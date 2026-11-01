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

/// The Sessions card: the first few agents running, and the way to the rest.
struct NotchAgentSessionsCard: View {
    let providers: [AgentProvider]
    let text: NotchAgentStrings
    /// Settings draws it with example rows and scans for nothing.
    let preview: Bool
    let showAll: () -> Void
    @ObservedObject private var service = AgentSessionsService.shared
    @State private var selected: String?

    var body: some View {
        let all = preview ? AgentSessionsSupport.sample(now: Date())
            : AgentSessionsSupport.shown(service.sessions, providers: providers)
        let (rows, hidden) = AgentSessionsSupport.preview(all)
        NotchAgentCardChrome {
            VStack(alignment: .leading, spacing: 5) {
                NotchAgentCardHeader(title: text.sessionsCard, symbol: NotchAgentCard.sessions.symbol)
                if !preview && !service.loaded {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rows.isEmpty {
                    Text(text.noSessions).font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        NotchAgentSessionRows(sessions: rows, now: context.date, text: text, preview: preview,
                                              selected: $selected)
                    }
                }
                Spacer(minLength: 0)
                if hidden > 0 || !service.orphans.isEmpty {
                    Button(action: showAll) {
                        HStack(spacing: 3) {
                            Text(hidden > 0 ? text.seeAllSessions(all.count) : text.orphanedPorts(service.orphans.count))
                                .lineLimit(1)
                            Image(systemName: "chevron.right").imageScale(.small)
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle(cornerRadius: 9, lifts: false))
                    // The Settings preview shows the card; it opens nothing.
                    .disabled(preview)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }
}

/// Every agent running, and the ports its processes left open.
struct NotchAgentSessionsList: View {
    let size: CGSize
    let providers: [AgentProvider]
    let text: NotchAgentStrings
    @ObservedObject private var service = AgentSessionsService.shared
    @State private var selected: String?

    var body: some View {
        let sessions = AgentSessionsSupport.shown(service.sessions, providers: providers)
        Group {
            if !service.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty && service.orphans.isEmpty {
                NotchEmptyView(symbol: NotchAgentCard.sessions.symbol, message: text.noSessions)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: NotchAgentSupport.spacing) {
                        if !sessions.isEmpty {
                            NotchAgentCardChrome {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    NotchAgentSessionRows(sessions: sessions, now: context.date, text: text,
                                                          preview: false, selected: $selected)
                                }
                            }
                        }
                        if !service.orphans.isEmpty { orphans }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
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
    let now: Date
    let text: NotchAgentStrings
    let preview: Bool
    @Binding var selected: String?
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
                NotchAgentSessionRow(session: session, now: now, text: text, preview: preview,
                                     canEnd: canEnd && !session.isSubagent, selected: selected == session.id) {
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
    let now: Date
    let text: NotchAgentStrings
    let preview: Bool
    let canEnd: Bool
    let selected: Bool
    let toggle: () -> Void

    private var statusText: String { session.status == .working ? text.working : text.waiting }
    private var endLabel: String { text.endSession(session.kind.displayName + " " + folder) }
    private var elapsed: String { session.started.map { AgentFormat.clock(now.timeIntervalSince($0)) } ?? "" }
    private var folder: String {
        if session.isSubagent { return session.title ?? session.kind.displayName }
        return session.folder.isEmpty ? session.kind.displayName : session.folder
    }

    private func end() { AgentSessionsService.shared.kill(session) }

    var body: some View {
        HStack(spacing: 4) {
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
        .frame(height: 16)
        .padding(.leading, CGFloat(session.depth) * 12)
    }

    private var pick: some View {
        Button(action: toggle) { content }
            .buttonStyle(NotchButtonStyle(cornerRadius: 6, lifts: false))
            .accessibilityLabel([session.kind.displayName, session.host?.name ?? text.background, folder, statusText]
                .joined(separator: ", "))
            .accessibilityValue(elapsed)
    }

    private var content: some View {
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
        .contentShape(Rectangle())
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
            } else {
                Circle().fill(.white.opacity(0.28)).frame(width: 5, height: 5)
            }
        }
        .frame(width: 8, height: 8)
        .help(statusText)
    }
}
