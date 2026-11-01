// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin
import Foundation

/// The agents running on this Mac now, for the AI page's Sessions card. It
/// scans only while that card or the full list is on screen, and nothing
/// starts from `init`.
final class AgentSessionsService: ObservableObject {
    static let shared = AgentSessionsService()

    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var orphans: [AgentOrphan] = []
    /// False until the first scan of this showing is done.
    @Published private(set) var loaded = false

    private static let tick: TimeInterval = 2
    /// `lsof` is the dear part of a scan, so its answer is kept between ticks.
    private static let portsTick: TimeInterval = 10
    private static let lsof = ("/usr/sbin/lsof", ["-nP", "+c0", "-iTCP", "-sTCP:LISTEN", "-F", "pcnPT"])

    private let queue = DispatchQueue(label: "com.vorssaint.agent-sessions", qos: .utility)
    private let claudeDirectory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
    // Main thread.
    private var timer: DispatchSourceTimer?
    /// Views showing the sessions. A page that disappears late must not stop
    /// the scan of the one that took its place.
    private var watchers = 0
    /// Bumped at each start and stop, so a scan that outlives its showing publishes nothing.
    private var epoch = 0
    // Confined to `queue`.
    private var listeners: [AgentPort] = []
    private var listenersRead = Date.distantPast
    private var tracked: [Int32: AgentOrphan] = [:]
    private var hosts: [Int32: (identity: UInt64, host: AgentHost?)] = [:]
    /// Where a session keeps its subagents; nil, with the time of the search, while it has none.
    private var subagentFolders: [String: (folder: URL?, searched: Date)] = [:]

    private init() {}

    // MARK: Lifecycle

    func pageDidAppear() {
        watchers += 1
        guard timer == nil, NotchAgentSupport.sectionShows() else { return }
        epoch += 1
        let epoch = epoch
        queue.async { [self] in
            listeners = []
            listenersRead = .distantPast
            tracked = [:]
            hosts = [:]
            subagentFolders = [:]
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.tick, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.scan(epoch: epoch) }
        self.timer = timer
        timer.resume()
    }

    func pageDidDisappear() {
        watchers = max(0, watchers - 1)
        if watchers == 0 { stop() }
    }

    /// Stops whatever is watching, for a feature that is off or a quit.
    func stop() {
        watchers = 0
        guard let timer else { return }
        timer.cancel()
        self.timer = nil
        epoch += 1
        sessions = []
        orphans = []
        loaded = false
    }

    // MARK: Ending

    /// Kills the session like abtop does, at once; a process that could not be
    /// told to quit may be stuck. Needs the Kill Process feature, as Port Manager does.
    func kill(_ session: AgentSession) {
        guard AppFeature.killProcess.isAvailable, !session.isSubagent else { return }
        KillProcessService.shared.kill(pid: session.pid, name: session.kind.displayName,
                                       startedAt: session.identity, force: true) { [weak self] in self?.rescan() }
    }

    /// Asks the listeners politely, once a fresh look shows each is still the
    /// process, on the port, that was left behind.
    func killOrphans() {
        guard AppFeature.killProcess.isAvailable else { return }
        let candidates = orphans
        queue.async { [self] in
            guard let current = Self.readListeners() else { return }
            for orphan in candidates
            where current.contains(where: { $0.pid == orphan.pid && orphan.ports.contains($0.port) })
                && KillProcessService.startTime(for: orphan.pid) == orphan.startedAt {
                KillProcessService.shared.kill(pid: orphan.pid, name: orphan.name, startedAt: orphan.startedAt,
                                               force: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.rescan() }
        }
    }

    private func rescan() {
        guard timer != nil else { return }
        let epoch = epoch
        queue.async { [self] in
            listenersRead = .distantPast
            scan(epoch: epoch)
        }
    }

    // MARK: Scanning

    /// On `queue`.
    private func scan(epoch: Int) {
        guard NotchAgentSupport.sectionShows() else {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }
        let listing = Shell.run("/bin/ps", ["-ww", "-eo", "pid,ppid,pcpu,rss,args"])
        guard listing.status == 0 else { return }
        let rows = AgentSessionsSupport.parseProcesses(listing.output)
        guard !rows.isEmpty else { return }
        var probes: [Int32: AgentProbe] = [:]
        for row in rows where AgentSessionsSupport.mayBeAgent(row.args) {
            if let probe = Self.probe(row) { probes[row.pid] = probe }
        }

        hosts = hosts.filter { probes[$0.key]?.startedAt == $0.value.identity }
        for (pid, probe) in probes where hosts[pid] == nil {
            hosts[pid] = (probe.startedAt, Self.host(of: pid))
        }

        var files: [Int32: AgentClaudeFile] = [:]
        var subagents: [String: [AgentSubagent]] = [:]
        let now = Date()
        for (pid, probe) in probes where probe.kind == .claude {
            let url = claudeDirectory.appending(path: "sessions/\(pid).json")
            guard let file = (try? Data(contentsOf: url)).flatMap(AgentSessionsSupport.parseClaudeFile),
                  AgentSessionsSupport.file(file, matches: probe.startedAt) else { continue }
            files[pid] = file
            subagents[file.sessionId] = workingSubagents(of: file.sessionId, now: now)
        }

        if probes.isEmpty && tracked.isEmpty {
            listeners = []
            listenersRead = .distantPast
        } else if now.timeIntervalSince(listenersRead) >= Self.portsTick, let fresh = Self.readListeners() {
            listeners = fresh
            listenersRead = now
            // What stopped listening is no longer worth remembering.
            let listening = Set(fresh.map(\.pid))
            tracked = tracked.filter { listening.contains($0.key) }
        }

        let sessions = AgentSessionsSupport.sessions(
            rows: rows, probes: probes, claudeFiles: files, subagents: subagents, listeners: listeners,
            hosts: hosts.compactMapValues { $0.host }, ignoring: ProcessInfo.processInfo.processIdentifier)
        tracked = AgentSessionsSupport.tracking(tracked, sessions: sessions, startedAt: KillProcessService.startTime(for:))
        // A pid reused by something else since is not what was remembered.
        let orphans = AgentSessionsSupport.orphans(tracked: tracked, sessions: sessions, listeners: listeners)
            .filter { KillProcessService.startTime(for: $0.pid) == $0.startedAt }

        DispatchQueue.main.async { [self] in
            guard epoch == self.epoch, timer != nil else { return }
            if self.sessions != sessions { self.sessions = sessions }
            if self.orphans != orphans { self.orphans = orphans }
            if !loaded { loaded = true }
        }
    }

    private static func probe(_ row: AgentProcessRow) -> AgentProbe? {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let executable = proc_pidpath(row.pid, &path, UInt32(path.count)) > 0 ? String(cString: path) : nil
        let argv = row.args.split(separator: " ").map(String.init)
        let comm = Self.comm(of: row.pid)
        guard let kind = AgentSessionsSupport.kind(executablePath: executable, comm: comm, argv: argv),
              let startedAt = KillProcessService.startTime(for: row.pid) else { return nil }
        return AgentProbe(kind: kind,
                          launcher: AgentSessionsSupport.isLauncher(executablePath: executable, comm: comm, argv: argv),
                          startedAt: startedAt, cwd: workingDirectory(of: row.pid),
                          requiresFile: AgentSessionsSupport.requiresSessionFile(argv: argv))
    }

    /// The name a process started under, which the kernel keeps after an
    /// update has replaced its binary.
    private static func comm(of pid: pid_t) -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return "" }
        return withUnsafePointer(to: &info.pbi_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    private static func host(of pid: pid_t) -> AgentHost? {
        ResponsibleProcess.regularAppOwner(of: pid).map {
            AgentHost(pid: $0.processIdentifier,
                      name: $0.localizedName ?? ResponsibleProcess.displayName(pid: $0.processIdentifier, fallback: ""))
        }
    }

    /// Nil when `lsof` did not finish.
    private static func readListeners() -> [AgentPort]? {
        let result = Shell.run(lsof.0, lsof.1)
        // lsof exits 1 for an empty list; a negative status is its timeout.
        guard result.status >= 0 else { return nil }
        return AgentSessionsSupport.ports(from: PortManagerSupport.parseLsof(result.output))
    }

    /// Claude keeps a session's subagents under `projects/<folder>/<id>/subagents`,
    /// the folder named after the project; the id is unique, so it is searched for.
    private func workingSubagents(of sessionId: String, now: Date) -> [AgentSubagent] {
        let fileManager = FileManager.default
        let known = subagentFolders[sessionId]
        // A session with no subagents yet is looked for again only now and then.
        if known == nil || (known?.folder == nil && now.timeIntervalSince(known?.searched ?? now) >= 30) {
            let projects = claudeDirectory.appending(path: "projects")
            subagentFolders[sessionId] = (((try? fileManager.contentsOfDirectory(atPath: projects.path)) ?? [])
                .map { projects.appending(path: "\($0)/\(sessionId)/subagents") }
                .first { fileManager.fileExists(atPath: $0.path) }, now)
        }
        guard let folder = subagentFolders[sessionId]?.folder else { return [] }
        let logs = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return logs.compactMap { log in
            guard log.pathExtension == "jsonl",
                  let written = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  AgentSessionsSupport.subagentIsWorking(lastActivity: written, now: now) else { return nil }
            let name = log.deletingPathExtension().lastPathComponent
            return (try? Data(contentsOf: folder.appending(path: name + ".meta.json")))
                .flatMap { AgentSessionsSupport.parseSubagent(meta: $0, id: name, lastActivity: written) }
        }
    }
}
