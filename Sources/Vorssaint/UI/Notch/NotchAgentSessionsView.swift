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

    /// Ending a session needs the Kill Process feature, as freeing a port does;
    /// read again when features change.
    private var canEnd: Bool {
        _ = features.revision
        return !preview && AppFeature.killProcess.isAvailable
    }

    var body: some View {
        let canEnd = canEnd
        VStack(alignment: .leading, spacing: 3) {
            ForEach(sessions) { session in
                NotchAgentSessionRow(session: session, turn: session.log.flatMap { turns[$0] }, now: now, text: text,
                                     preview: preview,
                                     canEnd: canEnd && !session.isSubagent, selected: selected == session.id,
                                     open: { open(session, $0) }) {
                    selected = selected == session.id ? nil : session.id
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

    private func end() { AgentSessionsService.shared.kill(session) }

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            if session.isSubagent {
                content.accessibilityElement(children: .combine)
            } else {
                // VoiceOver can end a session without revealing the ×.
                if canEnd { pick.accessibilityAction(named: endLabel, end) } else { pick }
            }
            if canEnd {
                Button(action: end) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 16, height: 16)
                        .contentShape(Circle())
                }
                .buttonStyle(NotchButtonStyle(cornerRadius: 8))
                // Out of sight and out of reach until the row is picked.
                .opacity(selected ? 1 : 0)
                .disabled(!selected)
                .accessibilityHidden(!selected)
                .help(endLabel)
                .accessibilityLabel(endLabel)
            }
        }
        .padding(.leading, CGFloat(session.depth) * 12)
    }

    private var pick: some View {
        Button(action: toggle) { content }
            .buttonStyle(NotchButtonStyle(cornerRadius: 6, lifts: false))
            .accessibilityLabel([session.kind.displayName, session.host?.name ?? text.background, folder, statusText,
                                 activity ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
            .accessibilityValue(elapsed)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            line.frame(height: 16)
            if let activity { activityLine(activity) }
            if selected { details }
        }
        .contentShape(Rectangle())
    }

    /// What the session does now, under its folder, and what its turn costs.
    private func activityLine(_ activity: String) -> some View {
        HStack(spacing: 4) {
            Text(activity)
                .foregroundStyle(session.status == .asking ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let files = session.activity?.files, !files.isEmpty {
                NotchAgentDiffCounts(added: files.reduce(0) { $0 + $1.added }, removed: files.reduce(0) { $0 + $1.removed })
            }
            if let turn {
                Text([AgentPricing.displayName(turn.model), turn.cost > 0 ? AgentFormat.cost(turn.cost) : ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .font(.system(size: 9.5))
        .padding(.leading, Self.indent)
        .frame(height: 13)
        .help(session.waitingFor ?? activity)
    }

    /// The prompt the turn answers, the latest reply and the files changed, for a picked session.
    @ViewBuilder private var details: some View {
        if let activity = session.activity, activity.prompt != nil || activity.reply != nil || !activity.files.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let prompt = activity.prompt { detail("person.fill", prompt) }
                if let reply = activity.reply { detail("text.bubble", reply) }
                ForEach(activity.files) { file in
                    Button { open(file) } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.text").font(.system(size: 8)).foregroundStyle(.tertiary)
                            Text(file.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            NotchAgentDiffCounts(added: file.added, removed: file.removed)
                            Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .frame(height: 15)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle(cornerRadius: 5, lifts: false))
                    .help(file.path)
                }
            }
            .padding(.leading, Self.indent)
            .padding(.vertical, 2)
        }
    }

    private func detail(_ symbol: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(value).font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
        }
    }

    /// Past the agent's mark, where the host starts.
    private static let indent: CGFloat = 9 * 1.45 + 1 + 6

    private var line: some View {
        HStack(spacing: 6) {
            glyph
            if !session.isSubagent {
                host
                Text(folder)
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help([session.title, session.cwd].compactMap { $0 }.joined(separator: "\n"))
            } else {
                Text(folder)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ports
            status
            Text(elapsed)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(session.kind.tint)
                .lineLimit(1)
                .frame(minWidth: 34, alignment: .trailing)
            Text(session.memory > 0 ? sessionMemory.string(fromByteCount: session.memory) : "")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    @ViewBuilder private var glyph: some View {
        if let provider = session.kind.provider {
            NotchAgentGlyph(provider: provider, size: 9, working: session.status == .working)
        } else {
            Image(systemName: session.kind.symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(session.kind.tint)
                .frame(width: 9 * 1.45 + 1, height: 9 * 1.45 + 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var host: some View {
        if let host = session.host {
            HStack(spacing: 3) {
                // The example rows have no app to take an icon from.
                if host.pid > 0 {
                    Image(nsImage: ResponsibleProcess.icon(for: host.pid, pointSize: 13)).resizable().frame(width: 13, height: 13)
                } else {
                    Image(systemName: "terminal").font(.system(size: 9)).frame(width: 13, height: 13)
                }
                Text(host.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: 84, alignment: .leading)
        } else {
            Text(text.background)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(maxWidth: 84, alignment: .leading)
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
                NotchAgentPulse(tint: session.kind.tint, size: 3)
            } else if session.status == .asking {
                Circle().fill(.orange).frame(width: 5, height: 5)
            } else {
                Circle().fill(.white.opacity(0.28)).frame(width: 5, height: 5)
            }
        }
        .frame(width: 8, height: 8)
        .help(statusText)
    }
}

/// Lines added and removed, in the colors a diff shows them in.
struct NotchAgentDiffCounts: View {
    let added: Int
    let removed: Int

    var body: some View {
        HStack(spacing: 3) {
            if added > 0 { Text("+\(added)").foregroundStyle(.green) }
            if removed > 0 { Text("\u{2212}\(removed)").foregroundStyle(.red) }
        }
        .font(.system(size: 9.5, weight: .medium))
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
