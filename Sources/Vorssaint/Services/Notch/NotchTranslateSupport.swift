// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import NaturalLanguage

/// Where a translation is made: on this Mac by Apple's own models, or by
/// the online service the person set up.
enum NotchTranslateEngine: String, CaseIterable {
    case apple, online

    /// Apple's on-device translation arrived in macOS 15.
    static var appleIsSupported: Bool {
        if #available(macOS 15, *) { return true }
        return false
    }

    /// Before macOS 15 only the online engine can translate.
    static func saved(in defaults: UserDefaults = .standard) -> NotchTranslateEngine {
        guard appleIsSupported else { return .online }
        return NotchTranslateEngine(rawValue: defaults.string(forKey: DefaultsKey.notchTranslateEngine) ?? "") ?? .apple
    }
}

/// The online services the page can call. Each one is a request and the
/// place its answer sits in the reply; nothing else differs between them.
enum NotchTranslateProvider: String, CaseIterable, Identifiable {
    case deepL, google, libre, openAI

    var id: String { rawValue }

    /// Product names, the same in every language.
    var title: String {
        switch self {
        case .deepL: return "DeepL"
        case .google: return "Google Cloud Translation"
        case .libre: return "LibreTranslate"
        case .openAI: return "OpenAI-compatible"
        }
    }

    /// LibreTranslate and OpenAI-compatible servers live wherever their
    /// owner put them.
    var usesServerURL: Bool { self == .libre || self == .openAI }
    var usesModel: Bool { self == .openAI }
    /// A self-hosted LibreTranslate or a local model may need no key.
    var requiresKey: Bool { self == .deepL || self == .google }

    var defaultServerURL: String {
        switch self {
        case .libre: return "https://libretranslate.com"
        case .openAI: return "https://api.openai.com/v1"
        case .deepL, .google: return ""
        }
    }

    static func saved(in defaults: UserDefaults = .standard) -> NotchTranslateProvider {
        NotchTranslateProvider(rawValue: defaults.string(forKey: DefaultsKey.notchTranslateProvider) ?? "") ?? .deepL
    }
}

/// What the online engine needs for one request. The key comes from the
/// keychain, never from preferences.
struct NotchTranslateOnlineConfig: Equatable {
    var provider: NotchTranslateProvider
    var serverURL: String
    var model: String
    var key: String
}

enum NotchTranslateFailure: Error, Equatable {
    case unsupportedPair
    case missingKey
    case invalidServer
    case unauthorized
    case quotaExceeded
    case rateLimited
    case offline
    case server(Int)
    case badResponse
    case tooLong
    /// Apple's translation failed for a reason it does not name, most often
    /// a language that is not downloaded.
    case unknown
}

/// One alternative translation of a word and what it means back in the
/// word's own language.
struct NotchTranslateVariant: Codable, Equatable {
    let word: String
    let back: [String]
}

struct NotchTranslateVariantGroup: Codable, Equatable {
    let partOfSpeech: String
    let items: [NotchTranslateVariant]
}

/// What the page lists under a single word's translation: alternatives from
/// a language model, or the entry the Mac's own dictionaries have for it.
enum NotchTranslateVariants: Equatable {
    case groups([NotchTranslateVariantGroup])
    case definition(String)
}

struct NotchTranslateEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    let source: String
    let result: String
    /// The language the text was translated into.
    let target: String
    let date: Date
}

enum NotchTranslateSupport {
    /// On-device translation follows typing after this pause. The online
    /// engine waits for Return so half-typed words are not sent.
    static let liveDelay: TimeInterval = 0.4
    static let historyLimit = 100
    /// Longer text belongs in a document translator, and a service's limit
    /// per request is near this.
    static let characterLimit = 5_000
    static let requestTimeout: TimeInterval = 15

    /// Every language Apple's on-device models translate, which the online
    /// services also know, and a few only online services do. Identifiers as
    /// `Locale.Language` reads them.
    static let languages = [
        "ar", "zh-Hans", "zh-Hant", "nl", "en", "fr", "de", "hi", "id", "it", "ja", "ko",
        "pl", "pt-BR", "ru", "es", "tg", "th", "tr", "uk", "vi",
    ]

    /// Apple's models don't translate these, and NaturalLanguage doesn't
    /// recognize them, so they are picked rather than detected.
    static let onlineOnlyLanguages: Set<String> = ["tg"]

    /// What the menus offer for the engine in use.
    static func languages(for engine: NotchTranslateEngine) -> [String] {
        engine == .apple ? languages.filter { !onlineOnlyLanguages.contains($0) } : languages
    }

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        AppFeature.notchTranslate.isAvailable(in: defaults) && defaults.bool(forKey: DefaultsKey.notchTranslateEnabled)
    }

    // MARK: Languages

    /// One of `languages` for any identifier: an exact match, then the
    /// script a Chinese region writes, then the base language.
    static func supportedLanguage(_ identifier: String?) -> String? {
        guard let identifier, !identifier.isEmpty else { return nil }
        let normalized = identifier.replacingOccurrences(of: "_", with: "-")
        if let exact = languages.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) { return exact }
        let parts = normalized.split(separator: "-").map { String($0).lowercased() }
        guard let base = parts.first else { return nil }
        if base == "zh" {
            return parts.contains(where: { ["hant", "tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
        }
        return languages.first { $0.split(separator: "-").first.map(String.init)?.lowercased() == base }
    }

    /// Two identifiers name the same language, whatever their region.
    static func sameLanguage(_ lhs: String, _ rhs: String) -> Bool {
        supportedLanguage(lhs) == supportedLanguage(rhs)
    }

    /// The person's own language first, English when it is not offered.
    static func defaultTarget(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        preferredLanguages.lazy.compactMap(supportedLanguage).first ?? "en"
    }

    /// The other side of the pair: English, or Spanish for someone who
    /// already reads English.
    static func defaultAlternate(for target: String) -> String {
        sameLanguage(target, "en") ? "es" : "en"
    }

    /// Text already in the chosen language goes to the other one of the pair.
    static func target(detected: String?, preferred: String, alternate: String) -> String {
        guard let detected, sameLanguage(detected, preferred) else { return preferred }
        return alternate
    }

    /// Picking a language keeps the one it replaces as the other side.
    static func choosing(_ language: String, preferred: String, alternate: String) -> (preferred: String, alternate: String) {
        guard !sameLanguage(language, preferred) else { return (preferred, alternate) }
        return (language, preferred)
    }

    /// The language of the text, or nil while it is too short to tell. A
    /// single word is rarely certain, so an unsure guess still counts when it
    /// is one of the `likely` pair: "Hello" is English to someone translating
    /// between Russian and English.
    static func detectLanguage(_ text: String, likely: [String] = []) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages(for: .apple).map { NLLanguage(rawValue: recognizerCode($0)) }
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3).sorted { $0.value > $1.value }
        if let (language, confidence) = hypotheses.first, confidence >= 0.3 {
            return supportedLanguage(language.rawValue)
        }
        return hypotheses.lazy.compactMap { supportedLanguage($0.key.rawValue) }
            .first { language in likely.contains { sameLanguage($0, language) } }
    }

    /// Alternatives are looked up for one word, as a dictionary would.
    static func isWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 40 && !trimmed.contains(where: \.isWhitespace)
    }

    /// NaturalLanguage names Brazilian Portuguese only as Portuguese.
    private static func recognizerCode(_ language: String) -> String {
        language == "pt-BR" ? "pt" : language
    }

    /// The language's name in the interface language.
    static func displayName(_ language: String, in interface: AppLanguage) -> String {
        Locale(identifier: interface.rawValue).localizedString(forIdentifier: language) ?? language
    }

    // MARK: Online requests

    /// A server URL without its trailing slash. Plain HTTP only reaches this
    /// Mac: a key sent anywhere else would cross the network readable.
    static func serverURL(_ string: String) -> URL? {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if scheme == "https" { return url }
        guard scheme == "http" else { return nil }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host) ? url : nil
    }

    static func request(text: String, source: String?, target: String,
                        config: NotchTranslateOnlineConfig) throws -> URLRequest {
        let key = config.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.provider.requiresKey, key.isEmpty { throw NotchTranslateFailure.missingKey }
        var body: [String: Any]
        var request: URLRequest
        switch config.provider {
        case .deepL:
            // Free keys end in ":fx" and only work on the free host.
            let host = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
            request = URLRequest(url: URL(string: host + "/v2/translate")!)
            request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            body = ["text": [text], "target_lang": deepLTarget(target)]
            if let source { body["source_lang"] = deepLSource(source) }
        case .google:
            request = URLRequest(url: URL(string: "https://translation.googleapis.com/language/translate/v2")!)
            // In a header, the key stays out of the URL and any log of it.
            request.setValue(key, forHTTPHeaderField: "X-Goog-Api-Key")
            body = ["q": text, "target": googleCode(target), "format": "text"]
            if let source { body["source"] = googleCode(source) }
        case .libre:
            guard let base = serverURL(config.serverURL) else { throw NotchTranslateFailure.invalidServer }
            request = URLRequest(url: base.appendingPathComponent("translate"))
            body = ["q": text, "source": source.map(libreCode) ?? "auto", "target": libreCode(target), "format": "text"]
            if !key.isEmpty { body["api_key"] = key }
        case .openAI:
            return try chatRequest(
                instruction: "Translate the user's text into \(englishName(target)). Reply with the translation only, keeping its line breaks and formatting.",
                text: text, config: config)
        }
        return try jsonPost(request, body: body)
    }

    /// Asks a language model for a word's other translations, grouped by part
    /// of speech, each with its meanings back in the word's language.
    static func variantsRequest(word: String, source: String, target: String, interface: String,
                                config: NotchTranslateOnlineConfig) throws -> URLRequest {
        let from = englishName(source)
        let instruction = """
            The user sends one \(from) word. List its common translations into \(englishName(target)), \
            grouped by part of speech: at most 3 groups of up to 5 translations, most common first. \
            For each translation give up to 3 of its meanings back in \(from). \
            Name each part of speech in \(englishName(interface)), in the plural. \
            Reply with JSON only, shaped {"groups":[{"partOfSpeech":"","items":[{"word":"","back":[""]}]}]}.
            """
        return try chatRequest(instruction: instruction, text: word, config: config)
    }

    private static func chatRequest(instruction: String, text: String, config: NotchTranslateOnlineConfig) throws -> URLRequest {
        guard let base = serverURL(config.serverURL) else { throw NotchTranslateFailure.invalidServer }
        var request = URLRequest(url: base.appendingPathComponent("chat/completions"))
        let key = config.key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return try jsonPost(request, body: [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0,
            "messages": [
                ["role": "system", "content": instruction],
                ["role": "user", "content": text],
            ],
        ])
    }

    private static func jsonPost(_ request: URLRequest, body: [String: Any]) throws -> URLRequest {
        var request = request
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// A model is told language names, which it knows better than codes.
    private static func englishName(_ language: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
    }

    /// The translation in a successful reply.
    static func translation(from data: Data, provider: NotchTranslateProvider) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotchTranslateFailure.badResponse
        }
        let text: String?
        switch provider {
        case .deepL:
            text = (json["translations"] as? [[String: Any]])?.first?["text"] as? String
        case .google:
            let translations = (json["data"] as? [String: Any])?["translations"] as? [[String: Any]]
            text = translations?.first?["translatedText"] as? String
        case .libre:
            text = json["translatedText"] as? String
        case .openAI:
            let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            text = (message?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let text, !text.isEmpty else { throw NotchTranslateFailure.badResponse }
        return text
    }

    /// The groups in a model's reply, which may wrap its JSON in prose or a
    /// code fence.
    static func variants(from data: Data) throws -> [NotchTranslateVariantGroup] {
        struct Reply: Decodable { let groups: [NotchTranslateVariantGroup] }
        let content = try translation(from: data, provider: .openAI)
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"), start < end,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(content[start...end].utf8)) else {
            throw NotchTranslateFailure.badResponse
        }
        return reply.groups.filter { !$0.items.isEmpty }
    }

    /// What an unsuccessful status means to the person.
    static func failure(status: Int) -> NotchTranslateFailure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        // DeepL's own code for a used-up quota.
        case 456: return .quotaExceeded
        case 429: return .rateLimited
        default: return .server(status)
        }
    }

    /// DeepL wants a region for English and Portuguese and a script for Chinese.
    static func deepLTarget(_ language: String) -> String {
        switch language {
        case "en": return "EN-US"
        case "pt-BR": return "PT-BR"
        case "zh-Hans": return "ZH-HANS"
        case "zh-Hant": return "ZH-HANT"
        default: return language.uppercased()
        }
    }

    /// Source languages are only ever the base language.
    static func deepLSource(_ language: String) -> String {
        String(language.split(separator: "-").first ?? "").uppercased()
    }

    static func googleCode(_ language: String) -> String {
        switch language {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "pt-BR": return "pt"
        default: return language
        }
    }

    static func libreCode(_ language: String) -> String {
        switch language {
        case "zh-Hans": return "zh"
        // LibreTranslate's own code for Traditional Chinese.
        case "zh-Hant": return "zt"
        case "pt-BR": return "pt"
        default: return language
        }
    }

    // MARK: History

    /// Newest first; the same text into the same language is kept once.
    static func recording(_ entry: NotchTranslateEntry, in history: [NotchTranslateEntry],
                          limit: Int = historyLimit) -> [NotchTranslateEntry] {
        let others = history.filter { $0.source != entry.source || $0.target != entry.target }
        return Array(([entry] + others).prefix(limit))
    }

    static func pruned(_ history: [NotchTranslateEntry], retention: ScratchpadRetention, now: Date) -> [NotchTranslateEntry] {
        guard let interval = retention.maxIdleInterval else { return history }
        return history.filter { now.timeIntervalSince($0.date) < interval }
    }
}
