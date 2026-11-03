// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The AI page's Chat tab: the conversation above, the message being
/// written below.
struct NotchChatView: View {
    let size: CGSize
    let preview: Bool
    @ObservedObject private var chat = NotchChatService.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Read so a change in Settings redraws the page.
    @AppStorage(DefaultsKey.notchChatProviders) private var storedProviders = ""
    @AppStorage(DefaultsKey.notchChatModel) private var storedModel = ""
    @State private var editor = EditorHandle()
    private var text: NotchChatStrings { FeatureStrings.notchChat(l10n.language) }
    private static let textSize: CGFloat = 13
    private static let editorInset = NSSize(width: 6, height: 6)

    private final class EditorHandle {
        weak var view: NSTextView?
    }

    var body: some View {
        let _ = (storedProviders, storedModel)
        Group {
            if preview {
                NotchEmptyView(symbol: NotchChatView.symbol, message: text.settingsDescription)
            } else if let selection = chat.selection {
                VStack(spacing: 6) {
                    conversation(model: selection.model, provider: selection.provider)
                    composer
                }
            } else {
                NotchEmptyView(symbol: NotchChatView.symbol, message: text.needsSetup) {
                    NotchPillButton(title: text.openSettings, prominent: true) {
                        NotchService.shared.openSettings(showing: .agents)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    static let symbol = "bubble.left.and.bubble.right"

    private var spring: Animation? { reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86) }

    // MARK: Conversation

    @ViewBuilder private func conversation(model: String, provider: ChatProvider) -> some View {
        if chat.messages.isEmpty, !chat.isBusy {
            VStack(spacing: 10) {
                ChatProviderBadge(provider: provider, size: 34)
                Text(text.empty(model))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chat.messages) { message in
                            bubble(message)
                                .id(message.id)
                                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                        removal: .opacity))
                        }
                        if chat.phase == .waiting {
                            thinking.id("thinking").transition(.opacity)
                        }
                        if case .failed(let failure) = chat.phase {
                            failureRow(failure).id("failure").transition(.opacity)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 2)
                    .animation(spring, value: chat.messages.count)
                    .animation(spring, value: chat.phase)
                }
                .scrollIndicators(.automatic)
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: chat.messages.last?.text) { _, _ in proxy.scrollTo(Self.bottom, anchor: .bottom) }
                .onChange(of: chat.phase) { _, _ in
                    withAnimation(spring) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(spring) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
            }
        }
    }

    private static let bottom = "bottom"

    @ViewBuilder private func bubble(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 36)
                Text(message.text)
                    .font(.system(size: Self.textSize))
                    .foregroundStyle(.white.opacity(0.95))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        } else {
            NotchChatReply(message: message,
                           streaming: chat.phase == .streaming && message.id == chat.messages.last?.id,
                           textSize: Self.textSize)
        }
    }

    private var thinking: some View {
        HStack(spacing: 6) {
            NotchChatTypingDots()
            Text(text.thinking).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    private func failureRow(_ failure: NotchChatFailure) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text.failure(failure))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            NotchPillButton(title: text.retry) { chat.retry() }
        }
        .font(.system(size: 11))
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .topLeading) {
                PlainTextEditor(text: $chat.draft, fontSize: Self.textSize, textColor: .white,
                                textContainerInset: Self.editorInset,
                                onCommandReturn: { chat.send() },
                                onReturn: { chat.send() }) { view in
                    view.insertionPointColor = .white
                    editor.view = view
                    DispatchQueue.main.async { focusEditor() }
                }
                if chat.draft.isEmpty {
                    Text(text.placeholder)
                        .font(.system(size: Self.textSize))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.leading, Self.editorInset.width + PlainTextEditor.lineFragmentPadding)
                        .padding(.top, Self.editorInset.height)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: editorHeight)
            .modifier(NotchControlSurface(cornerRadius: 12, interactive: false))
            sendButton
        }
        .animation(spring, value: editorHeight)
    }

    /// One to four lines, by the draft's line breaks and a rough count of
    /// where its long lines wrap.
    private var editorHeight: CGFloat {
        let perLine = max(1, (size.width - 60) / (Self.textSize * 0.55))
        let lines = chat.draft.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, Int((CGFloat($1.count) / perLine).rounded(.up))) }
        return CGFloat(min(4, max(1, lines))) * 16 + Self.editorInset.height * 2 + 2
    }

    private var canSend: Bool { !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var sendButton: some View {
        let busy = chat.isBusy
        return Button {
            if busy { chat.stop() } else { chat.send() }
        } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(busy || canSend ? Color.black : Color.white.opacity(0.4))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 30, height: 30)
                .background(Circle().fill(busy || canSend ? Color.white : Color.white.opacity(0.1)))
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: busy)
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: canSend)
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 15))
        .disabled(!busy && !canSend)
        .help(busy ? text.stop : text.send)
        .accessibilityLabel(busy ? text.stop : text.send)
        .padding(.bottom, 1)
    }

    /// Only once the island already has the keyboard: showing the page
    /// must not take it from the app in front.
    private func focusEditor() {
        guard let view = editor.view, let window = view.window, window.isKeyWindow else { return }
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    }
}

/// The Chat tab's end of the island's top row: the model in use and a new chat.
struct NotchChatBandControls: View {
    @ObservedObject private var chat = NotchChatService.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.notchChatProviders) private var storedProviders = ""
    @AppStorage(DefaultsKey.notchChatModel) private var storedModel = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Lit for a moment when the model changes.
    @State private var flash = false
    private var text: NotchChatStrings { FeatureStrings.notchChat(l10n.language) }

    var body: some View {
        let _ = (storedProviders, storedModel)
        let current = chat.selection.map { "\($0.provider.id):\($0.model)" }
        HStack(spacing: 2) {
            if let selection = chat.selection {
                modelMenu(selection)
                NotchIconButton(symbol: "square.and.pencil", title: text.newChat) { chat.newChat() }
                    .disabled(chat.messages.isEmpty && !chat.isBusy)
            }
        }
        .onChange(of: current) { old, _ in
            guard old != nil, !reduceMotion else { return }
            flash = true
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { flash = false }
        }
    }

    private func modelMenu(_ selection: (provider: ChatProvider, model: String)) -> some View {
        let usable = chat.providers.filter { $0.enabled && !$0.models.isEmpty }
        var items: [NotchMenuItem] = []
        for provider in usable {
            if !items.isEmpty { items.append(.separator) }
            // A provider's name heads its models when there is more than one to tell apart.
            if usable.count > 1 { items.append(NotchMenuItem(title: provider.name, enabled: false)) }
            for model in provider.models {
                let current = provider.id == selection.provider.id && model == selection.model
                items.append(NotchMenuItem(title: model, checked: current) { chat.choose(provider: provider, model: model) })
            }
        }
        return NotchMenuButton(title: text.model, items: items, cornerRadius: 9) {
            HStack(spacing: 5) {
                Circle().fill(selection.provider.tint).frame(width: 6, height: 6)
                Text(selection.model).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 7)
            .frame(maxWidth: 170)
            .frame(height: 28)
            .background(selection.provider.tint.opacity(flash ? 0.35 : 0),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// An assistant reply: prose as inline Markdown, code in cards of its own,
/// a model's thinking left out, and a copy button once it is written.
private struct NotchChatReply: View {
    let message: ChatMessage
    let streaming: Bool
    let textSize: CGFloat
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var copied: String?

    var body: some View {
        let shown = NotchChatSupport.visible(message.text)
        let blocks = NotchChatSupport.blocks(shown)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                let last = index == blocks.count - 1
                switch block {
                case .text(let prose):
                    if streaming && last {
                        cursorText(prose)
                    } else {
                        Text(Self.markdown(prose))
                    }
                case .code(let language, let code):
                    codeCard(language: language, code: code)
                }
            }
            // A reasoning model still thinking has nothing to show yet.
            if blocks.isEmpty, streaming { NotchChatTypingDots() }
            if !streaming, !shown.isEmpty {
                copyButton(shown, id: "reply")
                    .opacity(hovering || copied == "reply" ? 1 : 0)
            }
        }
        .font(.system(size: textSize))
        .foregroundStyle(.white.opacity(0.9))
        .tint(.white)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
    }

    /// The words so far with a cursor after them, blinking unless motion is reduced.
    private func cursorText(_ prose: String) -> some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let on = reduceMotion || Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0
            var cursor = AttributedString(" ▍")
            cursor.foregroundColor = .white.opacity(on ? 0.7 : 0)
            return Text(Self.markdown(prose) + cursor)
        }
    }

    private func codeCard(language: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 6)
                if !streaming { copyButton(code, id: code) }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
            .frame(height: 24)
            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: textSize - 1, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.never)
        }
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)))
    }

    private func copyButton(_ value: String, id: String) -> some View {
        let strings = FeatureStrings.clipboard(l10n.language)
        let done = copied == id
        return Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareVorssaintSource()
            pasteboard.setString(value, forType: .string)
            copied = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copied == id { copied = nil } }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: done ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                Text(done ? strings.copied : strings.copy)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(done ? 0.9 : 0.55))
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 6))
        .accessibilityLabel(strings.copy)
    }

    /// Inline Markdown, line breaks kept; text that does not parse shows as written.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Three dots in a wave while the reply has not started; still ones under Reduce Motion.
private struct NotchChatTypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3) { index in
                    let wave = reduceMotion ? 0 : max(0, sin((time * 2 * .pi / 1.1) - Double(index) * 0.7))
                    Circle()
                        .fill(.white.opacity(0.35 + 0.45 * wave))
                        .frame(width: 5, height: 5)
                        .offset(y: -2.5 * wave)
                }
            }
            .frame(height: 12)
        }
    }
}

