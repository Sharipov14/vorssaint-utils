// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum NotchTranslateTests {
    static func run(_ suite: TestSuite) {
        languageContracts(suite)
        pairContracts(suite)
        requestContracts(suite)
        replyContracts(suite)
        historyContracts(suite)
        gateContracts(suite)
    }

    private static func languageContracts(_ suite: TestSuite) {
        suite.expect(NotchTranslateSupport.supportedLanguage("ru_RU") == "ru"
                        && NotchTranslateSupport.supportedLanguage("en-GB") == "en"
                        && NotchTranslateSupport.supportedLanguage("pt-PT") == "pt-BR"
                        && NotchTranslateSupport.supportedLanguage("zh-TW") == "zh-Hant"
                        && NotchTranslateSupport.supportedLanguage("zh-Hant-HK") == "zh-Hant"
                        && NotchTranslateSupport.supportedLanguage("zh-CN") == "zh-Hans"
                        && NotchTranslateSupport.supportedLanguage("xx") == nil,
                     "any system language maps onto an offered one, by script for Chinese")
        suite.expect(NotchTranslateSupport.supportedLanguage("tg-TJ") == "tg"
                        && NotchTranslateSupport.languages(for: .online).contains("tg")
                        && !NotchTranslateSupport.languages(for: .apple).contains("tg"),
                     "Tajik is offered only where an online service translates it")
        suite.expect(NotchTranslateSupport.defaultTarget(preferredLanguages: ["eo", "uk-UA", "en"]) == "uk"
                        && NotchTranslateSupport.defaultTarget(preferredLanguages: ["eo"]) == "en",
                     "the target starts as the first offered system language, else English")
        suite.expect(NotchTranslateSupport.detectLanguage("Привет, как у тебя дела сегодня?") == "ru"
                        && NotchTranslateSupport.detectLanguage("The weather is lovely this morning.") == "en"
                        && NotchTranslateSupport.detectLanguage("a") == nil,
                     "the text's language is recognized once there is enough of it")
        suite.expect(NotchTranslateSupport.detectLanguage("Hello", likely: ["ru", "en"]) == "en"
                        && NotchTranslateSupport.detectLanguage("Hello", likely: ["ru", "uk"]) == nil,
                     "an unsure guess at one word counts only when it is one of the pair")
        suite.expect(NotchTranslateSupport.isWord(" hello ") && !NotchTranslateSupport.isWord("how are you")
                        && !NotchTranslateSupport.isWord(""),
                     "alternatives are looked up for a single word")
    }

    private static func pairContracts(_ suite: TestSuite) {
        suite.expect(NotchTranslateSupport.target(detected: "en", preferred: "ru", alternate: "en") == "ru"
                        && NotchTranslateSupport.target(detected: "ru", preferred: "ru", alternate: "en") == "en"
                        && NotchTranslateSupport.target(detected: nil, preferred: "ru", alternate: "en") == "ru",
                     "text already in the chosen language goes to the other side of the pair")
        let picked = NotchTranslateSupport.choosing("de", preferred: "ru", alternate: "en")
        let same = NotchTranslateSupport.choosing("ru", preferred: "ru", alternate: "en")
        suite.expect(picked == ("de", "ru") && same == ("ru", "en"),
                     "picking a language keeps the one it replaces as the other side")
        suite.expect(NotchTranslateSupport.defaultAlternate(for: "ru") == "en"
                        && NotchTranslateSupport.defaultAlternate(for: "en") == "es",
                     "the other side starts as English, or Spanish for English readers")
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private static func requestContracts(_ suite: TestSuite) {
        func config(_ provider: NotchTranslateProvider, url: String = "", key: String = "k") -> NotchTranslateOnlineConfig {
            NotchTranslateOnlineConfig(provider: provider, serverURL: url, model: "m", key: key)
        }
        let free = try? NotchTranslateSupport.request(text: "Hi", source: "en", target: "pt-BR", config: config(.deepL, key: "abc:fx"))
        let pro = try? NotchTranslateSupport.request(text: "Hi", source: nil, target: "zh-Hant", config: config(.deepL))
        suite.expect(free?.url?.host == "api-free.deepl.com" && pro?.url?.host == "api.deepl.com"
                        && free?.value(forHTTPHeaderField: "Authorization") == "DeepL-Auth-Key abc:fx"
                        && free.map(body)?["target_lang"] as? String == "PT-BR"
                        && free.map(body)?["source_lang"] as? String == "EN"
                        && pro.map(body)?["target_lang"] as? String == "ZH-HANT"
                        && pro.map(body)?["source_lang"] == nil,
                     "DeepL gets its host from the key and its own language codes")
        let google = try? NotchTranslateSupport.request(text: "Hi", source: "zh-Hans", target: "ru", config: config(.google, key: "g"))
        suite.expect(google?.value(forHTTPHeaderField: "X-Goog-Api-Key") == "g"
                        && google?.url?.query == nil
                        && google.map(body)?["source"] as? String == "zh-CN",
                     "the Google key travels in a header, never in the URL")
        let libre = try? NotchTranslateSupport.request(text: "Hi", source: nil, target: "zh-Hant",
                                                       config: config(.libre, url: "https://tr.example.org/", key: ""))
        suite.expect(libre?.url?.absoluteString == "https://tr.example.org/translate"
                        && libre.map(body)?["source"] as? String == "auto"
                        && libre.map(body)?["target"] as? String == "zt"
                        && libre.map(body)?["api_key"] == nil,
                     "LibreTranslate detects the language itself and needs no key")
        let local = try? NotchTranslateSupport.request(text: "Hi", source: nil, target: "ru",
                                                       config: config(.openAI, url: "http://localhost:11434/v1", key: ""))
        let messages = local.map(body)?["messages"] as? [[String: String]]
        suite.expect(local?.url?.absoluteString == "http://localhost:11434/v1/chat/completions"
                        && local?.value(forHTTPHeaderField: "Authorization") == nil
                        && messages?.first?["content"]?.contains("Russian") == true
                        && messages?.last?["content"] == "Hi",
                     "a local model is reached over plain HTTP, told the target language by name")
        func fails(_ config: NotchTranslateOnlineConfig, with failure: NotchTranslateFailure) -> Bool {
            do { _ = try NotchTranslateSupport.request(text: "Hi", source: nil, target: "ru", config: config); return false }
            catch { return error as? NotchTranslateFailure == failure }
        }
        suite.expect(fails(config(.deepL, key: " "), with: .missingKey)
                        && fails(config(.openAI, url: "http://example.com/v1"), with: .invalidServer)
                        && fails(config(.libre, url: "ftp://example.com"), with: .invalidServer)
                        && fails(config(.libre, url: ""), with: .invalidServer),
                     "a missing key or a key sent over plain HTTP to another machine is refused before sending")
    }

    private static func replyContracts(_ suite: TestSuite) {
        func reply(_ json: String, _ provider: NotchTranslateProvider) -> String? {
            try? NotchTranslateSupport.translation(from: Data(json.utf8), provider: provider)
        }
        suite.expect(reply(#"{"translations":[{"detected_source_language":"EN","text":"Привет"}]}"#, .deepL) == "Привет"
                        && reply(#"{"data":{"translations":[{"translatedText":"Привет"}]}}"#, .google) == "Привет"
                        && reply(#"{"translatedText":"Привет"}"#, .libre) == "Привет"
                        && reply(#"{"choices":[{"message":{"role":"assistant","content":" Привет\n"}}]}"#, .openAI) == "Привет"
                        && reply(#"{"translations":[]}"#, .deepL) == nil
                        && reply("not json", .libre) == nil,
                     "each service's translation is read from its own reply")
        let fenced = #"{"choices":[{"message":{"content":"```json\n{\"groups\":[{\"partOfSpeech\":\"nouns\",\"items\":[{\"word\":\"regards\",\"back\":[\"привет\"]}]},{\"partOfSpeech\":\"verbs\",\"items\":[]}]}\n```"}}]}"#
        let groups = try? NotchTranslateSupport.variants(from: Data(fenced.utf8))
        suite.expect(groups == [NotchTranslateVariantGroup(partOfSpeech: "nouns",
                                                           items: [NotchTranslateVariant(word: "regards", back: ["привет"])])]
                        && (try? NotchTranslateSupport.variants(from: Data(#"{"choices":[{"message":{"content":"none"}}]}"#.utf8))) == nil,
                     "a model's alternatives are read from inside a code fence, and empty groups are dropped")
        suite.expect(NotchTranslateSupport.failure(status: 200) == nil
                        && NotchTranslateSupport.failure(status: 403) == .unauthorized
                        && NotchTranslateSupport.failure(status: 456) == .quotaExceeded
                        && NotchTranslateSupport.failure(status: 429) == .rateLimited
                        && NotchTranslateSupport.failure(status: 500) == .server(500),
                     "an unsuccessful status says what to fix")
    }

    private static func historyContracts(_ suite: TestSuite) {
        let now = Date()
        func entry(_ source: String, _ target: String = "ru", age: TimeInterval = 0) -> NotchTranslateEntry {
            NotchTranslateEntry(source: source, result: source.uppercased(), target: target, date: now.addingTimeInterval(-age))
        }
        let history = [entry("a"), entry("b"), entry("a", "de")]
        let recorded = NotchTranslateSupport.recording(entry("b"), in: history, limit: 3)
        suite.expect(recorded.map(\.source) == ["b", "a", "a"] && recorded.count == 3,
                     "the same text into the same language moves to the top instead of repeating")
        suite.expect(NotchTranslateSupport.recording(entry("c"), in: history, limit: 2).map(\.source) == ["c", "a"],
                     "the history keeps only its newest entries")
        let aged = [entry("new", age: 3_600), entry("old", age: 2 * 86_400)]
        suite.expect(NotchTranslateSupport.pruned(aged, retention: .day, now: now).map(\.source) == ["new"]
                        && NotchTranslateSupport.pruned(aged, retention: .never, now: now).count == 2,
                     "entries past the chosen time are dropped, and forever keeps them all")
    }

    private static func gateContracts(_ suite: TestSuite) {
        let domain = "com.vorssaint.tests.notch-translate"
        let defaults = UserDefaults(suiteName: domain)!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        for (key, value) in Defaults.registeredDefaults where key.hasPrefix("notch") { defaults.set(value, forKey: key) }
        for (key, value) in AppFeature.availabilityDefaults { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: DefaultsKey.notchEnabled)
        suite.expect(!AppFeature.notchTranslate.installedByDefault && !NotchSupport.routesTranslate(in: defaults),
                     "an update does not add the translator on its own")
        defaults.set(true, forKey: AppFeature.notchTranslate.availabilityKey)
        suite.expect(NotchTranslateSupport.isEnabled(in: defaults) && NotchSupport.routesTranslate(in: defaults),
                     "installed, its page is in the island")
        suite.expect(NotchTranslateEngine.saved(in: defaults) == (NotchTranslateEngine.appleIsSupported ? .apple : .online),
                     "translation starts on this Mac wherever Apple's models exist")
        defaults.set(false, forKey: DefaultsKey.notchTranslateEnabled)
        suite.expect(!NotchSupport.routesTranslate(in: defaults) && !NotchSupport.modules(in: defaults).contains(.translate),
                     "switched off, the page leaves the island")
        suite.expect(AppFeature.notchTranslate.permissions.isEmpty
                        && !Defaults.registeredDefaults.keys.contains { $0.lowercased().contains("apikey") },
                     "no permission is asked and no key is kept in preferences")
    }
}
