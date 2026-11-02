// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin
import Foundation
import SQLite3

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
    private static let searchAgain: TimeInterval = 5
    /// `lsof` is the dear part of a scan, so its answer is kept between ticks.
    private static let portsTick: TimeInterval = 10
    private static let lsof = ("/usr/sbin/lsof", ["-nP", "+c0", "-iTCP", "-sTCP:LISTEN", "-F", "pcnPT"])

    private let queue = DispatchQueue(label: "com.vorssaint.agent-sessions", qos: .utility)
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private var claudeDirectory: URL { home.appending(path: ".claude") }
    private var openCodeDatabase: String { home.appending(path: ".local/share/opencode/opencode.db").path }
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
    /// The project folder of a Claude session's transcript; nil, with the
    /// time of the search, until Claude writes it.
    private var projectFolders: [String: (folder: URL?, searched: Date)] = [:]
    /// How far each log a session writes has been read, and what it said.
    private var activityLogs: [String: AgentActivityLog] = [:]
    /// The first line of each Codex and Copilot log looked at; nil for one that
    /// belongs to no session of the person's.
    private var heads: [String: AgentLogCandidate?] = [:]
    /// The Codex logs named by a `codex resume <id>`, found once.
    private var resumed: [String: String?] = [:]

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
            projectFolders = [:]
            activityLogs = [:]
            heads = [:]
            resumed = [:]
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

    // MARK: Showing

    func show(_ session: AgentSession) {
        guard let host = session.host, let app = NSRunningApplication(processIdentifier: host.pid) else { return }
        // A pid reused since sits on someone else's terminal.
        let tty = KillProcessService.startTime(for: session.pid) == session.identity ? Self.terminal(of: session.pid) : nil
        Self.show(app, tty: tty, cwd: session.cwd)
    }

    /// Brings the app forward: Terminal and iTerm2 on the session's own tab,
    /// VS Code on the window of its folder. Both are found off the main
    /// thread, as AppleScript waits on the app; a declined Automation, a tab
    /// that is gone or a folder no window has still shows the app.
    static func show(_ app: NSRunningApplication, tty: String?, cwd: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            if let tty, let script = AgentSessionsSupport.focusScript(bundleID: app.bundleIdentifier, tty: tty) {
                AppleScriptRunner.run(script)
            } else if let cwd, let bundleURL = app.bundleURL,
                      let state = app.bundleIdentifier.flatMap({ AgentSessionsSupport.editorStateFolders[$0] }),
                      let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                      let storage = try? Data(contentsOf: support.appending(path: state + "/User/globalStorage/storage.json")),
                      let folder = AgentSessionsSupport.editorFolder(storage: storage, cwd: cwd) {
                DispatchQueue.main.async {
                    ActivationHandoff.yield(to: app)
                    NSWorkspace.shared.open([folder], withApplicationAt: bundleURL, configuration: NSWorkspace.OpenConfiguration())
                }
                return
            }
            DispatchQueue.main.async { activate(app) }
        }
    }

    /// The terminal of the process or, as a hook can run in a session of its
    /// own, of its nearest parent that has one.
    static func terminal(near pid: pid_t) -> String? {
        var pid = pid
        for _ in 0..<4 where pid > 1 {
            if let tty = terminal(of: pid) { return tty }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
            pid = pid_t(info.pbi_ppid)
        }
        return nil
    }

    private static func activate(_ app: NSRunningApplication) {
        ActivationHandoff.yield(to: app)
        if !app.activate(from: NSRunningApplication.current, options: []) {
            app.activate(options: [])
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

        var sessions = AgentSessionsSupport.sessions(
            rows: rows, probes: probes, claudeFiles: files, subagents: subagents, listeners: listeners,
            hosts: hosts.compactMapValues { $0.host }, ignoring: ProcessInfo.processInfo.processIdentifier)
        attachActivity(to: &sessions, args: Dictionary(rows.map { ($0.pid, $0.args) }, uniquingKeysWith: { first, _ in first }),
                       files: files, now: now)
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

    /// The terminal the process reads, as `ttys003`; "??" or nil without one.
    /// Nil for a process with no terminal.
    private static func terminal(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32.max,
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        return String(cString: name)
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

    /// The folder Claude keeps a session's transcript in, named after the
    /// project; the id is unique, so it is searched for. A session that has
    /// not written yet is looked for again every few seconds.
    private func projectFolder(of sessionId: String, now: Date) -> URL? {
        let known = projectFolders[sessionId]
        if known == nil || (known?.folder == nil && now.timeIntervalSince(known?.searched ?? now) >= Self.searchAgain) {
            let projects = claudeDirectory.appending(path: "projects")
            projectFolders[sessionId] = (((try? FileManager.default.contentsOfDirectory(atPath: projects.path)) ?? [])
                .map { projects.appending(path: $0) }
                .first { FileManager.default.fileExists(atPath: $0.appending(path: sessionId + ".jsonl").path) }, now)
        }
        return projectFolders[sessionId]?.folder
    }

    /// Claude keeps a session's subagents under `projects/<folder>/<id>/subagents`.
    private func workingSubagents(of sessionId: String, now: Date) -> [AgentSubagent] {
        let fileManager = FileManager.default
        guard let folder = projectFolder(of: sessionId, now: now)?.appending(path: sessionId + "/subagents") else { return [] }
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

    // MARK: Activity

    /// On `queue`. Finds the log each session writes and reads what was added to it.
    private func attachActivity(to sessions: inout [AgentSession], args: [Int32: String],
                                files: [Int32: AgentClaudeFile], now: Date) {
        var logs: [Int32: String] = [:]
        for (pid, file) in files {
            if let folder = projectFolder(of: file.sessionId, now: now) {
                logs[pid] = folder.appending(path: file.sessionId + ".jsonl").path
            }
        }
        let requests = sessions.filter { !$0.isSubagent && [.codex, .copilot, .opencode].contains($0.kind) }.map { session in
            let argv = (args[session.pid] ?? "").split(separator: " ").map(String.init)
            return AgentLogRequest(pid: session.pid, kind: session.kind, cwd: session.cwd, started: session.started ?? now,
                                   exact: Self.openFiles(of: session.pid).first { AgentActivitySupport.isLog($0, kind: session.kind) }
                                       ?? namedLog(kind: session.kind, argv: argv))
        }
        let open = requests.filter { $0.exact == nil }
        logs.merge(AgentActivitySupport.links(requests, candidates: open.isEmpty ? [] : candidates(for: open, now: now))) { $1 }

        let written = Set(logs.values)
        activityLogs = activityLogs.filter { written.contains($0.key) }
        for index in sessions.indices {
            guard let path = logs[sessions[index].pid], !sessions[index].isSubagent else { continue }
            var log = activityLogs[path] ?? AgentActivityLog()
            if sessions[index].kind == .opencode { readOpenCode(path, into: &log) } else { read(path, kind: sessions[index].kind, into: &log) }
            activityLogs[path] = log
            sessions[index].log = path
            sessions[index].activity = log.activity
        }
    }

    /// The log a process names in its arguments: a session it resumes.
    private func namedLog(kind: AgentProcessKind, argv: [String]) -> String? {
        switch kind {
        case .codex:
            guard let id = AgentActivitySupport.argument(after: ["resume"], in: argv) else { return nil }
            if let known = resumed[id] { return known }
            let found = FileManager.default.enumerator(atPath: home.appending(path: ".codex/sessions").path)?
                .lazy.compactMap { $0 as? String }.first { $0.hasSuffix(id + ".jsonl") }
                .map { home.appending(path: ".codex/sessions/" + $0).path }
            resumed[id] = found
            return found
        case .copilot:
            guard let id = AgentActivitySupport.argument(after: ["--resume"], in: argv) else { return nil }
            let path = home.appending(path: ".copilot/session-state/\(id)/events.jsonl").path
            return FileManager.default.fileExists(atPath: path) ? path : nil
        case .opencode:
            return AgentActivitySupport.argument(after: ["--session", "-s"], in: argv).map { openCodeDatabase + "#" + $0 }
        default:
            return nil
        }
    }

    /// The logs begun since the oldest of these processes started.
    private func candidates(for requests: [AgentLogRequest], now: Date) -> [AgentLogCandidate] {
        guard let oldest = requests.map(\.started).min() else { return [] }
        let since = oldest.addingTimeInterval(-AgentSessionsSupport.startTolerance)
        let kinds = Set(requests.map(\.kind))
        var result: [AgentLogCandidate] = []
        if kinds.contains(.codex) {
            // Codex files a log under the day it began.
            let calendar = Calendar.current
            var day = max(calendar.startOfDay(for: since), calendar.startOfDay(for: now.addingTimeInterval(-7 * 86_400)))
            var folders: [URL] = []
            while day <= now {
                let parts = calendar.dateComponents([.year, .month, .day], from: day)
                folders.append(home.appending(path: String(format: ".codex/sessions/%04d/%02d/%02d",
                                                           parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)))
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? now.addingTimeInterval(1)
            }
            result += folders.flatMap { logs(in: $0, since: since, kind: .codex) { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") } }
        }
        if kinds.contains(.copilot) {
            let state = home.appending(path: ".copilot/session-state")
            let folders = ((try? FileManager.default.contentsOfDirectory(atPath: state.path)) ?? []).map { state.appending(path: $0) }
            result += folders.flatMap { logs(in: $0, since: since, kind: .copilot) { $0 == "events.jsonl" } }
        }
        if kinds.contains(.opencode) {
            Self.query(openCodeDatabase, """
                SELECT id, directory, time_created, time_updated FROM session
                WHERE parent_id IS NULL AND time_updated >= ?1
                """, [Int64(since.timeIntervalSince1970 * 1000)]) { row in
                guard let id = Self.text(row, 0), let cwd = Self.text(row, 1) else { return }
                result.append(AgentLogCandidate(path: openCodeDatabase + "#" + id, kind: .opencode, cwd: cwd,
                                                created: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 2)) / 1000),
                                                modified: Date(timeIntervalSince1970: Double(sqlite3_column_int64(row, 3)) / 1000)))
            }
        }
        return result
    }

    /// The logs in a folder changed since `since`, as their first lines describe them.
    private func logs(in folder: URL, since: Date, kind: AgentProcessKind,
                      named: (String) -> Bool) -> [AgentLogCandidate] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { file in
            guard named(file.lastPathComponent),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified >= since else { return nil }
            if heads[file.path] == nil {
                let head = Self.firstLine(file.path).flatMap(AgentLogParser.object)
                heads[file.path] = head.flatMap { head in
                    kind == .codex ? AgentActivitySupport.codexCandidate(head: head, path: file.path, modified: modified)
                        : AgentActivitySupport.copilotCandidate(head: head, path: file.path, modified: modified)
                }
            }
            return heads[file.path]?.map {
                AgentLogCandidate(path: $0.path, kind: $0.kind, cwd: $0.cwd, created: $0.created, modified: modified)
            }
        }
    }

    /// Reads what was added to a JSON-lines log since the last tick; at first
    /// only its end, which holds the turn running now.
    private func read(_ path: String, kind: AgentProcessKind, into log: inout AgentActivityLog) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if log.offset < 0 || UInt64(log.offset) > size {
            log = AgentActivityLog()
            log.offset = Int64(size) - Int64(min(UInt64(AgentActivitySupport.firstRead), size))
            log.midLine = log.offset > 0
        }
        guard UInt64(log.offset) < size, (try? handle.seek(toOffset: UInt64(log.offset))) != nil,
              let data = try? handle.read(upToCount: AgentActivitySupport.tickRead), !data.isEmpty else { return }
        let (lines, consumed) = AgentActivitySupport.lines(data, partialStart: log.midLine)
        guard consumed > 0 else {
            // A line longer than a tick's read is skipped rather than read forever.
            if data.count >= AgentActivitySupport.tickRead {
                log.offset += Int64(data.count)
                log.midLine = true
            }
            return
        }
        log.offset += Int64(consumed)
        log.midLine = false
        for line in lines {
            guard let object = AgentLogParser.object(line) else { continue }
            switch kind {
            case .claude: AgentActivitySupport.applyClaude(object, to: &log.activity)
            case .codex: AgentActivitySupport.applyCodex(object, to: &log.activity)
            case .copilot: AgentActivitySupport.applyCopilot(object, to: &log.activity)
            default: break
            }
        }
    }

    /// Reads the parts an OpenCode session added or changed since the last
    /// tick; at first only its latest.
    private func readOpenCode(_ path: String, into log: inout AgentActivityLog) {
        guard let mark = path.lastIndex(of: "#") else { return }
        let database = String(path[..<mark]), session = String(path[path.index(after: mark)...])
        let first = log.offset < 0
        var rows: [(id: String, updated: Int64, role: String?, part: [String: Any])] = []
        Self.query(database, """
            SELECT p.id, p.time_updated, json_extract(m.data, '$.role'), p.data FROM part p
            JOIN message m ON m.id = p.message_id WHERE p.session_id = ?1 AND p.time_updated > ?2
            ORDER BY p.time_updated \(first ? "DESC" : "ASC") LIMIT \(first ? 200 : 500)
            """, [session, max(log.offset, 0)]) { row in
            guard let id = Self.text(row, 0), let part = Self.text(row, 3).flatMap({ AgentLogParser.object(Data($0.utf8)) })
            else { return }
            rows.append((id, sqlite3_column_int64(row, 1), Self.text(row, 2), part))
        }
        if first { rows.reverse() }
        log.offset = max(log.offset, rows.last?.updated ?? 0)
        for row in rows { AgentActivitySupport.applyOpenCode(part: row.part, id: row.id, role: row.role, to: &log.activity) }
    }

    private static func firstLine(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Codex's first line carries its instructions, so it can be long.
        guard let data = try? handle.read(upToCount: 512 * 1024), let end = data.firstIndex(of: UInt8(ascii: "\n"))
        else { return nil }
        return data[data.startIndex..<end]
    }

    /// The files a process holds open, by path.
    private static func openFiles(of pid: pid_t) -> [String] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let filled = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return fds.prefix(Int(filled) / stride).compactMap { fd in
            guard fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) else { return nil }
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            return path.isEmpty ? nil : path
        }
    }

    /// Runs a read-only query; a database that is missing or busy gives no rows.
    private static func query(_ path: String, _ sql: String, _ values: [Any], row: (OpaquePointer) -> Void) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            if let number = value as? Int64 {
                sqlite3_bind_int64(statement, position, number)
            } else if let text = value as? String {
                sqlite3_bind_text(statement, position, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
        }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}

/// How far a session's log has been read, and what it said.
struct AgentActivityLog {
    /// Bytes read, or for OpenCode the newest part's update time; -1 before the first read.
    var offset: Int64 = -1
    /// The read stopped inside a line, whose rest is skipped.
    var midLine = false
    var activity = AgentActivity()
}
