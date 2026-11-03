// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The agents whose running processes the Sessions card lists: the four the
/// island reads logs from, and Hermes, which has none here. Names are product
/// names and stay untranslated.
enum AgentProcessKind: String, CaseIterable {
    case claude, codex, opencode, copilot, hermes

    /// The provider whose mark and color it wears; nil for Hermes.
    var provider: AgentProvider? {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        case .copilot: return .copilot
        case .hermes: return nil
        }
    }

    var displayName: String { provider?.displayName ?? "Hermes" }
    var symbol: String { provider?.symbol ?? "paperplane" }
}

/// One line of `ps -ww -eo pid,ppid,pcpu,rss,args`.
struct AgentProcessRow: Equatable {
    let pid: Int32
    let ppid: Int32
    let cpu: Double
    let rssKB: Int
    let args: String
}

/// What is known about a process that is an agent.
struct AgentProbe: Equatable {
    let kind: AgentProcessKind
    /// An interpreter (node, python) running the agent's script, which may
    /// only launch the agent's native binary.
    let launcher: Bool
    /// Kernel start time in microseconds, the identity a kill is checked against.
    let startedAt: UInt64
    let cwd: String?
    /// A helper that is a session only when Claude wrote a session file for it.
    var requiresFile = false
}

/// The regular app an agent runs under: a terminal, an editor, the Claude app.
struct AgentHost: Equatable {
    let pid: Int32
    let name: String
}

/// `~/.claude/sessions/<pid>.json`, which Claude Code keeps for each session
/// and leaves behind when it dies.
struct AgentClaudeFile: Equatable {
    let pid: Int32
    let sessionId: String
    let cwd: String?
    let startedAt: Date
    /// Busy or idle; nil when the file says neither.
    let working: Bool?
    let name: String?
    /// Waiting on the person: a permission, a question, a dialog.
    var asking = false
    /// What it waits for, in Claude's own words.
    var waitingFor: String?
}

/// A Claude subagent that runs inside its parent's process.
struct AgentSubagent: Equatable {
    let id: String
    /// Its type, as `Explore` or `general-purpose`, or else its description.
    let name: String
    /// What it was asked to do, in a few words.
    var task: String?
    let lastActivity: Date
    /// When its log was begun.
    var started: Date?
    /// Claude marked it done; older versions never do.
    var finished = false
    /// Its own transcript.
    var log: String?
    /// It wrote lately and is not done (see `subagentIsWorking`).
    var working = true
}

struct AgentPort: Hashable {
    let port: Int
    let pid: Int32
    let name: String
}

struct AgentSession: Identifiable, Equatable {
    /// `waiting` is idle; `asking` waits on the person.
    enum Status { case working, waiting, asking }

    let id: String
    let kind: AgentProcessKind
    /// 0 for a subagent that runs inside its parent's process.
    let pid: Int32
    /// Kernel start time in microseconds; 0 for a subagent.
    let identity: UInt64
    var depth = 0
    var cwd: String?
    var title: String?
    var status = Status.waiting
    var memory: Int64 = 0
    var ports: [AgentPort] = []
    var host: AgentHost?
    var waitingFor: String?
    /// The log it writes, named as the usage reader names its turns.
    var log: String?
    var activity: AgentActivity?
    /// A subagent's task, under its name.
    var task: String?
    /// When a subagent began and, once done, last wrote; its time stops there.
    var opened: Date?
    var ended: Date?
    /// CPU share of the process and its descendants, and the last minute of it.
    var cpu = 0.0
    var load: [Double] = []

    var isSubagent: Bool { pid == 0 }
    /// No regular app owns it: a daemon, a login item, a detached shell.
    var background: Bool { !isSubagent && host == nil }
    var started: Date? { identity > 0 ? Date(timeIntervalSince1970: Double(identity) / 1_000_000) : opened }
    var folder: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "" }
}

/// A session on the Live tab with what runs beneath it: its subagents and
/// the agents it started, in reading order.
struct AgentSessionGroup: Identifiable, Equatable {
    let session: AgentSession
    var children: [AgentSession] = []
    var id: String { session.id }
}

/// A process that listened under a session that has since ended and still does.
struct AgentOrphan: Identifiable, Equatable {
    let pid: Int32
    let name: String
    let startedAt: UInt64
    var ports: [Int]
    var id: Int32 { pid }
}

enum AgentSessionsSupport {
    /// Process and descendants above this CPU share are working.
    static let workingCPU = 5.0
    /// A subagent whose log was written this recently is working.
    static let subagentWindow: TimeInterval = 30
    /// CPU readings kept per session, one a scan: a minute of them.
    static let loadSamples = 30
    /// Claude's start time and the process's agree to within this.
    static let startTolerance: TimeInterval = 5

    // MARK: Recognizing agents

    /// Cheap filter before asking the kernel about a process.
    static func mayBeAgent(_ args: String) -> Bool {
        let lowered = args.lowercased()
        return AgentProcessKind.allCases.contains { lowered.contains($0.rawValue) }
    }

    /// The names a process goes by. After an update replaces its binary the
    /// kernel can no longer name the path it runs from, so the name it was
    /// started under and its own `argv[0]` stand in. A literal `.exe` is
    /// dropped (npm's Claude binary), but not a version's dots.
    private static func names(path: String?, comm: String, argv: [String]) -> [String] {
        let raw = path.map { [($0 as NSString).lastPathComponent] }
            ?? [comm, ((argv.first ?? "") as NSString).lastPathComponent]
        return raw.filter { !$0.isEmpty }.map { $0.hasSuffix(".exe") ? String($0.dropLast(4)) : $0 }
    }

    private static func isInterpreter(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered == "node" || lowered == "bun" || lowered == "deno" || lowered.hasPrefix("python")
    }

    /// An interpreter (node, python) that may only launch the agent's binary.
    static func isLauncher(executablePath: String?, comm: String = "", argv: [String]) -> Bool {
        names(path: executablePath, comm: comm, argv: argv).contains(where: isInterpreter)
    }

    /// Which agent a process is, from the kernel's path to its executable
    /// (which may hold spaces, as the Claude app's does) or else its name, and
    /// its arguments, `argv[0]` first. The Claude app's `disclaimer` wrapper
    /// only names the agent among its arguments, so it is not one. Neither are
    /// Claude's `daemon` and `bg-pty-host` helpers, or the `app-server` and
    /// `mcp-server` Codex runs for the apps that host it.
    static func kind(executablePath: String?, comm: String = "", argv: [String]) -> AgentProcessKind? {
        guard let (found, rest) = identify(executablePath: executablePath, comm: comm, argv: argv) else { return nil }
        switch found {
        case .claude where rest.first.map(["daemon", "bg-pty-host"].contains) == true: return nil
        case .codex where !Set(rest).isDisjoint(with: ["app-server", "mcp-server"]): return nil
        default: return found
        }
    }

    /// Claude's idle `bg-spare` helpers are sessions only once a session file names them.
    static func requiresSessionFile(argv: [String]) -> Bool { argv.dropFirst().first == "bg-spare" }

    /// The agent, and the arguments after its binary or script.
    private static func identify(executablePath: String?, comm: String,
                                 argv: [String]) -> (AgentProcessKind, [String])? {
        let rest = Array(argv.dropFirst())
        // The native install names its binaries by version.
        if executablePath?.contains("/claude/versions/") == true { return (.claude, rest) }
        let names = names(path: executablePath, comm: comm, argv: argv)
        for name in names {
            switch name {
            case "claude": return (.claude, rest)
            case "codex": return (.codex, rest)
            case "opencode": return (.opencode, rest)
            case "copilot": return (.copilot, rest)
            case "hermes": return (.hermes, rest)
            default: break
            }
        }
        guard names.contains(where: isInterpreter) else { return nil }
        if let flag = rest.firstIndex(of: "-m") {
            return rest.indices.contains(flag + 1) && rest[flag + 1].hasPrefix("hermes") ? (.hermes, []) : nil
        }
        guard let index = rest.firstIndex(where: { !$0.hasPrefix("-") }) else { return nil }
        let after = Array(rest[(index + 1)...])
        let parts = rest[index].lowercased().split(separator: "/").map(String.init)
        let stem = ((parts.last ?? "") as NSString).deletingPathExtension
        func contains(_ first: String, _ second: String) -> Bool {
            zip(parts, parts.dropFirst()).contains { $0 == first && $1 == second }
        }
        if contains("@anthropic-ai", "claude-code") { return (.claude, after) }
        if stem == "codex" { return (.codex, after) }
        if stem == "hermes" { return (.hermes, after) }
        if stem == "opencode" || parts.contains("opencode-ai") { return (.opencode, after) }
        if contains("@github", "copilot") { return (.copilot, after) }
        return nil
    }

    static func parseProcesses(_ output: String) -> [AgentProcessRow] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            let columns = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard columns.count == 5, let pid = Int32(columns[0]), pid > 0, let ppid = Int32(columns[1]),
                  let cpu = Double(columns[2]), let rss = Int(columns[3]) else { return nil }
            return AgentProcessRow(pid: pid, ppid: ppid, cpu: cpu, rssKB: rss, args: String(columns[4]))
        }
    }

    // MARK: Claude's files

    private struct ClaudeFileJSON: Decodable {
        let pid: Int32
        let sessionId: String
        let cwd: String?
        /// Milliseconds since 1970.
        let startedAt: Double
        let status: String?
        let name: String?
        let waitingFor: String?
    }

    private struct SubagentMetaJSON: Decodable {
        let agentType: String?
        let description: String?
        let finished: Bool?
    }

    static func parseClaudeFile(_ data: Data) -> AgentClaudeFile? {
        guard let file = try? JSONDecoder().decode(ClaudeFileJSON.self, from: data) else { return nil }
        return AgentClaudeFile(pid: file.pid, sessionId: file.sessionId, cwd: file.cwd,
                               startedAt: Date(timeIntervalSince1970: file.startedAt / 1000),
                               working: file.status == "busy" ? true : file.status == "idle" ? false : nil,
                               name: file.name?.isEmpty == false ? file.name : nil,
                               asking: file.status == "waiting",
                               waitingFor: file.waitingFor?.isEmpty == false ? file.waitingFor : nil)
    }

    /// Named by its type and described by its task, or named by the task
    /// when it has no type.
    static func parseSubagent(meta data: Data, id: String, lastActivity: Date) -> AgentSubagent? {
        guard let meta = try? JSONDecoder().decode(SubagentMetaJSON.self, from: data) else { return nil }
        let type = meta.agentType?.isEmpty == false ? meta.agentType : nil
        let task = meta.description?.isEmpty == false ? meta.description : nil
        guard let name = type ?? task else { return nil }
        return AgentSubagent(id: id, name: name, task: type == nil ? nil : task, lastActivity: lastActivity,
                             finished: meta.finished == true)
    }

    static func subagentIsWorking(_ subagent: AgentSubagent, now: Date) -> Bool {
        !subagent.finished && now.timeIntervalSince(subagent.lastActivity) < subagentWindow
    }

    /// A subagent shows while it works and, done, until the turn it worked
    /// in ends; `turnStarted` is nil while its session is in no turn.
    static func subagentShows(_ subagent: AgentSubagent, turnStarted: Date?, now: Date) -> Bool {
        subagentIsWorking(subagent, now: now) || turnStarted.map { subagent.lastActivity >= $0 } == true
    }

    /// The last minute of a session's CPU, the newest reading last.
    static func load(_ history: [Double], adding cpu: Double) -> [Double] {
        Array((history + [cpu]).suffix(loadSamples))
    }

    /// A file left by a session that died names a pid that may be alive again
    /// as something else; only one written at this process's start counts.
    static func file(_ file: AgentClaudeFile?, matches identity: UInt64) -> Bool {
        guard let file else { return false }
        return abs(file.startedAt.timeIntervalSince1970 - Double(identity) / 1_000_000) <= startTolerance
    }

    // MARK: Tree

    /// The live sessions in reading order: each one's in-process subagents and
    /// then its child sessions, indented beneath it. `subagents` holds only
    /// the ones working (see `subagentIsWorking`).
    static func sessions(rows: [AgentProcessRow], probes: [Int32: AgentProbe], claudeFiles: [Int32: AgentClaudeFile],
                         subagents: [String: [AgentSubagent]], listeners: [AgentPort], hosts: [Int32: AgentHost],
                         ignoring ignored: Int32?) -> [AgentSession] {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let parents = rows.map { (pid: $0.pid, ppid: $0.ppid) }
        // A helper no session file names is not a session.
        var agents = Set(probes.filter { pid, probe in
            byPID[pid] != nil && (!probe.requiresFile || file(claudeFiles[pid], matches: probe.startedAt))
        }.keys)
        // Vorssaint's own helpers, which check limits, are not anyone's session.
        if let ignored { agents.subtract(KillProcessSupport.descendants(of: ignored, parents: parents)) }

        func nearestAgent(above pid: Int32, in set: Set<Int32>) -> Int32? {
            var seen: Set<Int32> = [pid]
            var current = byPID[pid]?.ppid
            while let candidate = current, candidate > 1, seen.insert(candidate).inserted {
                if set.contains(candidate) { return candidate }
                current = byPID[candidate]?.ppid
            }
            return nil
        }

        // A launcher whose one agent child is the same agent's native binary
        // is one session: the child, which does the work and holds the memory.
        var launcherMemory: [Int32: Int] = [:]
        let all = agents
        for launcher in all where probes[launcher]?.launcher == true {
            let children = all.filter { nearestAgent(above: $0, in: all) == launcher }
            guard children.count == 1, let child = children.first, let kid = probes[child],
                  kid.kind == probes[launcher]?.kind, !kid.launcher else { continue }
            launcherMemory[child] = byPID[launcher]?.rssKB ?? 0
            agents.remove(launcher)
        }

        let parent = Dictionary(uniqueKeysWithValues: agents.compactMap { pid in
            nearestAgent(above: pid, in: agents).map { (pid, $0) }
        })
        var ports: [Int32: [AgentPort]] = [:]
        for listener in listeners {
            // An agent that listens itself keeps its own port.
            let owner = agents.contains(listener.pid) ? listener.pid : nearestAgent(above: listener.pid, in: agents)
            if let owner { ports[owner, default: []].append(listener) }
        }

        func session(_ pid: Int32, depth: Int) -> AgentSession? {
            guard let probe = probes[pid], let row = byPID[pid] else { return nil }
            let file = claudeFiles[pid].flatMap { Self.file($0, matches: probe.startedAt) ? $0 : nil }
            let cpu = KillProcessSupport.descendants(of: pid, parents: parents)
                .reduce(row.cpu) { $0 + (byPID[$1]?.cpu ?? 0) }
            return AgentSession(id: "\(pid)-\(probe.startedAt)", kind: probe.kind, pid: pid, identity: probe.startedAt, depth: depth,
                                cwd: file?.cwd ?? probe.cwd, title: file?.name,
                                status: file?.asking == true ? .asking : (file?.working ?? (cpu >= workingCPU)) ? .working : .waiting,
                                memory: Int64(row.rssKB + (launcherMemory[pid] ?? 0)) * 1024,
                                ports: Array(Set(ports[pid] ?? [])).sorted { ($0.port, $0.pid) < ($1.port, $1.pid) },
                                host: hosts[pid], waitingFor: file?.waitingFor, cpu: cpu)
        }

        let children = Dictionary(grouping: agents.filter { parent[$0] != nil }, by: { parent[$0]! })
        func ordered(_ pids: [Int32]) -> [Int32] {
            pids.sorted { (probes[$0]?.startedAt ?? 0, $0) < (probes[$1]?.startedAt ?? 0, $1) }
        }
        var result: [AgentSession] = []
        func emit(_ pid: Int32, depth: Int) {
            guard let line = session(pid, depth: depth) else { return }
            result.append(line)
            if let id = claudeFiles[pid].flatMap({ file($0, matches: probes[pid]?.startedAt ?? 0) ? $0.sessionId : nil }) {
                // In the order they began, as the person saw them start.
                for sub in (subagents[id] ?? []).sorted(by: { ($0.started ?? .distantPast, $0.id) < ($1.started ?? .distantPast, $1.id) }) {
                    result.append(AgentSession(id: "\(line.id).\(sub.id)", kind: .claude, pid: 0, identity: 0, depth: depth + 1,
                                               title: sub.name, status: sub.working ? .working : .waiting, log: sub.log,
                                               task: sub.task, opened: sub.started, ended: sub.working ? nil : sub.lastActivity))
                }
            }
            for child in ordered(children[pid] ?? []) { emit(child, depth: depth + 1) }
        }
        for root in ordered(agents.filter { parent[$0] == nil }) { emit(root, depth: 0) }
        return result
    }

    // MARK: Card

    /// Sessions of the agents the person follows, Hermes having no switch,
    /// and nothing beneath one they do not.
    static func shown(_ sessions: [AgentSession], providers: [AgentProvider]) -> [AgentSession] {
        var skipping: Int?
        return sessions.filter { session in
            if let depth = skipping, session.depth > depth { return false }
            skipping = nil
            guard session.kind.provider.map(providers.contains) ?? true else {
                skipping = session.depth
                return false
            }
            return true
        }
    }

    /// Each top session with all beneath it, however deep.
    static func groups(_ sessions: [AgentSession]) -> [AgentSessionGroup] {
        var result: [AgentSessionGroup] = []
        for session in sessions {
            if session.depth > 0, !result.isEmpty {
                result[result.count - 1].children.append(session)
            } else {
                result.append(AgentSessionGroup(session: session))
            }
        }
        return result
    }

    /// Tiles `columns` to a row in reading order. A wide one takes a row of
    /// its own; the row before it, or the last, may be left short.
    static func rows<Item>(_ items: [Item], columns: Int, wide: (Item) -> Bool) -> [[Item]] {
        let columns = max(1, columns)
        var rows: [[Item]] = []
        var row: [Item] = []
        for item in items {
            if wide(item) || columns == 1 {
                if !row.isEmpty { rows.append(row) }
                row = []
                rows.append([item])
            } else {
                row.append(item)
                if row.count == columns {
                    rows.append(row)
                    row = []
                }
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    /// As many tiles of at least `minimum` as a row of `width` holds.
    static func columns(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimum + spacing)))
    }

    /// What the Settings preview shows instead of scanning for processes.
    static func sample(now: Date) -> [AgentSession] {
        func start(_ minutes: Double) -> UInt64 { UInt64(now.addingTimeInterval(-minutes * 60).timeIntervalSince1970 * 1_000_000) }
        let terminal = AgentHost(pid: 0, name: "Terminal")
        return [
            AgentSession(id: "1", kind: .claude, pid: 1, identity: start(14), cwd: "/Users/you/web-app", status: .working,
                         memory: 410 << 20, ports: [AgentPort(port: 3000, pid: 2, name: "node")], host: terminal,
                         activity: AgentActivity(state: .running, step: AgentStep(verb: .edit, target: "App.swift"),
                                                 files: [AgentFileDiff(path: "/Users/you/web-app/App.swift", added: 2, removed: 1, hunks: [[
                                                     AgentDiffLine(kind: .context, text: "struct App {"),
                                                     AgentDiffLine(kind: .removed, text: "    var dark = false"),
                                                     AgentDiffLine(kind: .added, text: "    var dark = true"),
                                                     AgentDiffLine(kind: .added, text: "    var toggle = true"),
                                                 ]])], context: 68_000),
                         load: (0..<AgentSessionsSupport.loadSamples).map { 18 + 14 * sin(Double($0) / 3) }),
            AgentSession(id: "1.a", kind: .claude, pid: 0, identity: 0, depth: 1, title: "Explore", status: .working,
                         activity: AgentActivity(state: .running, step: AgentStep(verb: .search, target: "TODO"), context: 21_000),
                         task: "Find the settings code", opened: now.addingTimeInterval(-4 * 60)),
            AgentSession(id: "1.b", kind: .claude, pid: 0, identity: 0, depth: 1, title: "Plan", status: .waiting,
                         activity: AgentActivity(state: .finished), task: "Plan the dark mode",
                         opened: now.addingTimeInterval(-9 * 60), ended: now.addingTimeInterval(-2 * 60)),
            AgentSession(id: "3", kind: .codex, pid: 3, identity: start(52), cwd: "/Users/you/api", status: .waiting,
                         memory: 230 << 20, host: terminal, activity: AgentActivity(state: .finished, context: 96_000, contextWindow: 272_000),
                         load: (0..<AgentSessionsSupport.loadSamples).map { 4 + 3 * cos(Double($0) / 4) }),
            AgentSession(id: "4", kind: .hermes, pid: 4, identity: start(600), cwd: "/Users/you/.hermes", status: .waiting,
                         memory: 120 << 20),
        ]
    }

    // MARK: Showing

    /// Where editors built on VS Code keep their state, in Application Support.
    static let editorStateFolders = ["com.microsoft.VSCode": "Code", "com.microsoft.VSCodeInsiders": "Code - Insiders"]

    /// The folder of the editor's window the session runs in: the deepest one
    /// open that holds `cwd`, from the editor's `storage.json`. Opening a
    /// folder that has a window brings that window forward; nil when none
    /// has, so no new window opens.
    // ponytail: windows of a .code-workspace name no folder and are not found;
    // the editor then comes forward on its last window.
    static func editorFolder(storage: Data, cwd: String) -> URL? {
        guard let object = (try? JSONSerialization.jsonObject(with: storage)) as? [String: Any],
              let state = object["windowsState"] as? [String: Any] else { return nil }
        let windows = (state["openedWindows"] as? [[String: Any]] ?? []) + [state["lastActiveWindow"] as? [String: Any] ?? [:]]
        let path = (cwd as NSString).standardizingPath
        return windows.compactMap { ($0["folder"] as? String).flatMap(URL.init(string:)) }
            .filter { folder in
                let open = folder.standardizedFileURL.path
                return folder.isFileURL && !open.isEmpty && (path == open || path.hasPrefix(open == "/" ? open : open + "/"))
            }
            .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
    }

    /// An editor's window title names its folder as one of its parts, as
    /// VS Code's "● main.swift — project" does.
    static func title(_ title: String, names folder: String) -> Bool {
        !folder.isEmpty && title.components(separatedBy: " — ").flatMap { $0.components(separatedBy: " - ") }
            .contains { $0.trimmingCharacters(in: .whitespaces) == folder }
    }

    /// A script that puts the Terminal or iTerm2 tab on `tty` (`ttys003`) in
    /// front of its window and the window in front of the app's; nil for any
    /// other app, which can only be brought forward whole.
    static func focusScript(bundleID: String?, tty: String) -> String? {
        let number = tty.dropFirst(4)
        guard tty.hasPrefix("ttys"), !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let device = AppleScriptRunner.literal("/dev/" + tty)
        switch bundleID {
        case "com.apple.Terminal":
            return """
                tell application id "com.apple.Terminal"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is \(device) then
                                set miniaturized of w to false
                                set selected tab of w to t
                                set index of w to 1
                                return
                            end if
                        end repeat
                    end repeat
                end tell
                """
        case "com.googlecode.iterm2":
            return """
                tell application id "com.googlecode.iterm2"
                    repeat with w in windows
                        repeat with t in tabs of w
                            repeat with s in sessions of t
                                if tty of s is \(device) then
                                    select w
                                    tell t to select
                                    tell s to select
                                    return
                                end if
                            end repeat
                        end repeat
                    end repeat
                end tell
                """
        default:
            return nil
        }
    }

    // MARK: Orphans

    static func ports(from entries: [PortManagerEntry]) -> [AgentPort] {
        Set(entries.map { AgentPort(port: $0.port, pid: $0.pid, name: $0.processName) })
            .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Remembers what listens under the live sessions. `startedAt` is asked
    /// only for a process not remembered yet; one it cannot place is left
    /// out, as no kill could be checked against it.
    static func tracking(_ tracked: [Int32: AgentOrphan], sessions: [AgentSession],
                         startedAt: (Int32) -> UInt64?) -> [Int32: AgentOrphan] {
        var result = tracked
        for port in sessions.flatMap(\.ports) {
            guard var owner = result[port.pid] ?? startedAt(port.pid).map({
                AgentOrphan(pid: port.pid, name: port.name, startedAt: $0, ports: [])
            }) else { continue }
            owner.ports = Set(owner.ports + [port.port]).sorted()
            result[port.pid] = owner
        }
        return result
    }

    /// Processes that listened under a session and now sit under none but
    /// still listen, on the ports they are known to have had. What listens is
    /// remembered in memory and only while the page is shown, so a server left
    /// behind while the island was closed is never seen.
    static func orphans(tracked: [Int32: AgentOrphan], sessions: [AgentSession],
                        listeners: [AgentPort]) -> [AgentOrphan] {
        // A session is no orphan, nor is what listens beneath one.
        let live = Set(sessions.flatMap(\.ports).map(\.pid) + sessions.map(\.pid))
        let listening = Dictionary(grouping: listeners, by: \.pid).mapValues { Set($0.map(\.port)) }
        return tracked.values.compactMap { owner -> AgentOrphan? in
            guard !live.contains(owner.pid) else { return nil }
            let still = (listening[owner.pid] ?? []).intersection(owner.ports)
            guard !still.isEmpty else { return nil }
            var orphan = owner
            orphan.ports = still.sorted()
            return orphan
        }.sorted { ($0.ports.first ?? 0, $0.pid) < ($1.ports.first ?? 0, $1.pid) }
    }
}
