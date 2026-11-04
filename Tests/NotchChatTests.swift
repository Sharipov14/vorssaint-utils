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
                        && anthropicBody["max_tokens"] as? Int == NotchChatSupport.anthropicThinkingMaxTokens
                        && (anthropicBody["thinking"] as? [String: String]) == ["type": "adaptive", "display": "summarized"]
                        && anthropicBody["system"] as? String == "Be brief"
                        && (anthropicBody["messages"] as? [[String: String]])?.count == 3,
                     "an Anthropic request carries its key, version, token cap, thinking and a separate system prompt")
        let plain = (try? NotchChatSupport.request(provider: ChatPreset.named("anthropic")!.provider(), model: "claude",
                                                   messages: messages, system: "", key: "ak", thinking: false)).map(body) ?? [:]
        suite.expect(plain["thinking"] == nil && plain["max_tokens"] as? Int == NotchChatSupport.anthropicMaxTokens
                        && openAIBody["extra_body"] == nil,
                     "a model that refuses thinking is asked again without it, and other servers are never asked")
        let thought = [ChatMessage(role: .user, text: "Q"), ChatMessage(role: .assistant, text: "<think>hm</think>A"),
                       ChatMessage(role: .user, text: "Q2")]
        let resent = (try? NotchChatSupport.request(provider: custom("https://llm.example.com/v1"), model: "a",
                                                    messages: thought, system: "", key: "")).map(body)?["messages"]
        suite.expect((resent as? [[String: String]])?[1] == ["role": "assistant", "content": "A"],
                     "an earlier reply goes back without its thinking")
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
        suite.expect(anthropic.compactMap { NotchChatSupport.event(line: $0, wire: .anthropic) }
                        == [.reasoning("hmm"), .text("Hello"), .done],
                     "an Anthropic stream yields its thinking and its text, not pings")
        let reasoning = [
            #"data: {"choices":[{"delta":{"reasoning_content":"Думаю"}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning":" ещё","content":null}}]}"#,
            #"data: {"choices":[{"delta":{"content":"Ответ","reasoning":""}}]}"#,
        ]
        suite.expect(reasoning.compactMap { NotchChatSupport.event(line: $0, wire: .openAI) }
                        == [.reasoning("Думаю"), .reasoning(" ещё"), .text("Ответ")],
                     "an OpenAI-compatible stream's reasoning is read under either name")
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
        let closed = NotchChatSupport.split("<think>plan</think>\n\nHello")
        let open = NotchChatSupport.split("Hi <think>still going")
        let gemini = NotchChatSupport.split("<thought>a</thought>One<think>b</think> two")
        suite.expect(closed == ("plan", "Hello") && open == ("still going", "Hi")
                        && gemini == ("a\n\nb", "One two") && NotchChatSupport.split("plain") == ("", "plain"),
                     "a model's thinking is set apart from its answer, closed or still open")
        let words = "Привет, мир, это длинная строка текста"
        let first = NotchChatSupport.reveal(words, shown: 0, frame: 1.0 / 30)
        suite.expect(first == 7 && NotchChatSupport.reveal(words, shown: words.count, frame: 1.0 / 30) == words.count,
                     "typing shows a word whole and stops at the end")
        let flood = String(repeating: "a ", count: 2000)
        let caughtUp = (0..<16).reduce(0) { shown, _ in NotchChatSupport.reveal(flood, shown: shown, frame: 1.0 / 30) }
        suite.expect(caughtUp > flood.count / 2 && NotchChatSupport.reveal("ab", shown: 0, frame: 1.0 / 30) == 2,
                     "typing speeds up when much is waiting, so it never trails the model for long")
        let reply = "Run this:\n```swift\nlet a = 1\n  print(a)\n```\nDone."
        suite.expect(NotchChatSupport.blocks(reply) == [.text("Run this:"), .code(language: "swift", code: "let a = 1\n  print(a)"),
                                                        .text("Done.")],
                     "a reply splits into prose and fenced code, indentation kept")
        suite.expect(NotchChatSupport.blocks("Look\n```\nhalf") == [.text("Look"), .code(language: "", code: "half")]
                        && NotchChatSupport.blocks("") == [],
                     "a fence still streaming is already code")
        // Typing out, the settled prose is parsed once and joined to the rest.
        let prose = "Посмотрю **формат**, `код` и [ссылку](https://a.b)! a -> b #12\n\n**Жирный\n\nчерез абзац** и `код\n\nчерез абзац`.\n\nКонец."
        var typed = "", joined = 0, same = true
        for character in prose {
            typed.append(character)
            guard let end = NotchChatSupport.settledEnd(of: typed) else { continue }
            let settled = NotchChatSupport.markdown(String(typed[..<end]))
            guard NotchChatSupport.isClosed(settled) else { continue }
            joined += 1
            same = same && settled + NotchChatSupport.markdown(String(typed[end...])) == NotchChatSupport.markdown(typed)
        }
        suite.expect(same && joined >= 10 && !NotchChatSupport.isClosed(NotchChatSupport.markdown("**Жирный\n\n")),
                     "settled prose is joined to the rest only where the whole would read the same")
    }
}
