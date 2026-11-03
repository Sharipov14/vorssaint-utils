// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// The chat on the AI page: one conversation, kept in memory only, so it
/// outlives the island closing but not the app quitting. Nothing of it is
/// logged.
final class NotchChatService: ObservableObject {
    static let shared = NotchChatService()

    enum Phase: Equatable {
        case idle
        /// Sent; no word of the reply yet.
        case waiting
        case streaming
        case failed(NotchChatFailure)
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published var draft = ""
    @Published private(set) var phase: Phase = .idle
    /// The Chat tab is the one open, so the island gives the page its full
    /// height and reopens on it.
    @Published var isShown = false
    private var task: Task<Void, Never>?
    /// Which reply is current: one from before a new chat or a retry is dropped.
    private var turn = 0
    private let defaults = UserDefaults.standard

    /// Short on purpose: the window is small and the person may write in any language.
    static let systemPrompt = """
        You are a helpful assistant in a small panel at the top of a Mac screen. \
        Answer in the language the user writes in. Be concise; light Markdown is fine.
        """

    var isBusy: Bool { phase == .waiting || phase == .streaming }

    /// Decoded again only once Settings change them: the page asks on every
    /// frame of a reply.
    private var decoded: (json: String, providers: [ChatProvider]) = ("", [])

    var providers: [ChatProvider] {
        let json = defaults.string(forKey: DefaultsKey.notchChatProviders) ?? ""
        if json != decoded.json { decoded = (json, NotchChatSupport.providers(from: json)) }
        return decoded.providers
    }

    /// The stored choice while its provider is on and still offers the
    /// model; otherwise the first model of the first provider that is on.
    var selection: (provider: ChatProvider, model: String)? {
        let usable = providers.filter { $0.enabled && !$0.models.isEmpty }
        if let chosen = NotchChatSupport.selection(defaults.string(forKey: DefaultsKey.notchChatModel) ?? ""),
           let provider = usable.first(where: { $0.id == chosen.provider }), provider.models.contains(chosen.model) {
            return (provider, chosen.model)
        }
        return usable.first.map { ($0, $0.models[0]) }
    }

    func choose(provider: ChatProvider, model: String) {
        objectWillChange.send()
        defaults.set(NotchChatSupport.selectionValue(provider: provider.id, model: model), forKey: DefaultsKey.notchChatModel)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isBusy, selection != nil else { return }
        draft = ""
        // A failed turn's question stays; a new one is simply added after it.
        messages.append(ChatMessage(role: .user, text: text))
        start()
    }

    /// Asks again after a failure, dropping any half reply it left.
    func retry() {
        guard case .failed = phase else { return }
        if messages.last?.role == .assistant { messages.removeLast() }
        start()
    }

    /// Keeps what has arrived so far.
    func stop() { task?.cancel() }

    func newChat() {
        task?.cancel()
        task = nil
        turn += 1
        messages = []
        phase = .idle
    }

    /// What has come in from the server, ahead of what the page shows.
    private final class Feed {
        var text = ""
        var reasoning = ""
        var failure: NotchChatFailure?
        var done = false
    }

    /// The reply is read as fast as it comes and typed out frame by frame,
    /// so bursts from the network read as steady writing.
    private func start() {
        guard let (provider, model) = selection, messages.last?.role == .user else { return }
        phase = .waiting
        turn += 1
        let current = turn
        let history = messages
        task = Task { @MainActor [weak self] in
            let feed = Feed()
            let reader = Task { @MainActor in
                do {
                    for try await event in NotchChatClient.stream(provider: provider, model: model, messages: history,
                                                                  system: Self.systemPrompt) {
                        switch event {
                        case .text(let piece): feed.text += piece
                        case .reasoning(let piece): feed.reasoning += piece
                        default: break
                        }
                    }
                } catch is CancellationError {
                } catch {
                    feed.failure = error as? NotchChatFailure ?? .badResponse
                }
                feed.done = true
            }
            var shown = 0
            var total = 0
            var size = (text: 0, reasoning: 0)
            await withTaskCancellationHandler {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(Self.frame))
                    guard let self, self.turn == current, !Task.isCancelled else { break }
                    // Nothing new and nothing left to type: the frame costs nothing.
                    let arrived = (text: feed.text.utf8.count, reasoning: feed.reasoning.utf8.count)
                    if arrived != size {
                        size = arrived
                        total = feed.text.count
                    } else if shown >= total {
                        if feed.done { break }
                        continue
                    }
                    // Under Reduce Motion the words appear as they come.
                    shown = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                        ? total : NotchChatSupport.reveal(feed.text, shown: shown, frame: Self.frame)
                    self.show(String(feed.text.prefix(shown)), reasoning: feed.reasoning)
                    if feed.done, shown >= total { break }
                }
            } onCancel: {
                reader.cancel()
            }
            // Stopped: everything that came in so far stays.
            await reader.value
            guard let self, self.turn == current else { return }
            self.show(feed.text, reasoning: feed.reasoning)
            self.finish(failure: feed.failure)
        }
    }

    private static let frame: TimeInterval = 1.0 / 30

    private func show(_ reply: String, reasoning: String) {
        guard !reply.isEmpty || !reasoning.isEmpty else { return }
        if phase == .waiting {
            messages.append(ChatMessage(role: .assistant, text: ""))
            phase = .streaming
        }
        guard let last = messages.indices.last, messages[last].role == .assistant else { return }
        var message = messages[last]
        message.text = reply
        message.reasoning = reasoning
        // Settled once the answer begins, so the reply is not split again on every frame after.
        if message.thought == nil {
            let (thinking, answer) = NotchChatSupport.split(reply)
            if message.thinkingSince == nil, !reasoning.isEmpty || !thinking.isEmpty { message.thinkingSince = Date() }
            if !answer.isEmpty { message.thought = message.thinkingSince.map { Date().timeIntervalSince($0) } ?? 0 }
        }
        if message != messages[last] { messages[last] = message }
    }

    private func finish(failure: NotchChatFailure?) {
        if let last = messages.indices.last, messages[last].role == .assistant,
           let since = messages[last].thinkingSince, messages[last].thought == nil {
            messages[last].thought = Date().timeIntervalSince(since)
        }
        phase = failure.map(Phase.failed) ?? .idle
        task = nil
    }
}
