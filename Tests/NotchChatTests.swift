// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum NotchChatTests {
    static func run(_ suite: TestSuite) {
        storageContracts(suite)
        requestContracts(suite)
        streamContracts(suite)
        modelListContracts(suite)
        failureContracts(suite)
        replyContracts(suite)
    }

    private static func body(_ request: URLRequest) -> [String: Any] {
        (request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private static let messages = [ChatMessage(role: .user, text: "Привет"),
                                   ChatMessage(role: .assistant, text: "Hi"),
                                   ChatMessage(role: .user, text: "How are you?")]

    private static func custom(_ url: String, wire: ChatWire = .openAI) -> ChatProvider {
        ChatProvider(name: "Mine", wire: wire, baseURL: url, models: ["a", "b"])
    }

    private static func storageContracts(_ suite: TestSuite) {
        let providers = [ChatPreset.named("anthropic")!.provider(), custom("https://llm.example.com/v1")]
        suite.expect(NotchChatSupport.providers(from: NotchChatSupport.json(providers)) == providers,
                     "providers survive a round trip through their stored JSON")
        suite.expect(NotchChatSupport.providers(from: "").isEmpty && NotchChatSupport.providers(from: "{").isEmpty,
                     "no stored or unreadable JSON means no providers")
        let id = UUID()
        let stored = NotchChatSupport.selectionValue(provider: id, model: "llama3.2:3b")
        suite.expect(NotchChatSupport.selection(stored).map { $0.provider == id && $0.model == "llama3.2:3b" } == true,
                     "a chosen model keeps the colons in its name")
        suite.expect(NotchChatSupport.selection("") == nil && NotchChatSupport.selection("nope:model") == nil
                        && NotchChatSupport.selection(id.uuidString + ":") == nil,
                     "a malformed choice is no choice")
        suite.expect(ChatPreset.named("ollama")!.provider().requiresKey == false
                        && ChatPreset.named("openCodeZen")!.provider().requiresKey
                        && !custom("https://llm.example.com").requiresKey,
                     "hosted presets need a key; local servers and one's own may not")
        suite.expect(ChatPreset.all.allSatisfy { NotchTranslateSupport.serverURL($0.baseURL) != nil }
                        && Set(ChatPreset.all.map(\.id)).count == ChatPreset.all.count,
                     "every preset has a unique id and an allowed address")
    }

    private static func requestContracts(_ suite: TestSuite) {
        let openAI = try? NotchChatSupport.request(provider: custom("https://llm.example.com/v1/"), model: "a",
                                                   messages: messages, system: "Be brief", key: " sk-1 ")
        let openAIBody = openAI.map(body) ?? [:]
        let turns = openAIBody["messages"] as? [[String: String]] ?? []
        suite.expect(openAI?.url?.absoluteString == "https://llm.example.com/v1/chat/completions"
                        && openAI?.value(forHTTPHeaderField: "Authorization") == "Bearer sk-1"
                        && openAI?.httpMethod == "POST"
                        && openAIBody["stream"] as? Bool == true && openAIBody["max_tokens"] == nil
                        && turns.first == ["role": "system", "content": "Be brief"] && turns.count == 4
                        && turns[1] == ["role": "user", "content": "Привет"],
                     "an OpenAI-compatible request streams, leads with the system prompt and has no token cap")
        let keyless = try? NotchChatSupport.request(provider: ChatPreset.named("ollama")!.provider(), model: "llama3.2:3b",
                                                    messages: messages, system: "", key: "")
        suite.expect(keyless?.value(forHTTPHeaderField: "Authorization") == nil
                        && keyless?.url?.absoluteString == "http://localhost:11434/v1/chat/completions"
                        && (keyless.map(body)?["messages"] as? [[String: String]])?.count == 3,
                     "a local server is asked without a key or an empty system prompt")
        let anthropic = try? NotchChatSupport.request(provider: ChatPreset.named("anthropic")!.provider(), model: "claude",
                                                      messages: messages, system: "Be brief", key: "ak")
        let anthropicBody = anthropic.map(body) ?? [:]
        suite.expect(anthropic?.url?.absoluteString == "https://api.anthropic.com/v1/messages"
                        && anthropic?.value(forHTTPHeaderField: "x-api-key") == "ak"
                        && anthropic?.value(forHTTPHeaderField: "anthropic-version") == NotchChatSupport.anthropicVersion
                        && anthropic?.value(forHTTPHeaderField: "Authorization") == nil
                        && anthropicBody["max_tokens"] as? Int == NotchChatSupport.anthropicMaxTokens
                        && anthropicBody["system"] as? String == "Be brief"
                        && (anthropicBody["messages"] as? [[String: String]])?.count == 3,
                     "an Anthropic request carries its key, version, token cap and a separate system prompt")
        suite.expect(throwsFailure(.missingKey) {
            try NotchChatSupport.request(provider: ChatPreset.named("openAI")!.provider(), model: "m",
                                         messages: messages, system: "", key: "  ")
        }, "a hosted preset is not asked without a key")
        suite.expect(throwsFailure(.invalidServer) {
            try NotchChatSupport.request(provider: custom("http://llm.example.com/v1"), model: "m",
                                         messages: messages, system: "", key: "k")
        } && throwsFailure(.invalidServer) {
            try NotchChatSupport.modelsRequest(provider: custom("ftp://localhost"), key: "")
        }, "plain HTTP reaches only this Mac, so a key never crosses the network readable")
        let anthropicModels = try? NotchChatSupport.modelsRequest(provider: ChatPreset.named("anthropic")!.provider(), key: "ak")
        let openAIModels = try? NotchChatSupport.modelsRequest(provider: custom("https://llm.example.com/v1"), key: "")
        suite.expect(anthropicModels?.url?.absoluteString == "https://api.anthropic.com/v1/models?limit=100"
                        && anthropicModels?.httpMethod == "GET"
                        && openAIModels?.url?.absoluteString == "https://llm.example.com/v1/models"
                        && openAIModels?.value(forHTTPHeaderField: "Authorization") == nil,
                     "the model list is asked for at the provider's models address")
    }

    private static func throwsFailure(_ failure: NotchChatFailure, _ body: () throws -> URLRequest) -> Bool {
        do { _ = try body(); return false } catch { return error as? NotchChatFailure == failure }
    }

    private static func streamContracts(_ suite: TestSuite) {
        let openAI: [String] = [
            ": OPENROUTER PROCESSING",
            #"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            #"data: {"choices":[{"delta":{"content":"При"}}]}"#,
            #"data:{"choices":[{"delta":{"content":"вет"}}]}"#,
            #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
        ]
        suite.expect(openAI.compactMap { NotchChatSupport.event(line: $0, wire: .openAI) }
                        == [.text("При"), .text("вет"), .done],
                     "an OpenAI-compatible stream yields its text pieces and its end, skipping comments")
        let anthropic: [String] = [
            "event: message_start",
            #"data: {"type":"message_start","message":{"id":"m"}}"#,
            #"data: {"type":"ping"}"#,
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        suite.expect(anthropic.compactMap { NotchChatSupport.event(line: $0, wire: .anthropic) } == [.text("Hello"), .done],
                     "an Anthropic stream yields only its text, not pings or thinking")
        suite.expect(NotchChatSupport.event(line: #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
                                            wire: .anthropic) == .error("Overloaded")
                        && NotchChatSupport.event(line: #"data: {"error":{"message":"Ошибка"}}"#, wire: .openAI) == .error("Ошибка")
                        && NotchChatSupport.event(line: #"data: {"error":"model not loaded"}"#, wire: .openAI) == .error("model not loaded")
                        && NotchChatSupport.event(line: "data: [DONE]", wire: .anthropic) == nil,
                     "an error in the middle of a stream is told, in the server's words")
    }

    private static func modelListContracts(_ suite: TestSuite) {
        let reply = Data(#"""
            {"object":"list","data":[{"id":"models/gemini-2.5-flash"},{"id":"gpt-4o"},
            {"id":"text-embedding-3-small"},{"id":"tts-1"},{"id":"whisper-1"},{"id":"gpt-4o"},{"name":"x"}]}
            """#.utf8)
        suite.expect(NotchChatSupport.models(from: reply) == ["gemini-2.5-flash", "gpt-4o"],
                     "a model list keeps chat models once, in order, without Gemini's prefix")
        suite.expect(NotchChatSupport.models(from: Data("[]".utf8)).isEmpty,
                     "an unexpected model list is an empty one")
    }

    private static func failureContracts(_ suite: TestSuite) {
        suite.expect(NotchChatSupport.failure(status: 200, body: Data()) == nil
                        && NotchChatSupport.failure(status: 401, body: Data()) == .unauthorized
                        && NotchChatSupport.failure(status: 403, body: Data()) == .unauthorized
                        && NotchChatSupport.failure(status: 404, body: Data()) == .notFound
                        && NotchChatSupport.failure(status: 429, body: Data()) == .rateLimited,
                     "common HTTP failures are named")
        let russian = Data(#"{"error":{"message":"Недостаточно средств на балансе"}}"#.utf8)
        suite.expect(NotchChatSupport.failure(status: 402, body: russian) == .server(402, "Недостаточно средств на балансе")
                        && NotchChatSupport.failure(status: 500, body: Data("Внутренняя ошибка\n".utf8)) == .server(500, "Внутренняя ошибка")
                        && NotchChatSupport.failure(status: 502, body: Data()) == .server(502, nil),
                     "a server's error message reaches the person intact, in any language")
    }

    private static func replyContracts(_ suite: TestSuite) {
        suite.expect(NotchChatSupport.visible("<think>plan</think>\n\nHello") == "Hello"
                        && NotchChatSupport.visible("Hi <think>still going") == "Hi"
                        && NotchChatSupport.visible("<think>a</think>One<think>b</think> two") == "One two"
                        && NotchChatSupport.visible("plain") == "plain",
                     "a model's thinking is hidden, closed or still open")
        let reply = "Run this:\n```swift\nlet a = 1\n  print(a)\n```\nDone."
        suite.expect(NotchChatSupport.blocks(reply) == [.text("Run this:"), .code(language: "swift", code: "let a = 1\n  print(a)"),
                                                        .text("Done.")],
                     "a reply splits into prose and fenced code, indentation kept")
        suite.expect(NotchChatSupport.blocks("Look\n```\nhalf") == [.text("Look"), .code(language: "", code: "half")]
                        && NotchChatSupport.blocks("") == [],
                     "a fence still streaming is already code")
    }
}
