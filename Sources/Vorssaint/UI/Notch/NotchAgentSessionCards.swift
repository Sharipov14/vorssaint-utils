// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

private let sessionMemory: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    formatter.allowedUnits = [.useMB, .useGB]
    return formatter
}()

/// What every card on the Live tab shares: the clock, the words, and what a tap does.
private struct NotchAgentSessionContext {
    let now: Date
    let text: NotchAgentStrings
    let preview: Bool
    let canEnd: Bool
    let width: CGFloat
    let turns: [String: AgentLiveSession]
    let picks: AgentSessionPicks
    /// The one card open now.
    let openCard: String?
    let flip: (AgentSessionGroup) -> Void
    let pick: (AgentSession) -> Void
    let open: (AgentSession, AgentFileDiff) -> Void

    func isOpen(_ group: AgentSessionGroup) -> Bool { group.id == openCard }

    func isPicked(_ child: AgentSession) -> Bool { child.id == picks.child }

    func turn(of session: AgentSession) -> AgentLiveSession? { session.log.flatMap { turns[$0] } }
}

/// The Live tab's sessions as a list or as tiles, a session's subagents
/// beneath it.
struct NotchAgentSessionCards: View {
    let sessions: [AgentSession]
    /// The usage turn each log is having, for its model and cost.
    let turns: [String: AgentLiveSession]
    let now: Date
    let text: NotchAgentStrings
    let preview: Bool
    let width: CGFloat
    let layout: NotchAgentSessionLayout
    /// The open card and its picked subagent.
    @Binding var picks: AgentSessionPicks
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
        let groups = AgentSessionsSupport.groups(sessions)
        let context = NotchAgentSessionContext(now: now, text: text, preview: preview, canEnd: canEnd, width: width, turns: turns,
                                               picks: picks, openCard: picks.open(in: groups),
                                               flip: { group in change { picks.flip(group.id, in: groups) } },
                                               pick: { child in change { picks.pick(child.id) } }, open: open)
        Group {
            switch layout {
            case .list:
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups) { NotchAgentListCard(group: $0, context: context) }
                }
            case .grid:
                NotchAgentSessionGrid(groups: groups, context: context)
            }
        }
        // What was opened or closed and has since gone, or lost its subagents, is forgotten.
        .onChange(of: Self.keys(groups)) { picks.prune(AgentSessionsSupport.groups(sessions)) }
    }

    private static func keys(_ groups: [AgentSessionGroup]) -> Set<String> {
        Set(groups.flatMap { group in
            [group.children.isEmpty ? group.id : group.id + "+"] + group.children.map(\.id)
        })
    }

    private func change(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.86), update)
    }
}

// MARK: Pieces

extension AgentSession {
    /// The project's folder; a subagent goes by its name.
    fileprivate var shownName: String {
        if isSubagent { return title ?? kind.displayName }
        return folder.isEmpty ? kind.displayName : folder
    }

    fileprivate func elapsed(_ now: Date) -> String {
        started.map { AgentFormat.clock((ended ?? now).timeIntervalSince($0)) } ?? ""
    }

    fileprivate var changes: (added: Int, removed: Int)? {
        guard let files = activity?.files, !files.isEmpty else { return nil }
        return (files.reduce(0) { $0 + $1.added }, files.reduce(0) { $0 + $1.removed })
    }

    /// A subagent's time stops once it is done.
    fileprivate var isDone: Bool { isSubagent && status == .waiting }

    fileprivate func heldContext(_ locale: Locale) -> String? {
        activity?.context.map { AgentFormat.context($0, window: activity?.contextWindow, locale: locale) }
    }

    /// At work in blue, waiting on the person in amber, done in green; nil
    /// where nothing is known either way.
    fileprivate var toneColor: Color? {
        switch AgentSessionsSupport.tone(of: self) {
        case .working: return Color(red: 0.36, green: 0.64, blue: 1)
        case .asking: return Color(red: 1, green: 0.62, blue: 0.22)
        case .done: return Color(red: 0.3, green: 0.82, blue: 0.46)
        case .idle: return nil
        }
    }

    fileprivate var toneStyle: AnyShapeStyle { toneColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary) }
}

/// The square a card starts with: the app the session runs in, the agent's
/// mark at its corner; in the background, the agent alone. A subagent's is
/// the companion in the agent's colors.
private struct NotchAgentSessionPlaque: View {
    let session: AgentSession
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        content
            .frame(width: size, height: size)
            .background(.white.opacity(0.08), in: shape)
            .overlay(shape.strokeBorder(.white.opacity(0.08)))
            .overlay(alignment: .bottomTrailing) {
                if !session.isSubagent && session.host != nil {
                    mark(size * 0.24, working: session.status == .working)
                        .frame(width: size * 0.46, height: size * 0.46)
                        .background(Color(white: 0.14), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.12)))
                        .offset(x: size * 0.14, y: size * 0.14)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if session.isSubagent {
            if NotchMascotSupport.isEnabled() {
                NotchMascotView(look: NotchMascotSupport.look(for: session.kind.provider),
                                mood: session.status == .working ? .determined : .happy, size: size * 0.8)
                    .frame(width: size * 0.8, height: size * 0.8)
            } else {
                mark(size * 0.42, working: session.status == .working)
            }
        } else if let host = session.host {
            // The example rows have no app to take an icon from.
            if host.pid > 0 {
                Image(nsImage: ResponsibleProcess.icon(for: host.pid, pointSize: size * 0.7))
                    .resizable()
                    .frame(width: size * 0.7, height: size * 0.7)
            } else {
                Image(systemName: "terminal").font(.system(size: size * 0.38)).foregroundStyle(.secondary)
            }
        } else {
            mark(size * 0.42, working: session.status == .working)
        }
    }

    @ViewBuilder private func mark(_ size: CGFloat, working: Bool) -> some View {
        if let provider = session.kind.provider {
            NotchAgentGlyph(provider: provider, size: size, working: working)
        } else {
            Image(systemName: session.kind.symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(session.kind.tint)
        }
    }
}

/// The status dot and how long the session has run, in the agent's color;
/// under it, the context the session holds.
private struct NotchAgentSessionClock: View {
    let session: AgentSession
    let now: Date
    let text: NotchAgentStrings
    var size: CGFloat = 13
    /// As wide as the longest usual time, so the dots of a column line up.
    var reserves = true
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            time
            if let held = session.heldContext(locale) {
                HStack(spacing: 3) {
                    Image(systemName: "brain").font(.system(size: max(9, size - 4))).foregroundStyle(.tertiary)
                    Text(held).monospacedDigit()
                }
                .font(.system(size: max(10, size - 2.5)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(text.context(held))
            }
        }
        .fixedSize()
    }

    private var time: some View {
        HStack(spacing: 5) {
            // Over a blank, so the time's baseline is the row's: the pulse,
            // an AppKit view, has a baseline of its own.
            Color.clear.frame(width: 10, height: 10).overlay {
                if AgentSessionsSupport.tone(of: session) == .working {
                    NotchAgentPulse(tint: session.toneColor ?? session.kind.tint, size: 4)
                } else {
                    Circle().fill(session.toneColor ?? .white.opacity(0.28)).frame(width: 7, height: 7)
                }
            }
            ZStack(alignment: .trailing) {
                if reserves { Text("00:00:00").hidden() }
                Text(session.elapsed(now)).foregroundStyle(session.toneStyle)
            }
            .font(.system(size: size, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
        }
        .help(statusText)
    }

    private var statusText: String {
        if session.isDone { return text.done }
        switch session.status {
        case .working: return text.working
        case .waiting: return text.waiting
        case .asking: return text.asking
        }
    }
}

private struct NotchAgentSquareButton: View {
    let symbol: String
    let label: String
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(tint ?? .white.opacity(0.78))
                .frame(width: 26, height: 26)
                .background((tint ?? .white).opacity(tint == nil ? 0.1 : 0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 8))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Ends a session, in red, in the header of its opened card.
private struct NotchAgentEndButton: View {
    let session: AgentSession
    let context: NotchAgentSessionContext

    var body: some View {
        if context.canEnd && !session.isSubagent {
            NotchAgentSquareButton(symbol: "xmark", label: context.text.endSession(session.kind.displayName + " " + session.shownName),
                                   tint: Color(red: 1, green: 0.36, blue: 0.34)) {
                AgentSessionsService.shared.kill(session)
            }
        }
    }
}

private struct NotchAgentMemory: View {
    let bytes: Int64

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "memorychip").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(sessionMemory.string(fromByteCount: bytes))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .fixedSize()
    }
}

/// A short word in a capsule, or a chip with its symbol.
private struct NotchAgentCapsule<Icon: View>: View {
    let title: String
    var tint: Color = .white
    @ViewBuilder var icon: Icon

    var body: some View {
        HStack(spacing: 4) {
            icon
            Text(title).lineLimit(1)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(tint == .white ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(tint.opacity(tint == .white ? 0.09 : 0.16), in: Capsule(style: .continuous))
    }
}

extension NotchAgentCapsule where Icon == EmptyView {
    init(title: String, tint: Color = .white) {
        self.init(title: title, tint: tint) { EmptyView() }
    }
}

/// The last minute of the session's CPU, drawn low behind a card's foot: a
/// smooth line over a tinted fill, both fading out toward the older samples.
private struct NotchAgentLoadWave: View {
    let session: AgentSession

    var body: some View {
        if session.load.count >= 2 {
            let tint = session.kind.tint
            let peak = max(session.load.max() ?? 0, 20)
            ZStack {
                NotchAgentWave(values: session.load, peak: peak, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.42), tint.opacity(0.04)], startPoint: .top, endPoint: .bottom))
                NotchAgentWave(values: session.load, peak: peak, closed: false)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
            .mask(LinearGradient(colors: [.clear, .black.opacity(0.7), .black], startPoint: .leading, endPoint: .trailing))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}

/// Samples joined by curves through their midpoints, closed down to the
/// bottom edge for a fill.
private struct NotchAgentWave: Shape {
    let values: [Double]
    let peak: Double
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }
        // A little room above, so the line at its peak is not cut.
        let top = rect.minY + 2
        let points = values.enumerated().map { index, value in
            CGPoint(x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                    y: rect.maxY - (rect.maxY - top) * CGFloat(min(1, max(0, value / peak))))
        }
        path.move(to: points[0])
        for (point, next) in zip(points, points.dropFirst()) {
            path.addQuadCurve(to: CGPoint(x: (point.x + next.x) / 2, y: (point.y + next.y) / 2), control: point)
        }
        path.addLine(to: points[points.count - 1])
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// What the session's card reads to VoiceOver, and what it offers.
private struct NotchAgentSessionAccessibility: ViewModifier {
    let session: AgentSession
    let context: NotchAgentSessionContext
    let open: Bool
    @Environment(\.locale) private var locale

    func body(content: Content) -> some View {
        let text = context.text
        let end = text.endSession(session.kind.displayName + " " + session.shownName)
        let show = session.host.flatMap { session.isSubagent ? nil : text.showIn($0.name) }
        content
            .accessibilityLabel([session.kind.displayName,
                                 session.isSubagent ? "" : session.host?.name ?? text.background, session.shownName,
                                 session.task ?? "", text.activity(of: session) ?? text.state(of: session)]
                .filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityValue([session.elapsed(context.now), session.heldContext(locale).map(text.context) ?? ""]
                .filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityAddTraits(open ? .isSelected : [])
            // VoiceOver reaches opening and ending without revealing their buttons.
            .accessibilityActions {
                if let show, !context.preview { Button(show) { NotchAgentSessionActions.show(session) } }
                if context.canEnd && !session.isSubagent { Button(end) { AgentSessionsService.shared.kill(session) } }
            }
    }
}

private enum NotchAgentSessionActions {
    static func show(_ session: AgentSession) {
        NotchService.shared.collapse()
        AgentSessionsService.shared.show(session)
    }
}

/// A card's tap target: the whole of it, picked as one.
private struct NotchAgentCardButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label

    var body: some View {
        Button(action: action) { label.contentShape(Rectangle()) }
            .buttonStyle(NotchButtonStyle(cornerRadius: 14, lifts: false, highlights: false))
    }
}

/// An opened card's model and cost, its prompt and latest reply, and the
/// files it changed behind Show all. A subagent names its own model.
private struct NotchAgentSessionDetails: View {
    let session: AgentSession
    let context: NotchAgentSessionContext
    /// Grid cards carry the model and cost in their chips already.
    var showsModel = true
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsFiles = false

    private var text: NotchAgentStrings { context.text }

    private var model: String? {
        (context.turn(of: session)?.model ?? session.activity?.model).map(AgentPricing.displayName).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var cost: String? {
        context.turn(of: session).flatMap { $0.cost > 0 ? AgentFormat.cost($0.cost, locale: locale) : nil }
    }

    static func hasContent(_ session: AgentSession, context: NotchAgentSessionContext, showsModel: Bool = true) -> Bool {
        let activity = session.activity
        return activity?.prompt != nil || activity?.reply != nil || activity?.files.isEmpty == false
            || (showsModel && (activity?.model != nil || context.turn(of: session) != nil))
    }

    var body: some View {
        let activity = session.activity
        let files = activity?.files ?? []
        VStack(alignment: .leading, spacing: 8) {
            if showsModel && (model != nil || cost != nil) {
                HStack(spacing: 10) {
                    if let model { fact(nil, model) }
                    if model != nil, cost != nil { Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: 14) }
                    if let cost { fact("dollarsign.circle", text.cost(cost)) }
                }
            }
            if activity?.prompt != nil || activity?.reply != nil { actions(activity) }
            if !files.isEmpty { filesFooter(files) }
        }
    }

    private func fact(_ symbol: String?, _ value: String) -> some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5)).foregroundStyle(.tertiary)
            } else if let provider = session.kind.provider {
                NotchAgentMark(provider: provider, size: 10.5)
            }
            Text(value).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
        }
    }

    /// What was asked and the latest reply, as points in a plate.
    private func actions(_ activity: AgentActivity?) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble").font(.system(size: 10.5)).foregroundStyle(session.kind.tint)
                Text(text.recentActions).font(.system(size: 11.5, weight: .semibold))
            }
            .accessibilityAddTraits(.isHeader)
            if let prompt = activity?.prompt { point(prompt, symbol: "person.fill") }
            if let reply = activity?.reply { point(reply, symbol: nil) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.07)))
    }

    private func point(_ value: String, symbol: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 8))
                } else {
                    Circle().frame(width: 4, height: 4)
                }
            }
            .foregroundStyle(session.kind.tint.opacity(0.85))
            .frame(width: 8)
            .accessibilityHidden(true)
            Text(value).font(.system(size: 11)).foregroundStyle(.white.opacity(0.78)).lineLimit(3)
        }
    }

    private func filesFooter(_ files: [AgentFileDiff]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showsFiles.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Text(text.changedFiles(files.count)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Text(showsFiles ? text.showLess : text.showAll).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Image(systemName: showsFiles ? "chevron.up" : "chevron.down").font(.system(size: 8.5, weight: .semibold))
                    }
                    .foregroundStyle(session.kind.tint)
                }
                .frame(height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle(cornerRadius: 5, lifts: false))
            .accessibilityAddTraits(showsFiles ? .isSelected : [])
            if showsFiles {
                ForEach(files) { file in
                    Button { context.open(session, file) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "doc.text").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            Text(file.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            NotchAgentDiffCounts(added: file.added, removed: file.removed, size: 10.5)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .frame(height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle(cornerRadius: 5, lifts: false))
                    .help(file.path)
                    .transition(.opacity)
                }
            }
        }
    }
}

/// What a subagent does now, or that it is done; another agent the
/// session started says what it does.
private struct NotchAgentChildStep: View {
    let session: AgentSession
    let text: NotchAgentStrings
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 4) {
            if session.isDone {
                Image(systemName: "checkmark").font(.system(size: size - 2, weight: .bold))
                Text(text.done)
            } else {
                // The target goes first where the room is short, then the verb is cut.
                ViewThatFits(in: .horizontal) {
                    Text(text.activity(of: session) ?? text.state(of: session)).fixedSize()
                    Text(text.state(of: session))
                }
                .help(text.activity(of: session) ?? text.state(of: session))
            }
        }
        .font(.system(size: size))
        .foregroundStyle(session.toneStyle)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

// MARK: List

/// A session's card in the list: its app, folder and what it does, what it
/// holds, how long it has run, and the way to its window. Opened, it shows
/// its subagents as a tree, or else its details.
private struct NotchAgentListCard: View {
    let group: AgentSessionGroup
    let context: NotchAgentSessionContext

    private var session: AgentSession { group.session }
    private var open: Bool { context.isOpen(group) }
    private var text: NotchAgentStrings { context.text }
    private static let inset: CGFloat = 12
    private static let plaque: CGFloat = 34

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                NotchAgentCardButton(action: { context.flip(group) }) { summary }
                    .modifier(NotchAgentSessionAccessibility(session: session, context: context, open: open))
                trailing
            }
            .padding(.horizontal, Self.inset)
            .padding(.vertical, 9)
            if open {
                Group {
                    if group.children.isEmpty {
                        if NotchAgentSessionDetails.hasContent(session, context: context) {
                            NotchAgentSessionDetails(session: session, context: context)
                                .padding(.leading, Self.inset + Self.plaque + 10)
                                .padding(.trailing, Self.inset)
                                .padding(.bottom, 10)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            tree
                            if let child = context.picks.picked(in: group) {
                                NotchAgentChildDetails(session: child, context: context)
                                    .padding(.leading, Self.inset)
                                    .transition(.opacity.combined(with: .offset(y: -6)))
                            }
                        }
                        .padding(.trailing, Self.inset)
                        .padding(.bottom, 8)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .modifier(NotchControlSurface(cornerRadius: 14, selected: open, interactive: false))
        .overlay { shape.strokeBorder(session.kind.tint.opacity(open ? 0.45 : 0)).allowsHitTesting(false) }
    }

    /// Opening is always at hand; a card with nothing to open keeps its time in
    /// the column. Opened, the card can end the session.
    @ViewBuilder private var trailing: some View {
        if open { NotchAgentEndButton(session: session, context: context) }
        if let host = session.host {
            NotchAgentSquareButton(symbol: "arrow.up.forward", label: text.showIn(host.name)) {
                NotchAgentSessionActions.show(session)
            }
            .disabled(context.preview)
        } else {
            Color.clear.frame(width: 26, height: 26)
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            NotchAgentSessionPlaque(session: session, size: Self.plaque)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.shownName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help([session.title, session.cwd].compactMap { $0 }.joined(separator: "\n"))
                    NotchAgentPorts(session: session)
                }
                subtitle
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            divider
            VStack(alignment: .leading, spacing: 3) {
                if session.memory > 0 { NotchAgentMemory(bytes: session.memory) }
                if let changes = session.changes {
                    NotchAgentDiffCounts(added: changes.added, removed: changes.removed, size: 11.5)
                }
            }
            .frame(minWidth: 62, alignment: .leading)
            divider
            NotchAgentSessionClock(session: session, now: context.now, text: text)
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 26).accessibilityHidden(true)
    }

    /// Where it runs and what it does, in its tone; with subagents, how many,
    /// and which way the card folds.
    private var subtitle: some View {
        let activity = text.activity(of: session)
        let state = (group.children.isEmpty ? activity : activity ?? text.state(of: session))
            .map { Text($0).foregroundStyle(session.toneStyle) }
        let parts = group.children.isEmpty
            ? [Text(session.host?.name ?? text.background), state]
            : [state, Text(text.subagents(group.children.count))]
        return HStack(spacing: 3) {
            (parts.compactMap { $0 }.reduce(nil as Text?) { line, part in line.map { $0 + Text(" \u{00B7} ") + part } ?? part } ?? Text(""))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !group.children.isEmpty {
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .help(session.waitingFor ?? activity ?? "")
    }

    /// Each subagent on a branch from under the session's plaque.
    private var tree: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(group.children.enumerated()), id: \.element.id) { index, child in
                HStack(alignment: .top, spacing: 0) {
                    NotchAgentBranch(last: index == group.children.count - 1, joint: 20)
                        .stroke(.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    NotchAgentListChild(session: child, context: context)
                }
            }
        }
        .padding(.leading, Self.inset + Self.plaque / 2)
    }
}

/// A line down the side of a session's subagents, branching to each.
private struct NotchAgentBranch: Shape {
    let last: Bool
    /// How far down the row its branch leaves.
    let joint: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + 0.5, bend: CGFloat = 5
        path.move(to: CGPoint(x: x, y: rect.minY))
        if last {
            path.addLine(to: CGPoint(x: x, y: joint - bend))
            path.addQuadCurve(to: CGPoint(x: x + bend, y: joint), control: CGPoint(x: x, y: joint))
        } else {
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
            path.move(to: CGPoint(x: x, y: joint))
            path.addLine(to: CGPoint(x: x + bend, y: joint))
        }
        path.addLine(to: CGPoint(x: rect.maxX - 2, y: joint))
        return path
    }
}

/// A subagent, or an agent the session started, on its branch: its name
/// over its task, what it does now and how long it has run. Picked, it is
/// marked, and its details show under the session's subagents.
private struct NotchAgentListChild: View {
    let session: AgentSession
    let context: NotchAgentSessionContext

    private var picked: Bool { context.isPicked(session) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 8) {
            NotchAgentCardButton(action: { context.pick(session) }) {
                HStack(spacing: 8) {
                    NotchAgentSessionPlaque(session: session, size: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.shownName).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if let task = session.task ?? (session.isSubagent ? nil : session.host?.name) {
                            Text(task).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 6)
                    NotchAgentChildStep(session: session, text: context.text)
                        .frame(maxWidth: 120, alignment: .trailing)
                    NotchAgentSessionClock(session: session, now: context.now, text: context.text, size: 12, reserves: false)
                }
            }
            .modifier(NotchAgentSessionAccessibility(session: session, context: context, open: picked))
            if !session.isSubagent, let host = session.host {
                NotchAgentSquareButton(symbol: "arrow.up.forward", label: context.text.showIn(host.name)) {
                    NotchAgentSessionActions.show(session)
                }
                .disabled(context.preview)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(session.kind.tint.opacity(picked ? 0.12 : 0), in: shape)
        .overlay { shape.strokeBorder(session.kind.tint.opacity(picked ? 0.4 : 0)).allowsHitTesting(false) }
    }
}

/// The picked subagent's details, under all of the session's subagents;
/// picking another one changes what it shows.
private struct NotchAgentChildDetails: View {
    let session: AgentSession
    let context: NotchAgentSessionContext

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Group {
                    Text(session.shownName).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(session.kind.tint)
                    if let task = session.task {
                        Text(task).font(.system(size: 11)).foregroundStyle(.secondary).truncationMode(.tail)
                    }
                }
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                NotchAgentEndButton(session: session, context: context)
            }
            if NotchAgentSessionDetails.hasContent(session, context: context) {
                NotchAgentSessionDetails(session: session, context: context)
            }
        }
        // Each subagent keeps its own Show all.
        .id(session.id)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(session.kind.tint.opacity(0.06), in: shape)
        .overlay(shape.strokeBorder(session.kind.tint.opacity(0.3)))
    }
}

/// A session's listening ports, as on the old rows.
private struct NotchAgentPorts: View {
    let session: AgentSession

    var body: some View {
        let numbers = Array(Set(session.ports.map(\.port))).sorted()
        if !numbers.isEmpty {
            HStack(spacing: 3) {
                ForEach(numbers.prefix(2), id: \.self) { NotchAgentChip(text: ":\($0)", tint: session.kind.tint) }
                if numbers.count > 2 { NotchAgentChip(text: "+\(numbers.count - 2)", tint: session.kind.tint) }
            }
            .fixedSize()
            .help(numbers.map { ":\($0)" }.joined(separator: " "))
        }
    }
}

// MARK: Tiles

/// Sessions as tiles two to a row; one with subagents, or opened, takes the
/// whole row.
private struct NotchAgentSessionGrid: View {
    let groups: [AgentSessionGroup]
    let context: NotchAgentSessionContext

    private func wide(_ group: AgentSessionGroup) -> Bool { !group.children.isEmpty || context.isOpen(group) }

    var body: some View {
        let rows = AgentSessionsSupport.rows(groups, columns: context.width >= NotchAgentSupport.pairWidth ? 2 : 1, wide: wide)
        VStack(spacing: 6) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: 6) {
                    ForEach(row) { group in
                        if wide(group) {
                            NotchAgentWideTile(group: group, context: context)
                        } else {
                            NotchAgentSessionTile(session: group.session, context: context) { context.flip(group) }
                        }
                    }
                }
                // A row is as tall as its tallest tile.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NotchAgentSessionTile: View {
    let session: AgentSession
    let context: NotchAgentSessionContext
    let flip: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        NotchAgentCardButton(action: flip) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 9) {
                    NotchAgentSessionPlaque(session: session, size: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        // The name shares its row with the way to the session's window,
                        // laid over the card; the time goes by the state, under it.
                        HStack(spacing: 4) {
                            Text(session.shownName)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 4)
                            // Kept with no window to go to, so the times of a row line up.
                            Color.clear.frame(width: 26, height: 26)
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            NotchAgentCapsule(title: context.text.state(of: session), tint: session.toneColor ?? .white)
                            Spacer(minLength: 2)
                            NotchAgentSessionClock(session: session, now: context.now, text: context.text, size: 12, reserves: false)
                        }
                    }
                }
                Spacer(minLength: 10)
                HStack(spacing: 6) {
                    if session.memory > 0 { NotchAgentMemory(bytes: session.memory) }
                    Spacer(minLength: 4)
                    if let changes = session.changes {
                        NotchAgentDiffCounts(added: changes.added, removed: changes.removed, size: 11.5)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(alignment: .bottomTrailing) {
                NotchAgentLoadWave(session: session).frame(height: 38).padding(.leading, 40)
            }
            .clipShape(shape)
            .help(session.host?.name ?? context.text.background)
        }
        .modifier(NotchAgentSessionAccessibility(session: session, context: context, open: false))
        .overlay(alignment: .topTrailing) {
            if let host = session.host {
                NotchAgentSquareButton(symbol: "arrow.up.forward", label: context.text.showIn(host.name)) {
                    NotchAgentSessionActions.show(session)
                }
                .disabled(context.preview)
                .padding(10)
            }
        }
        .modifier(NotchControlSurface(cornerRadius: 14, interactive: false))
    }
}

/// A session across the whole row: its chips by its name, and once opened
/// its subagents as tiles of their own, or else its details.
private struct NotchAgentWideTile: View {
    let group: AgentSessionGroup
    let context: NotchAgentSessionContext
    @Environment(\.locale) private var locale

    private var session: AgentSession { group.session }
    private var open: Bool { context.isOpen(group) }
    private var text: NotchAgentStrings { context.text }

    private var model: String? {
        (context.turn(of: session)?.model ?? session.activity?.model).map(AgentPricing.displayName).flatMap { $0.isEmpty ? nil : $0 }
    }

    private var cost: String? {
        context.turn(of: session).flatMap { $0.cost > 0 ? AgentFormat.cost($0.cost, locale: locale) : nil }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                NotchAgentCardButton(action: { context.flip(group) }) { header }
                    .modifier(NotchAgentSessionAccessibility(session: session, context: context, open: open))
                if open { NotchAgentEndButton(session: session, context: context) }
                if let host = session.host {
                    NotchAgentSquareButton(symbol: "arrow.up.forward", label: text.showIn(host.name)) {
                        NotchAgentSessionActions.show(session)
                    }
                    .disabled(context.preview)
                }
                NotchAgentSquareButton(symbol: open ? "chevron.up" : "chevron.down", label: open ? text.showLess : text.showAll) {
                    context.flip(group)
                }
            }
            // The chips drop their words, then the model, where the row is short.
            if !group.children.isEmpty || model != nil || cost != nil {
                ViewThatFits(in: .horizontal) {
                    chips(spelled: true, model: true)
                    chips(spelled: false, model: true)
                    chips(spelled: false, model: false)
                }
                .padding(.leading, 46)
                .padding(.top, -2)
            }
            if open && (!group.children.isEmpty || NotchAgentSessionDetails.hasContent(session, context: context, showsModel: false)) {
                Group {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    if group.children.isEmpty {
                        NotchAgentSessionDetails(session: session, context: context, showsModel: false)
                    } else {
                        NotchAgentChildTiles(children: group.children, context: context, width: context.width - 24)
                        if let child = context.picks.picked(in: group) {
                            NotchAgentChildDetails(session: child, context: context)
                                .transition(.opacity.combined(with: .offset(y: -6)))
                        }
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Behind the header, as long as no tiles of subagents sit under it.
        .background(alignment: .topTrailing) {
            if group.children.isEmpty {
                NotchAgentLoadWave(session: session).frame(width: context.width * 0.55, height: 48).opacity(0.5)
            }
        }
        .clipShape(shape)
        .modifier(NotchControlSurface(cornerRadius: 16, selected: open, interactive: false))
        .overlay { shape.strokeBorder(session.kind.tint.opacity(open ? 0.45 : 0.25)).allowsHitTesting(false) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            NotchAgentSessionPlaque(session: session, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(session.shownName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    NotchAgentPorts(session: session)
                }
                NotchAgentCapsule(title: text.state(of: session), tint: session.toneColor ?? .white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NotchAgentSessionClock(session: session, now: context.now, text: text, reserves: false)
        }
    }

    private func chips(spelled: Bool, model shown: Bool) -> some View {
        HStack(spacing: 5) {
            if !group.children.isEmpty {
                NotchAgentCapsule(title: spelled ? text.subagents(group.children.count) : "\(group.children.count)",
                                  tint: session.kind.tint) {
                    Image(systemName: "square.stack.3d.up.fill").font(.system(size: 9))
                }
                .help(text.subagents(group.children.count))
            }
            if shown, let model {
                NotchAgentCapsule(title: model) {
                    if let provider = session.kind.provider { NotchAgentMark(provider: provider, size: 9.5) }
                }
            }
            if let cost {
                NotchAgentCapsule(title: cost) {
                    Image(systemName: "dollarsign.circle").font(.system(size: 9.5))
                }
            }
        }
        .fixedSize()
    }
}

/// A session's subagents as small tiles, as many to a row as fit.
private struct NotchAgentChildTiles: View {
    let children: [AgentSession]
    let context: NotchAgentSessionContext
    let width: CGFloat
    private static let spacing: CGFloat = 6

    var body: some View {
        let columns = AgentSessionsSupport.columns(width: width, minimum: 124, spacing: Self.spacing)
        let rows = AgentSessionsSupport.rows(children, columns: columns) { _ in false }
        VStack(spacing: Self.spacing) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row) { NotchAgentChildTile(session: $0, context: context) }
                    // A short row keeps its tiles the width of the others.
                    if row.count < columns {
                        ForEach(row.count..<columns, id: \.self) { _ in Color.clear.frame(maxWidth: .infinity).frame(height: 0) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct NotchAgentChildTile: View {
    let session: AgentSession
    let context: NotchAgentSessionContext

    private var picked: Bool { context.isPicked(session) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .top, spacing: 6) {
            NotchAgentCardButton(action: { context.pick(session) }) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 7) {
                        NotchAgentSessionPlaque(session: session, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(session.shownName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            if let task = session.task ?? (session.isSubagent ? nil : session.host?.name) {
                                Text(task).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        NotchAgentChildStep(session: session, text: context.text, size: 10.5)
                        Spacer(minLength: 2)
                        NotchAgentSessionClock(session: session, now: context.now, text: context.text, size: 11.5, reserves: false)
                    }
                }
            }
            .modifier(NotchAgentSessionAccessibility(session: session, context: context, open: picked))
            if !session.isSubagent, let host = session.host {
                NotchAgentSquareButton(symbol: "arrow.up.forward", label: context.text.showIn(host.name)) {
                    NotchAgentSessionActions.show(session)
                }
                .disabled(context.preview)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(NotchControlSurface(cornerRadius: 12, selected: picked, interactive: false))
        .overlay { shape.strokeBorder(session.kind.tint.opacity(picked ? 0.55 : 0)).allowsHitTesting(false) }
    }
}
