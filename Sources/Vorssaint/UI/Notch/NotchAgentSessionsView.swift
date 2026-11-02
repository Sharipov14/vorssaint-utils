// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

extension AgentProcessKind {
    /// Hermes has no provider to take its color from.
    var tint: Color { provider?.tint ?? Color(red: 0.66, green: 0.52, blue: 0.95) }
}

private let sessionMemory: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter
}()

/// A changed file of a session, opened in full on the Live tab.
struct AgentDiffTarget: Equatable {
    let session: String
    let path: String
}

extension AgentSessionsService {
    /// The name Claude gave the session asking, or its folder.
    func title(of approval: AgentApproval) -> String {
        let named = approval.session.flatMap { id in
            sessions.first { $0.log?.hasSuffix("/\(id).jsonl") == true }?.title
        }
        if let named, !named.isEmpty { return named }
        return approval.folder.isEmpty ? AgentProvider.claude.displayName : approval.folder
    }
}

/// Claude's requests on their own: the open island shows them as a
/// notification's card, and nothing else.
struct NotchAgentRequests: View {
    @ObservedObject private var approvals = AgentApprovalService.shared
    @ObservedObject private var sessions = AgentSessionsService.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = FeatureStrings.notchAgents(l10n.language)
        VStack(spacing: NotchAgentSupport.spacing) {
            ForEach(approvals.pending) { approval in
                NotchAgentApprovalCard(approval: approval, title: sessions.title(of: approval), text: text)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.86), value: approvals.pending)
        .environment(\.locale, l10n.language.formattingLocale())
    }
}

/// The Live tab: every agent running, and the ports its processes left open.
struct NotchAgentSessionsList: View {
    let size: CGSize
    /// The agents followed, whose sessions show.
    let providers: [AgentProvider]
    /// The agents with cards, each said when it last worked while none runs.
    let recent: [AgentProvider]
    let text: NotchAgentStrings
    /// Settings draws it with example rows and scans for nothing.
    let preview: Bool
    /// The file shown in full instead of the list; its way back is in the island's top row.
    @Binding var diff: AgentDiffTarget?
    @ObservedObject private var service = AgentSessionsService.shared
    @ObservedObject private var usage = AgentUsageService.shared
    @Environment(\.locale) private var locale
    @State private var selected: String?

    var body: some View {
        let sessions = preview ? AgentSessionsSupport.sample(now: Date())
            : AgentSessionsSupport.shown(service.sessions, providers: providers)
        let orphans = preview ? [] : service.orphans
        // The usage reader names a turn after its log, as the sessions do.
        let turns = Dictionary(usage.snapshot.live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let opened = diff.flatMap { target in
            sessions.first { $0.id == target.session }?.activity?.files.first { $0.path == target.path }
        }
        Group {
            if let opened {
                NotchAgentDiffView(file: opened)
            } else if !preview && !service.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty && orphans.isEmpty {
                if recent.isEmpty {
                    NotchEmptyView(symbol: "terminal", message: text.noSessions)
                } else {
                    idle
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: NotchAgentSupport.spacing) {
                        if !sessions.isEmpty {
                            NotchAgentCardChrome {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    NotchAgentSessionRows(sessions: sessions, turns: turns, now: context.date, text: text,
                                                          preview: preview, selected: $selected) { session, file in
                                        diff = AgentDiffTarget(session: session.id, path: file.path)
                                    }
                                }
                            }
                        }
                        if !orphans.isEmpty { self.orphans }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        // A file whose session ended has nothing left to show.
        .onChange(of: opened == nil) { _, gone in if gone { diff = nil } }
    }

    /// No agent runs: when each last worked.
    private var idle: some View {
        NotchAgentCardChrome {
            VStack(alignment: .leading, spacing: 5) {
                Text(text.noSessions).font(.system(size: 10.5)).foregroundStyle(.secondary)
                ForEach(recent) { provider in
                    HStack(spacing: 5) {
                        NotchAgentGlyph(provider: provider, size: 9, working: false)
                        Text(provider.displayName).font(.system(size: 10.5, weight: .medium))
                        Spacer(minLength: 4)
                        Text(usage.snapshot.lastActivity[provider].map {
                            $0.formatted(.relative(presentation: .named, unitsStyle: .abbreviated).locale(locale))
                        } ?? text.idle)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var orphans: some View {
        NotchAgentCardChrome {
            VStack(alignment: .leading, spacing: 5) {
                NotchAgentCardHeader(title: text.orphanedPorts, symbol: "network", tint: .orange) {
                    if AppFeature.killProcess.isAvailable {
                        Button(action: service.killOrphans) {
                            Text(text.closeAll)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                                .padding(.horizontal, 9)
                                .frame(height: 20)
                                .background(Color.orange.opacity(0.2), in: Capsule(style: .continuous))
                                .contentShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(NotchButtonStyle(cornerRadius: 10))
                    }
                }
                Text(text.orphansHint).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(2)
                ForEach(service.orphans) { orphan in
                    HStack(spacing: 6) {
                        Text(orphan.name)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(String(orphan.pid)).font(.system(size: 9.5)).foregroundStyle(.tertiary).monospacedDigit()
                        Spacer(minLength: 4)
                        ForEach(orphan.ports, id: \.self) { NotchAgentChip(text: ":\($0)", tint: .orange) }
                    }
                    .frame(height: 16)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

/// A tool call Claude waits to have allowed, or its questions answered,
/// until the line along its foot runs out and only the terminal asks.
/// Answered, here or elsewhere, it says so a moment, the companion reacting,
/// then goes. A finished turn's card says so with its last reply.
private struct NotchAgentApprovalCard: View {
    let approval: AgentApproval
    /// The name Claude gave the session, or its folder.
    let title: String
    let text: NotchAgentStrings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The state badge pops in once the card is in.
    @State private var popped = false

    private var agent: AgentProvider { approval.agent }
    private static let amber = Color(red: 1, green: 0.62, blue: 0.22)
    private static let teal = Color(red: 0.13, green: 0.83, blue: 0.93)
    private static let radius: CGFloat = 22
    private static let companionSize: CGFloat = 52

    private var outcome: AgentApproval.Outcome? { approval.outcome }
    /// Warm for a permission, cool for a question, green for a finished turn.
    private var tint: Color { approval.isFinish ? .green : approval.isQuestion ? Self.teal : Self.amber }

    private var glow: Color {
        switch outcome {
        case nil: return tint
        case .allowed, .elsewhere: return .green
        case .denied: return Color(white: 0.6)
        }
    }

    private var status: String {
        switch outcome {
        case nil: return approval.isFinish ? text.finished(agent.displayName)
            : approval.isQuestion ? text.asks : text.needsPermission
        case .allowed: return approval.isQuestion ? text.answerSent : text.allowed
        case .denied: return text.denied
        case .elsewhere: return text.answered(in: approval.host)
        }
    }

    private var mood: NotchMascotMood {
        switch outcome {
        case nil: return approval.isFinish ? .happy : .alert
        case .allowed, .elsewhere: return .happy
        case .denied: return .confused
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            companion
            VStack(alignment: .leading, spacing: 8) {
                header
                if approval.isQuestion {
                    NotchAgentQuestionForm(approval: approval, text: text, tint: Self.teal)
                } else if let reply = approval.reply {
                    Text(reply)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .help(reply)
                    finishButtons
                } else {
                    command
                    buttons
                }
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { surface }
        .overlay(alignment: .bottom) {
            // A finished turn waits longer under the pointer, so no line runs out.
            if !approval.isFinish {
                NotchAgentApprovalCountdown(deadline: approval.deadline, wait: approval.wait, tint: tint)
                    .opacity(outcome == nil ? 0.85 : 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .overlay(alignment: .topTrailing) { if !approval.isFinish { terminal } }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: outcome)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    /// A question's text and choices are read from the form itself.
    private var accessibilityTitle: String {
        let parts = approval.isFinish ? [status, title, approval.reply ?? ""]
            : approval.isQuestion ? [agent.displayName, title, status]
            : [text.approval(agent.displayName, tool: approval.tool), title, outcome == nil ? "" : status, approval.detail ?? ""]
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// Dark, lit from below in the color of where it stands.
    private var surface: some View {
        ZStack {
            Color.white.opacity(0.06)
            RadialGradient(colors: [glow.opacity(0.36), glow.opacity(0)], center: UnitPoint(x: 0.45, y: 1.15),
                           startRadius: 0, endRadius: 240)
                .id(outcome.map { "\($0)" } ?? "asking")
                .transition(.opacity)
        }
    }

    /// The companion in the agent's colors, or its mark when the person
    /// turned the companion off.
    private var companion: some View {
        let size = Self.companionSize
        let shown = NotchMascotSupport.isEnabled()
        let reacts = NotchMascotSupport.reacts()
        return Group {
            if shown {
                NotchMascotView(look: NotchMascotSupport.look(for: agent), mood: mood, size: size,
                                cue: reacts && outcome == .allowed ? .celebrate : nil, cueID: outcome == .allowed ? 1 : 0,
                                reaction: reacts ? approval.isFinish ? .celebrate : .perk : nil)
            } else {
                NotchAgentMark(provider: agent, size: size * 0.5)
            }
        }
        .frame(width: size, height: size)
        .background {
            Circle()
                .fill(RadialGradient(colors: [agent.tint.opacity(0.32), agent.tint.opacity(0)], center: .center,
                                     startRadius: 4, endRadius: size))
                .frame(width: size * 2, height: size * 2)
        }
        .overlay(alignment: .topLeading) { badge.offset(x: -4, y: -4) }
        .overlay(alignment: .bottomTrailing) {
            if shown {
                NotchAgentMark(provider: agent, size: 10)
                    .frame(width: 20, height: 20)
                    .background(Color(white: 0.14), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                    .offset(x: 4, y: 4)
            }
        }
        .accessibilityHidden(true)
    }

    /// What the card waits for, or how it ended.
    private var badge: some View {
        let (symbol, tint): (String, Color) = switch outcome {
        case nil: approval.isFinish ? ("checkmark", .green)
            : approval.isQuestion ? ("questionmark", Self.teal) : ("exclamationmark", .orange)
        case .allowed, .elsewhere: ("checkmark", .green)
        case .denied: ("xmark", Color(white: 0.45))
        }
        return Image(systemName: symbol)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(.white)
            .frame(width: 17, height: 17)
            .background(tint, in: Circle())
            .overlay(Circle().strokeBorder(.black.opacity(0.3)))
            .id(symbol)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
            .scaleEffect(popped || reduceMotion ? 1 : 0.3)
            .opacity(popped ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.5).delay(0.2)) { popped = true }
            }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(.white).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .help(approval.cwd ?? title)
            Text(status)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .contentTransition(.opacity)
        }
        // Clear of the way back to the terminal.
        .padding(.trailing, 26)
    }

    /// A command speaks for itself; a path or a query is read with its tool.
    private var command: some View {
        HStack(spacing: 6) {
            if approval.detail != nil && approval.tool != "Bash" {
                // Whole before the path is cut, unless an MCP tool's long name.
                Text(approval.tool).foregroundStyle(.secondary).frame(maxWidth: 150, alignment: .leading).fixedSize()
            }
            Text(approval.detail ?? approval.tool)
                .foregroundStyle(.white.opacity(0.92))
                .truncationMode(.middle)
        }
        .font(.system(size: 13, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .help(approval.detail ?? approval.tool)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            pill(text.deny, fill: .white.opacity(0.12), ink: .white) { answer(false) }
            pill(text.allow, fill: .white, ink: .black) { answer(true) }
            // Only when Claude offers a rule to keep.
            if approval.rules != nil {
                pill(text.always, fill: Self.amber.opacity(0.24), ink: .white) { answer(true, always: true) }
            }
        }
        .disabled(outcome != nil)
    }

    /// To the session's app, by its name, and away.
    private var finishButtons: some View {
        HStack(spacing: 8) {
            if let host = approval.host {
                pill(text.showIn(host), fill: .white, ink: .black) { AgentApprovalService.shared.showSession(of: approval.id) }
            }
            pill(text.ok, fill: .white.opacity(0.12), ink: .white) { AgentApprovalService.shared.dismiss(approval.id) }
        }
    }

    /// Hands the question back and goes to the session, where its app's icon says.
    private var terminal: some View {
        Button { AgentApprovalService.shared.handBack(approval.id) } label: {
            Group {
                if let pid = approval.hostPID {
                    Image(nsImage: ResponsibleProcess.icon(for: pid, pointSize: 16)).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: "apple.terminal").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: 26, height: 26)
            .background(.white.opacity(0.08), in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 13))
        .help(text.askInTerminal)
        .accessibilityLabel(text.askInTerminal)
        .padding(10)
        .opacity(outcome == nil ? 1 : 0)
        .disabled(outcome != nil)
    }

    private func answer(_ allow: Bool, always: Bool = false) {
        AgentApprovalService.shared.answer(approval.id, allow: allow, always: always)
    }
}

/// A card's answer button.
private func pill(_ label: String, fill: Color, ink: Color, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Text(label)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(fill, in: Capsule(style: .continuous))
            .contentShape(Capsule(style: .continuous))
    }
    .buttonStyle(NotchButtonStyle(cornerRadius: 15))
}

/// Claude's questions one at a time, as the terminal asks them: a pick
/// answers one and moves on, the last sending them all. Several picks, or a
/// typed answer, wait for the button.
private struct NotchAgentQuestionForm: View {
    let approval: AgentApproval
    let text: NotchAgentStrings
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    @State private var picks: [[String]]
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var focused: Bool

    init(approval: AgentApproval, text: NotchAgentStrings, tint: Color) {
        self.approval = approval
        self.text = text
        self.tint = tint
        _picks = State(initialValue: Array(repeating: [], count: approval.questions.count))
    }

    private var question: AgentQuestion { approval.questions[min(index, approval.questions.count - 1)] }
    private var isLast: Bool { index >= approval.questions.count - 1 }
    private var picked: [String] { index < picks.count ? picks[index] : [] }
    private var answer: String { typed.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Claude's short name for the question, and which one of how many.
    private var heading: String? {
        let count = approval.questions.count
        let parts = [question.header, count > 1 ? "\(index + 1)/\(count)" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if let heading {
                    Text(heading).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(question.text)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                options
            }
            .id(index)
            .transition(reduceMotion ? .opacity : .push(from: .trailing))
            footer
        }
        .disabled(approval.outcome != nil)
    }

    /// Bare labels go side by side while they fit; described ones, or ones to
    /// tick, one under another.
    @ViewBuilder private var options: some View {
        if !question.multiple && question.options.allSatisfy({ $0.detail == nil }) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(question.options, id: \.label) { option in
                        pill(option.label, fill: .white.opacity(0.1), ink: .white) { pick(option.label) }
                    }
                }
                plates
            }
        } else {
            plates
        }
    }

    private var plates: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(question.options, id: \.label) { plate($0) }
        }
    }

    private func plate(_ option: AgentQuestion.Option) -> some View {
        let on = picked.contains(option.label)
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button { pick(option.label) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if question.multiple {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundStyle(on ? tint : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.system(size: 13, weight: .semibold))
                    if let detail = option.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(on ? tint.opacity(0.22) : .white.opacity(0.07), in: shape)
            .overlay(shape.strokeBorder(on ? tint.opacity(0.55) : .white.opacity(0.08)))
            .contentShape(shape)
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 10, lifts: false))
        .accessibilityAddTraits(on ? .isSelected : [])
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: on)
    }

    /// An answer of one's own, and the button that sends several picks, with
    /// or without it. The cross gives the picks back their own button.
    private var footer: some View {
        HStack(spacing: 8) {
            if typing {
                HStack(spacing: 6) {
                    TextField(text.otherPlaceholder, text: $typed)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit(submitTyped)
                        .onExitCommand(perform: stopTyping)
                        .accessibilityLabel(text.other)
                    Button(action: stopTyping) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(text.cancelTyping)
                    .accessibilityLabel(text.cancelTyping)
                }
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(height: 30)
                .background(.white.opacity(0.07), in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(focused ? 0.55 : 0.2)))
                pill(isLast ? text.send : text.next, fill: .white, ink: .black, action: submitTyped)
                    .disabled(answer.isEmpty && (!question.multiple || picked.isEmpty))
            } else {
                pill(text.other, fill: .white.opacity(0.12), ink: .white, action: startTyping)
                if question.multiple {
                    pill(isLast ? text.send : text.next, fill: .white, ink: .black, action: advance)
                        .disabled(picked.isEmpty)
                }
            }
        }
        .transition(.opacity)
    }

    private func pick(_ label: String) {
        guard index < picks.count else { return }
        guard question.multiple else {
            picks[index] = [label]
            return advance()
        }
        if let at = picks[index].firstIndex(of: label) { picks[index].remove(at: at) } else { picks[index].append(label) }
    }

    /// The island takes the keyboard only now, the person having asked to type.
    private func startTyping() {
        typing = true
        NotchService.shared.presentationWindow?.makeKey()
        DispatchQueue.main.async { focused = true }
    }

    private func stopTyping() {
        typing = false
        typed = ""
    }

    /// The typed answer, joining any picks; an empty field sends the picks alone.
    private func submitTyped() {
        guard index < picks.count else { return }
        if !answer.isEmpty { picks[index] = question.multiple ? picks[index] + [answer] : [answer] }
        guard !picks[index].isEmpty else { return }
        advance()
    }

    private func advance() {
        guard !isLast else { return AgentApprovalService.shared.answer(approval.id, picks: picks) }
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.86)) {
            index += 1
            typing = false
            typed = ""
        }
    }
}

/// The time left to answer, running out along the card's foot in one
/// smooth stroke the render server draws.
private struct NotchAgentApprovalCountdown: View {
    let deadline: Date
    let wait: TimeInterval
    let tint: Color
    @State private var running = false

    var body: some View {
        let left = max(0, deadline.timeIntervalSinceNow)
        Rectangle()
            .fill(tint)
            .frame(height: 2)
            .scaleEffect(x: running ? 0 : left / wait, y: 1, anchor: .leading)
            .onAppear { withAnimation(.linear(duration: left)) { running = true } }
            .accessibilityHidden(true)
    }
}

/// Sessions one under another, a tapped one offering to end it.
private struct NotchAgentSessionRows: View {
    let sessions: [AgentSession]
    /// The usage turn each log is having, for its model and cost.
    let turns: [String: AgentLiveSession]
    let now: Date
    let text: NotchAgentStrings
    let preview: Bool
    @Binding var selected: String?
    let open: (AgentSession, AgentFileDiff) -> Void
    @ObservedObject private var features = FeatureRuntime.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ending a session needs the Kill Process feature, as freeing a port does;
    /// read again when features change.
    private var canEnd: Bool {
        _ = features.revision
        return !preview && AppFeature.killProcess.isAvailable
    }

    var body: some View {
        let canEnd = canEnd
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sessions) { session in
                NotchAgentSessionRow(session: session, turn: session.log.flatMap { turns[$0] }, now: now, text: text,
                                     preview: preview,
                                     canEnd: canEnd && !session.isSubagent, selected: selected == session.id,
                                     open: { open(session, $0) }) {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86)) {
                        selected = selected == session.id ? nil : session.id
                    }
                }
            }
        }
        // A session that ended takes its selection with it.
        .onChange(of: sessions.map(\.id)) { _, ids in
            if let current = selected, !ids.contains(current) { selected = nil }
        }
    }
}

private struct NotchAgentSessionRow: View {
    let session: AgentSession
    let turn: AgentLiveSession?
    let now: Date
    let text: NotchAgentStrings
    let preview: Bool
    let canEnd: Bool
    let selected: Bool
    let open: (AgentFileDiff) -> Void
    let toggle: () -> Void

    private var statusText: String {
        switch session.status {
        case .working: return text.working
        case .waiting: return text.waiting
        case .asking: return text.asking
        }
    }
    private var activity: String? { session.isSubagent ? nil : text.activity(of: session) }
    private var endLabel: String { text.endSession(session.kind.displayName + " " + folder) }
    private var elapsed: String { session.started.map { AgentFormat.clock(now.timeIntervalSince($0)) } ?? "" }
    private var folder: String {
        if session.isSubagent { return session.title ?? session.kind.displayName }
        return session.folder.isEmpty ? session.kind.displayName : session.folder
    }

    /// The app it runs in; a background session has none to show.
    private var showLabel: String? {
        session.host.flatMap { session.isSubagent ? nil : text.showIn($0.name) }
    }

    /// The turn's model and cost, and what the session holds in memory.
    private var meta: String? {
        let parts = [turn.map { AgentPricing.displayName($0.model) },
                     turn.flatMap { $0.cost > 0 ? AgentFormat.cost($0.cost) : nil },
                     session.memory > 0 ? sessionMemory.string(fromByteCount: session.memory) : nil]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func end() { AgentSessionsService.shared.kill(session) }

    private func show() {
        NotchService.shared.collapse()
        AgentSessionsService.shared.show(session)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if session.isSubagent {
                content.accessibilityElement(children: .combine)
            } else {
                // VoiceOver reaches ending without revealing its button.
                pick.accessibilityActions {
                    if let showLabel, !preview { Button(showLabel, action: show) }
                    if canEnd { Button(endLabel, action: end) }
                }
            }
            // Ending waits for the row to be picked; opening is always at hand.
            if canEnd && selected {
                round("xmark", endLabel, action: end).transition(.opacity)
            }
            if let showLabel {
                round("arrow.up.forward", showLabel, action: show).disabled(preview)
            } else {
                // A row with nothing to open keeps its times in the column.
                Color.clear.frame(width: 22, height: 22)
            }
        }
        .padding(.leading, CGFloat(session.depth) * 14)
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 22, height: 22)
                .background(.white.opacity(0.1), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 11))
        .help(label)
        .accessibilityLabel(label)
    }

    private var pick: some View {
        Button(action: toggle) { content }
            .buttonStyle(NotchButtonStyle(cornerRadius: 8, lifts: false))
            .accessibilityLabel([session.kind.displayName, session.host?.name ?? text.background, folder, statusText,
                                 activity ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityValue(elapsed)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            line.frame(height: 22)
            if let activity { activityLine(activity) }
            if let meta {
                Text(meta)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.leading, Self.indent)
                    .frame(height: 14)
            }
            if selected { details }
        }
        .contentShape(Rectangle())
    }

    /// What the session does now, under its folder, and the lines it changed.
    private func activityLine(_ activity: String) -> some View {
        HStack(spacing: 5) {
            Text(activity)
                .foregroundStyle(session.status == .asking ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let files = session.activity?.files, !files.isEmpty {
                NotchAgentDiffCounts(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed },
                                     size: 11)
            }
        }
        .font(.system(size: 11))
        .padding(.leading, Self.indent)
        .frame(height: 15)
        .help(session.waitingFor ?? activity)
    }

    /// The prompt the turn answers, the latest reply and the files changed, for a picked session.
    @ViewBuilder private var details: some View {
        let activity = session.activity
        if activity?.prompt != nil || activity?.reply != nil || activity?.files.isEmpty == false {
            VStack(alignment: .leading, spacing: 3) {
                if let prompt = activity?.prompt { detail("person.fill", prompt) }
                if let reply = activity?.reply { detail("text.bubble", reply) }
                ForEach(activity?.files ?? []) { file in
                    link("doc.text", file.name, action: { open(file) }) {
                        NotchAgentDiffCounts(added: file.added, removed: file.removed, size: 10.5)
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .help(file.path)
                }
            }
            .padding(.leading, Self.indent)
            .padding(.vertical, 3)
        }
    }

    private func link(_ symbol: String, _ title: String, action: @escaping () -> Void,
                      @ViewBuilder trailing: () -> some View) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                Text(title).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                trailing()
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 5, lifts: false))
    }

    private func detail(_ symbol: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
        }
    }

    private static let glyphSize: CGFloat = 11
    /// Past the agent's mark, where the host starts.
    private static let indent: CGFloat = glyphSize * 1.45 + 1 + 7

    private var line: some View {
        HStack(spacing: 7) {
            glyph
            if !session.isSubagent {
                host
                Text(folder)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help([session.title, session.cwd].compactMap { $0 }.joined(separator: "\n"))
            } else {
                Text(folder)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ports
            status
            // As wide as the longest usual time, so the status dots line up.
            ZStack(alignment: .trailing) {
                Text("00:00:00").hidden()
                Text(elapsed).foregroundStyle(session.kind.tint)
            }
            .font(.system(size: 11.5, weight: .medium))
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    @ViewBuilder private var glyph: some View {
        if let provider = session.kind.provider {
            NotchAgentGlyph(provider: provider, size: Self.glyphSize, working: session.status == .working)
        } else {
            Image(systemName: session.kind.symbol)
                .font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundStyle(session.kind.tint)
                .frame(width: Self.glyphSize * 1.45 + 1, height: Self.glyphSize * 1.45 + 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var host: some View {
        if let host = session.host {
            HStack(spacing: 4) {
                // The example rows have no app to take an icon from.
                if host.pid > 0 {
                    Image(nsImage: ResponsibleProcess.icon(for: host.pid, pointSize: 18)).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "terminal").font(.system(size: 12)).frame(width: 18, height: 18)
                }
                Text(host.name).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 96, alignment: .leading)
            .help(host.name)
        } else {
            Text(text.background)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: 96, alignment: .leading)
        }
    }

    @ViewBuilder private var ports: some View {
        let numbers = Array(Set(session.ports.map(\.port))).sorted()
        HStack(spacing: 3) {
            ForEach(numbers.prefix(2), id: \.self) { NotchAgentChip(text: ":\($0)", tint: session.kind.tint) }
            if numbers.count > 2 { NotchAgentChip(text: "+\(numbers.count - 2)", tint: session.kind.tint) }
        }
        .fixedSize()
        .help(numbers.map { ":\($0)" }.joined(separator: " "))
    }

    private var status: some View {
        Group {
            if session.status == .working {
                NotchAgentPulse(tint: session.kind.tint, size: 4)
            } else if session.status == .asking {
                Circle().fill(.orange).frame(width: 7, height: 7)
            } else {
                Circle().fill(.white.opacity(0.28)).frame(width: 7, height: 7)
            }
        }
        .frame(width: 10, height: 10)
        .help(statusText)
    }
}

/// Lines added and removed, in the colors a diff shows them in.
struct NotchAgentDiffCounts: View {
    let added: Int
    let removed: Int
    var size: CGFloat = 9.5

    var body: some View {
        HStack(spacing: 3) {
            if added > 0 { Text("+\(added)").foregroundStyle(.green) }
            if removed > 0 { Text("\u{2212}\(removed)").foregroundStyle(.red) }
        }
        .font(.system(size: size, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
    }
}

/// A changed file's lines, hunk after hunk, as the agent made them.
struct NotchAgentDiffView: View {
    let file: AgentFileDiff

    var body: some View {
        NotchAgentCardChrome {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                    Spacer(minLength: 4)
                    NotchAgentDiffCounts(added: file.added, removed: file.removed)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(file.hunks.indices, id: \.self) { index in
                            if index > 0 {
                                Text("\u{22EF}").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.vertical, 2)
                            }
                            ForEach(file.hunks[index].indices, id: \.self) { line(file.hunks[index][$0]) }
                        }
                        if file.truncated {
                            Text("\u{2026}").font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private func line(_ line: AgentDiffLine) -> some View {
        let (marker, tint): (String, Color?) = switch line.kind {
        case .added: ("+", .green)
        case .removed: ("\u{2212}", .red)
        case .context: (" ", nil)
        }
        return HStack(spacing: 4) {
            Text(marker).foregroundStyle(tint ?? .secondary).frame(width: 8)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundStyle(tint == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.9)))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 3)
        .background((tint ?? .clear).opacity(0.16))
        .help(line.text)
        .accessibilityElement(children: .combine)
    }
}
