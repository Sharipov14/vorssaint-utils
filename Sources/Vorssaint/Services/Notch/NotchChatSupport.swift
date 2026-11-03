// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// How a provider's server is spoken to. Almost every service copies
/// OpenAI's chat completions; Anthropic's Messages API is the one exception.
enum ChatWire: String, Codable, CaseIterable {
    case openAI
    case anthropic
}

/// A chat service, built-in or the person's own. Providers are data, so any
/// number of them can sit side by side.
struct ChatProvider: Codable, Identifiable, Equatable {
    /// Also the keychain account of the provider's key.
    var id = UUID()
    /// The preset it started from, for its colour and hints; nil for one's own.
    var preset: String?
    var name: String
    var wire: ChatWire
    /// As typed: a base URL is never guessed at or rewritten.
    var baseURL: String
    var models: [String] = []
    var enabled = true

    /// Presets that charge per request refuse to answer without a key; one's
    /// own server may well need none.
    var requiresKey: Bool { ChatPreset.named(preset)?.requiresKey ?? false }
}

/// A template that fills a new provider. Model names are left out: they go
/// stale quickly, and the server lists its own.
struct ChatPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let wire: ChatWire
    let baseURL: String
    let requiresKey: Bool

    static let all: [ChatPreset] = [
        ChatPreset(id: "anthropic", name: "Anthropic", wire: .anthropic, baseURL: "https://api.anthropic.com/v1", requiresKey: true),
        ChatPreset(id: "openAI", name: "OpenAI", wire: .openAI, baseURL: "https://api.openai.com/v1", requiresKey: true),
        ChatPreset(id: "openCodeZen", name: "OpenCode Zen", wire: .openAI, baseURL: "https://opencode.ai/zen/v1", requiresKey: true),
        ChatPreset(id: "openRouter", name: "OpenRouter", wire: .openAI, baseURL: "https://openrouter.ai/api/v1", requiresKey: true),
        ChatPreset(id: "deepSeek", name: "DeepSeek", wire: .openAI, baseURL: "https://api.deepseek.com/v1", requiresKey: true),
        ChatPreset(id: "gemini", name: "Google Gemini", wire: .openAI,
                   baseURL: "https://generativelanguage.googleapis.com/v1beta/openai", requiresKey: true),
        ChatPreset(id: "ollama", name: "Ollama", wire: .openAI, baseURL: "http://localhost:11434/v1", requiresKey: false),
        ChatPreset(id: "lmStudio", name: "LM Studio", wire: .openAI, baseURL: "http://localhost:1234/v1", requiresKey: false),
    ]

    static func named(_ id: String?) -> ChatPreset? { all.first { $0.id == id } }

    func provider() -> ChatProvider { ChatProvider(preset: id, name: name, wire: wire, baseURL: baseURL) }
}

struct ChatMessage: Equatable {
    enum Role: String { case user, assistant }
    var role: Role
    var text: String
}

enum ChatStreamEvent: Equatable {
    case text(String)
    case done
    case error(String)
}

enum NotchChatFailure: Error, Equatable {
    case missingKey
    case invalidServer
    case unauthorized
    /// A wrong model name or base URL.
    case notFound
    case rateLimited
    case offline
    case server(Int, String?)
    case badResponse
}

enum NotchChatSupport {
    static let anthropicVersion = "2023-06-01"
    /// Anthropic requires a ceiling; every current model accepts this one.
    static let anthropicMaxTokens = 4096
    /// Between two pieces of the reply, not for all of it: a reasoning model
    /// can think a while before its first word.
    static let requestTimeout: TimeInterval = 120

    // MARK: Stored settings

    static func providers(from json: String) -> [ChatProvider] {
        (try? JSONDecoder().decode([ChatProvider].self, from: Data(json.utf8))) ?? []
    }

    static func json(_ providers: [ChatProvider]) -> String {
        (try? JSONEncoder().encode(providers)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static func loadProviders(_ defaults: UserDefaults = .standard) -> [ChatProvider] {
        providers(from: defaults.string(forKey: DefaultsKey.notchChatProviders) ?? "")
    }

    static func saveProviders(_ providers: [ChatProvider], _ defaults: UserDefaults = .standard) {
        defaults.set(json(providers), forKey: DefaultsKey.notchChatProviders)
    }

    /// The chosen model is stored as `<provider id>:<model>`. It splits at the
    /// first colon: an id has none, while a model name may (`llama3.2:3b`).
    static func selection(_ value: String) -> (provider: UUID, model: String)? {
        guard let colon = value.firstIndex(of: ":"),
              let id = UUID(uuidString: String(value[..<colon])) else { return nil }
        let model = String(value[value.index(after: colon)...])
        return model.isEmpty ? nil : (id, model)
    }

    static func selectionValue(provider: UUID, model: String) -> String { provider.uuidString + ":" + model }

    // MARK: Requests

    static func request(provider: ChatProvider, model: String, messages: [ChatMessage],
                        system: String, key: String) throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.requiresKey, key.isEmpty { throw NotchChatFailure.missingKey }
        guard let base = NotchTranslateSupport.serverURL(provider.baseURL) else { throw NotchChatFailure.invalidServer }
        let turns = messages.map { ["role": $0.role.rawValue, "content": $0.text] }
        var request: URLRequest
        var body: [String: Any] = ["model": model, "stream": true]
        switch provider.wire {
        case .openAI:
            request = URLRequest(url: base.appendingPathComponent("chat/completions"))
            authorize(&request, wire: .openAI, key: key)
            // No max_tokens: OpenAI's reasoning models refuse it.
            body["messages"] = (system.isEmpty ? [] : [["role": "system", "content": system]]) + turns
        case .anthropic:
            request = URLRequest(url: base.appendingPathComponent("messages"))
            authorize(&request, wire: .anthropic, key: key)
            body["max_tokens"] = anthropicMaxTokens
            body["messages"] = turns
            if !system.isEmpty { body["system"] = system }
        }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = requestTimeout
        return request
    }

    /// Lists the server's models; a key is sent when there is one.
    static func modelsRequest(provider: ChatProvider, key: String) throws -> URLRequest {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.requiresKey, key.isEmpty { throw NotchChatFailure.missingKey }
        guard let base = NotchTranslateSupport.serverURL(provider.baseURL) else { throw NotchChatFailure.invalidServer }
        var url = base.appendingPathComponent("models")
        // Anthropic pages its list at 20 by default.
        if provider.wire == .anthropic { url.append(queryItems: [URLQueryItem(name: "limit", value: "100")]) }
        var request = URLRequest(url: url)
        authorize(&request, wire: provider.wire, key: key)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = NotchTranslateSupport.requestTimeout
        return request
    }

    private static func authorize(_ request: inout URLRequest, wire: ChatWire, key: String) {
        switch wire {
        case .openAI:
            if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        case .anthropic:
            if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "x-api-key") }
            request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        }
    }

    /// Words that name models which do not chat: embeddings, speech, images.
    private static let nonChatModels = ["embed", "tts", "whisper", "transcribe", "dall-e", "moderation", "image"]

    /// The chat models in a `/models` reply, in the server's order. Gemini
    /// prefixes its names with `models/`, which its chat endpoint refuses.
    static func models(from data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return list.compactMap { entry -> String? in
            guard var id = entry["id"] as? String else { return nil }
            if id.hasPrefix("models/") { id.removeFirst("models/".count) }
            let lower = id.lowercased()
            guard !id.isEmpty, !nonChatModels.contains(where: lower.contains), seen.insert(id).inserted else { return nil }
            return id
        }
    }

    // MARK: Replies

    /// One line of a server-sent event stream. Comments, `event:` names,
    /// pings and thinking are nothing to show.
    static func event(line: String, wire: ChatWire) -> ChatStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if wire == .openAI, payload == "[DONE]" { return .done }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { return nil }
        if let message = errorMessage(object) { return .error(message) }
        switch wire {
        case .openAI:
            let choice = (object["choices"] as? [[String: Any]])?.first
            let text = (choice?["delta"] as? [String: Any])?["content"] as? String
            return text.flatMap { $0.isEmpty ? nil : .text($0) }
        case .anthropic:
            switch object["type"] as? String {
            case "content_block_delta":
                let delta = object["delta"] as? [String: Any]
                guard delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String,
                      !text.isEmpty else { return nil }
                return .text(text)
            case "message_stop": return .done
            default: return nil
            }
        }
    }

    /// A failed reply, with the server's own words when it gives any. The
    /// body is decoded as a whole, so a message in any language survives.
    static func failure(status: Int, body: Data) -> NotchChatFailure? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .unauthorized
        case 404: return .notFound
        case 429: return .rateLimited
        default:
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let message = object.flatMap(errorMessage)
                ?? String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .server(status, message.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) })
        }
    }

    /// OpenAI and Anthropic nest it as `error.message`; Ollama sends `error`
    /// as plain text.
    private static func errorMessage(_ object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] { return error["message"] as? String ?? "" }
        return object["error"] as? String
    }
}
