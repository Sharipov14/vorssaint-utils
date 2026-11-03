// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

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

    var providers: [ChatProvider] { NotchChatSupport.loadProviders(defaults) }

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

    private func start() {
        guard let (provider, model) = selection, messages.last?.role == .user else { return }
        phase = .waiting
        turn += 1
        let current = turn
        let history = messages
        task = Task { @MainActor [weak self] in
            var reply = ""
            var shown = Date.distantPast
            var failure: NotchChatFailure?
            do {
                for try await piece in NotchChatClient.stream(provider: provider, model: model, messages: history,
                                                              system: Self.systemPrompt) {
                    reply += piece
                    // About fifteen redraws a second, however fast the words come.
                    if Date().timeIntervalSince(shown) >= 1.0 / 15, self?.turn == current {
                        self?.show(reply)
                        shown = Date()
                    }
                }
            } catch is CancellationError {
            } catch {
                failure = error as? NotchChatFailure ?? .badResponse
            }
            guard self?.turn == current else { return }
            self?.finish(reply, failure: failure)
        }
    }

    private func show(_ reply: String) {
        guard !reply.isEmpty else { return }
        if phase == .waiting {
            messages.append(ChatMessage(role: .assistant, text: reply))
            phase = .streaming
        } else if let last = messages.indices.last, messages[last].role == .assistant {
            messages[last].text = reply
        }
    }

    private func finish(_ reply: String, failure: NotchChatFailure?) {
        show(reply)
        phase = failure.map(Phase.failed) ?? .idle
        task = nil
    }
}
