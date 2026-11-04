// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentSessionsTests {
    static func run(_ suite: TestSuite) {
        suite.run("agent sessions: which processes are agents") { recognizing(suite) }
        suite.run("agent sessions: the process tree") { tree(suite) }
        suite.run("agent sessions: Claude's files") { claudeFiles(suite) }
        suite.run("agent sessions: orphaned ports") { orphans(suite) }
        suite.run("agent sessions: live tab") { liveTab(suite) }
        suite.run("agent sessions: one card open") { picks(suite) }
    }

    private static func picks(_ suite: TestSuite) {
        func session(_ id: String, depth: Int = 0) -> AgentSession {
            AgentSession(id: id, kind: .claude, pid: depth > 0 ? 0 : 1, identity: 1, depth: depth)
        }
        let groups = AgentSessionsSupport.groups([session("a"), session("b"), session("b.1", depth: 1), session("b.2", depth: 1),
                                                  session("c"), session("c.1", depth: 1)])
        var picks = AgentSessionPicks()
        suite.expect(picks.open(in: groups) == "b", "until one is picked, the first session with subagents opens on them")
        picks.pick("b.1")
        picks.pick("b.2")
        suite.expect(picks.picked(in: groups[1])?.id == "b.2", "picking another subagent moves the details to it")
        picks.pick("b.2")
        suite.expect(picks.picked(in: groups[1]) == nil, "picking it again hides them")
        picks.pick("b.1")
        picks.flip("a", in: groups)
        suite.expect(picks.open(in: groups) == "a" && picks.child == nil, "opening a card closes the open one and its pick")
        picks.flip("c", in: groups)
        suite.expect(picks.open(in: groups) == "c", "one card is open at a time")
        picks.flip("c", in: groups)
        suite.expect(picks.open(in: groups) == nil, "closing it leaves all closed, those with subagents too")
        picks.flip("b", in: groups)
        picks.prune(Array(groups.dropFirst(2)))
        suite.expect(picks.card == nil && picks.closed == ["c"], "what has gone is forgotten")
        picks.prune(AgentSessionsSupport.groups([session("c")]) + [AgentSessionGroup(session: session("d"), children: [session("d.1", depth: 1)])])
        suite.expect(picks.open(in: AgentSessionsSupport.groups([session("c"), session("c.1", depth: 1)])) == "c",
                     "a session that lost its subagents opens on new ones")
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static func micros(_ secondsAgo: Double) -> UInt64 {
        UInt64(now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1_000_000)
    }

    private static func row(_ pid: Int32, _ ppid: Int32, cpu: Double = 0, rss: Int = 1000) -> AgentProcessRow {
        AgentProcessRow(pid: pid, ppid: ppid, cpu: cpu, rssKB: rss, args: "")
    }

    private static func probe(_ kind: AgentProcessKind, launcher: Bool = false, age: Double = 600,
                              cwd: String? = "/Users/x/app") -> AgentProbe {
        AgentProbe(kind: kind, launcher: launcher, startedAt: micros(age), cwd: cwd)
    }

    private static func build(_ rows: [AgentProcessRow], _ probes: [Int32: AgentProbe],
                              files: [Int32: AgentClaudeFile] = [:], subagents: [String: [AgentSubagent]] = [:],
                              listeners: [AgentPort] = [], hosts: [Int32: AgentHost] = [:]) -> [AgentSession] {
        AgentSessionsSupport.sessions(rows: rows, probes: probes, claudeFiles: files, subagents: subagents,
                                      listeners: listeners, hosts: hosts, ignoring: nil)
    }

    private static func recognizing(_ suite: TestSuite) {
        let kind = { AgentSessionsSupport.kind(executablePath: $0, argv: $1) }
        suite.expect(kind("/Users/x/Library/Application Support/Claude/claude-code/2.1.308/abc/claude.app/Contents/MacOS/claude",
                          ["claude", "--print"]) == .claude,
                     "the Claude app's own binary is Claude despite the space in its path")
        suite.expect(kind("/Applications/Claude.app/Contents/Helpers/disclaimer",
                          ["disclaimer", "--pgroup", "--", "/Users/x/Library/Application", "Support/Claude/claude"]) == nil,
                     "the wrapper that launches Claude is not an agent")
        suite.expect(kind("/Applications/Claude.app/Contents/MacOS/Claude", ["Claude"]) == nil
                        && kind("/Applications/Codex.app/Contents/MacOS/Codex", ["Codex"]) == nil,
                     "the desktop apps themselves are not agents")
        suite.expect(kind("/Users/x/.local/share/claude/versions/2.1.140", ["claude"]) == .claude,
                     "the native install names its binary by version")
        suite.expect(kind("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claude
                        && kind("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex.js", "--yolo"]) == .codex
                        && kind("/opt/homebrew/bin/node", ["node", "/opt/homebrew/lib/node_modules/@github/copilot/index.js"]) == .copilot
                        && kind("/opt/homebrew/bin/node", ["node", "/x/node_modules/opencode-ai/bin/opencode"]) == .opencode,
                     "an interpreter running an agent's script is that agent")
        suite.expect(kind("/Users/x/.hermes/hermes-agent/venv/bin/python", ["python", "-m", "hermes_cli.main", "gateway", "run", "--replace"]) == .hermes
                        && kind("/usr/bin/python3", ["python3", "-m", "http.server"]) == nil
                        && kind("/opt/homebrew/bin/node", ["node", "/Users/x/projects/codex/server.js"]) == nil
                        && kind("/opt/homebrew/bin/node", ["node", "--inspect"]) == nil,
                     "Hermes is found by its module, and a script that only sits in a folder of that name is not an agent")
        suite.expect(kind("/usr/bin/vim", ["vim", "claude.md"]) == nil, "an editor with an agent's name in its arguments is not one")
        suite.expect(kind("/opt/homebrew/bin/node", ["node", "/Users/x/src/claude-code/server.js"]) == nil
                        && kind("/opt/homebrew/bin/node", ["node", "/Users/x/.nvm/lib/node_modules/@anthropic-ai/claude-code/cli.js"]) == .claude,
                     "only the Claude Code package's script is Claude, not any folder of that name")

        // What a running Mac shows: sessions whose binary an update replaced, and Claude's helpers.
        suite.expect(AgentSessionsSupport.kind(executablePath: nil, comm: "2.1.140", argv: ["claude"]) == .claude
                        && AgentSessionsSupport.kind(executablePath: nil, comm: "claude", argv: ["claude", "--continue"]) == .claude
                        && AgentSessionsSupport.kind(executablePath: nil, comm: "node", argv: ["node", "/x/@anthropic-ai/claude-code/cli.js"]) == .claude,
                     "a session whose binary was replaced is still found by its name")
        suite.expect(kind("/Users/x/.nvm/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", ["claude"]) == .claude,
                     "npm's claude.exe is Claude")
        suite.expect(kind("/Users/x/.local/share/claude/versions/2.1.140", ["2.1.140"]) == .claude
                        && kind("/x/2.1.140", ["2.1.140"]) == nil,
                     "a version's dots stay, so only the versions folder names Claude")
        suite.expect(kind("/Users/x/.nvm/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe",
                          ["/Users/x/.nvm/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe", "daemon", "run", "--origin", "transient"]) == nil
                        && AgentSessionsSupport.kind(executablePath: nil, comm: "claude", argv: ["claude", "bg-pty-host", "--bg-pty-host", "/tmp/x.pty.sock", "200", "50"]) == nil,
                     "Claude's daemon and pty host are not sessions")
        let vscode = "/Users/x/.vscode/extensions/anthropic.claude-code-2.1.317-darwin-arm64/resources/native-binary/claude"
        suite.expect(kind(vscode, [vscode, "--claude-in-chrome-mcp"]) == nil && kind(vscode, [vscode, "--computer-use-mcp"]) == nil
                        && kind(vscode, [vscode, "--chrome-native-host"]) == nil && kind(vscode, [vscode, "--daemon-worker", "bg"]) == nil
                        && kind(vscode, [vscode, "--output-format", "stream-json"]) == .claude,
                     "the MCP servers, Chrome host and daemon workers Claude runs of itself are not sessions")
        suite.expect(AgentSessionsSupport.kind(executablePath: nil, comm: "claude", argv: ["claude", "bg-spare", "--bg-spare", "/tmp/x.claim.sock"]) == .claude
                        && AgentSessionsSupport.requiresSessionFile(argv: ["claude", "bg-spare", "--bg-spare", "/tmp/x"])
                        && AgentSessionsSupport.requiresSessionFile(argv: [vscode, "--bg-spare", "/tmp/x"])
                        && AgentSessionsSupport.requiresSessionFile(argv: [vscode, "--preload"])
                        && !AgentSessionsSupport.requiresSessionFile(argv: ["claude", "--continue"]),
                     "a warm spare is a session only when a session file says so")
        suite.expect(kind("/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                          ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "-c", "features.code_mode_host=true", "app-server"]) == nil
                        && kind("/opt/homebrew/bin/node", ["node", "/x/@openai/codex/bin/codex.js", "mcp-server"]) == nil
                        && kind("/opt/homebrew/bin/codex", ["codex", "--yolo"]) == .codex,
                     "the Codex backend of another app is not a session")
        suite.expect(AgentSessionsSupport.isLauncher(executablePath: nil, comm: "node", argv: ["node", "x.js"])
                        && !AgentSessionsSupport.isLauncher(executablePath: "/x/claude", argv: ["claude"]),
                     "an interpreter is a launcher, also by name")

        let table = AgentSessionsSupport.parseProcesses("""
            PID  PPID  %CPU   RSS ARGS
              1     0   0.0  1000 /sbin/launchd
            412   398  12.5 20480 /Users/x/Library/Application Support/Claude/claude --print hi
            garbage
            """)
        suite.expect(table.map(\.pid) == [1, 412] && table[1].ppid == 398 && table[1].cpu == 12.5 && table[1].rssKB == 20480
                        && table[1].args.hasPrefix("/Users/x/Library/Application Support"),
                     "ps rows keep the arguments whole, spaces included")
        suite.expect(AgentSessionsSupport.mayBeAgent("node /x/CODEX.js") && !AgentSessionsSupport.mayBeAgent("/usr/sbin/cfprefsd"),
                     "only processes naming an agent are asked about")
        suite.expect(["claude", "/opt/bin/Hermes", "x OpenCode y", "copilotx"].allSatisfy(AgentSessionsSupport.mayBeAgent)
                        && !["", "cl", "codeq", "CL@UDE", "copi lot"].contains(where: AgentSessionsSupport.mayBeAgent),
                     "an agent's name counts anywhere and in any case, and nothing else does")

        let terminal = AgentSessionsSupport.focusScript(bundleID: "com.apple.Terminal", tty: "ttys003")
        let iTerm = AgentSessionsSupport.focusScript(bundleID: "com.googlecode.iterm2", tty: "ttys12")
        suite.expect(terminal?.contains("tty of t is \"/dev/ttys003\"") == true && iTerm?.contains("tty of s is \"/dev/ttys12\"") == true,
                     "Terminal and iTerm2 are asked for the tab on the session's own terminal")
        suite.expect(AgentSessionsSupport.focusScript(bundleID: "com.microsoft.VSCode", tty: "ttys003") == nil
                        && ["??", "ttys", "ttys1\"", "ttys+1", "console", "ttys٣"].allSatisfy {
                            AgentSessionsSupport.focusScript(bundleID: "com.apple.Terminal", tty: $0) == nil
                        },
                     "another app, or no terminal, gets no script")

        let storage = Data(#"""
            {"windowsState":{"lastActiveWindow":{"folder":"file:///Users/x/My%20app"},
             "openedWindows":[{"folder":"file:///Users/x/My%20app"},{"folder":"file:///Users/x/My%20app/web"},
                              {"workspaceIdentifier":{"id":"1","configURIPath":"file:///Users/x/all.code-workspace"}},
                              {"folder":"vscode-remote://ssh-remote%2Bbox/Users/x/api"}]}}
            """#.utf8)
        func folder(_ cwd: String) -> String? { AgentSessionsSupport.editorFolder(storage: storage, cwd: cwd)?.path }
        suite.expect(folder("/Users/x/My app") == "/Users/x/My app" && folder("/Users/x/My app/web/src") == "/Users/x/My app/web",
                     "a session goes to the window of the deepest open folder holding it")
        suite.expect(folder("/Users/x/My application") == nil && folder("/Users/x/api") == nil
                        && AgentSessionsSupport.editorFolder(storage: Data("{}".utf8), cwd: "/Users/x/My app") == nil,
                     "a folder no local window has opens nothing")
        suite.expect(AgentSessionsSupport.title("● main.swift — vorssaint-utils", names: "vorssaint-utils")
                        && AgentSessionsSupport.title("vorssaint-utils - Visual Studio Code", names: "vorssaint-utils")
                        && !AgentSessionsSupport.title("● main.swift — vorssaint-utils", names: "utils")
                        && !AgentSessionsSupport.title("main.swift — coucou", names: "vorssaint-utils")
                        && !AgentSessionsSupport.title("main.swift", names: ""),
                     "an editor window is the session's when its title names the session's folder, whole")
    }

    private static func tree(_ suite: TestSuite) {
        // node launcher 10 -> native codex 11 -> shell 12 -> dev server 13; claude 20 -> shell 21 -> codex 22.
        let rows = [row(10, 1, cpu: 0.2, rss: 40_000), row(11, 10, cpu: 0.5, rss: 200_000), row(12, 11), row(13, 12, cpu: 30),
                    row(20, 1, rss: 300_000), row(21, 20), row(22, 21, rss: 100_000)]
        let sessions = build(rows,
                             [10: probe(.codex, launcher: true), 11: probe(.codex), 20: probe(.claude, age: 900), 22: probe(.codex, age: 100)],
                             listeners: [AgentPort(port: 3000, pid: 13, name: "node"), AgentPort(port: 3000, pid: 13, name: "node"),
                                         AgentPort(port: 9229, pid: 13, name: "node")],
                             hosts: [11: AgentHost(pid: 500, name: "iTerm2")])
        suite.expect(sessions.map(\.pid) == [20, 22, 11],
                     "a launcher and its native binary are one session, and a nested agent sits under its parent: \(sessions.map(\.pid))")
        suite.expect(sessions.map(\.depth) == [0, 1, 0], "the nested session is indented")
        let codex = sessions.first { $0.pid == 11 }
        suite.expect(codex?.memory == (40_000 + 200_000) * 1024, "the launcher's memory counts with the session")
        suite.expect(codex?.status == .working && codex?.ports.map(\.port) == [3000, 9229],
                     "a busy descendant makes the session work, and its listening ports are listed once")
        suite.expect(codex?.host?.name == "iTerm2" && codex?.background == false && sessions[0].background,
                     "a session with no host app is in the background")
        suite.expect(sessions[0].status == .waiting, "a quiet session waits")

        let ignored = AgentSessionsSupport.sessions(rows: rows, probes: [11: probe(.codex), 22: probe(.claude)],
                                                    claudeFiles: [:], subagents: [:], listeners: [], hosts: [:],
                                                    ignoring: 21)
        suite.expect(ignored.map(\.pid) == [11], "agents Vorssaint itself started are not listed")

        // Impossible in a real table, but it must end, and a cycle has no root to list from.
        let loop = build([row(30, 31), row(31, 30)], [30: probe(.claude), 31: probe(.claude)])
        suite.expect(loop.isEmpty, "a circular parent table ends with nothing listed")

        // An agent listens for itself, and a spare helper without a file is not one.
        let own = build([row(40, 1), row(41, 1), row(42, 41)], [40: probe(.hermes), 41: probe(.claude), 42: probe(.claude)],
                        listeners: [AgentPort(port: 8642, pid: 40, name: "python")])
        suite.expect(own.first { $0.pid == 40 }?.ports.map(\.port) == [8642], "an agent's own listening port is its own")
        var spare = probe(.claude)
        spare = AgentProbe(kind: spare.kind, launcher: false, startedAt: spare.startedAt, cwd: nil, requiresFile: true)
        suite.expect(build([row(50, 1)], [50: spare]).isEmpty, "a spare helper with no session file is not listed")
    }

    private static func claudeFiles(_ suite: TestSuite) {
        let json = """
            {"pid":20,"sessionId":"abc-1","cwd":"/Users/x/real","startedAt":\(Int(now.addingTimeInterval(-900).timeIntervalSince1970 * 1000)),
             "kind":"interactive","status":"busy","name":"fix tests"}
            """
        let file = AgentSessionsSupport.parseClaudeFile(Data(json.utf8))
        suite.expect(file?.sessionId == "abc-1" && file?.working == true && file?.name == "fix tests",
                     "Claude's session file is read")
        suite.expect(AgentSessionsSupport.parseClaudeFile(Data("{}".utf8)) == nil, "a file without a session is ignored")
        let rows = [row(20, 1), row(21, 20)]
        let fresh = build(rows, [20: probe(.claude, age: 898, cwd: "/elsewhere")], files: [20: file!])
        suite.expect(fresh.first?.cwd == "/Users/x/real" && fresh.first?.status == .working && fresh.first?.title == "fix tests",
                     "a file written when the process started names its folder and status")
        let stale = build(rows, [20: probe(.claude, age: 100, cwd: "/elsewhere")], files: [20: file!])
        suite.expect(stale.first?.cwd == "/elsewhere" && stale.first?.status == .waiting && stale.first?.title == nil,
                     "a file left by an older process with the same pid is not trusted")

        let working = AgentSubagent(id: "agent-1", name: "Explore", task: "Look around", lastActivity: now.addingTimeInterval(-5),
                                    started: now.addingTimeInterval(-60), log: "/p/agent-1.jsonl")
        var done = AgentSubagent(id: "agent-2", name: "Plan", lastActivity: now.addingTimeInterval(-31),
                                 started: now.addingTimeInterval(-300))
        done.working = false
        let nested = build(rows, [20: probe(.claude, age: 900)], files: [20: file!], subagents: ["abc-1": [done, working]])
        suite.expect(nested.map(\.title) == ["fix tests", "Plan", "Explore"] && nested[1].isSubagent && nested[1].depth == 1
                        && nested[1].pid == 0,
                     "subagents are listed under their parent in the order they began, with nothing to kill")
        suite.expect(nested[2].status == .working && nested[2].task == "Look around" && nested[2].log == "/p/agent-1.jsonl"
                        && nested[2].started == working.started && nested[2].ended == nil
                        && nested[1].status == .waiting && nested[1].ended == done.lastActivity,
                     "a subagent keeps its task, its log and when it began; one done stops its time at its last write")
        suite.expect(AgentSessionsSupport.subagentIsWorking(working, now: now)
                        && !AgentSessionsSupport.subagentIsWorking(done, now: now),
                     "only a subagent that wrote in the last 30 seconds is working")
        var marked = working
        marked.finished = true
        suite.expect(!AgentSessionsSupport.subagentIsWorking(marked, now: now), "one Claude marked done is done at once")
        let request = now.addingTimeInterval(-120)
        func shown(_ subagents: [AgentSubagent], request: Date?, busy: Bool) -> [String] {
            AgentSessionsSupport.subagentsShown(subagents, request: request, busy: busy, now: now).map(\.id)
        }
        suite.expect(shown([done, working], request: request, busy: true) == ["agent-2", "agent-1"]
                        && shown([done], request: request, busy: false).isEmpty
                        && shown([done, working], request: now.addingTimeInterval(-20), busy: true) == ["agent-1"]
                        && shown([working], request: nil, busy: false) == ["agent-1"],
                     "a subagent done stays until its request ends, one done in an earlier request does not show")
        var thinking = AgentSubagent(id: "agent-3", name: "general-purpose", lastActivity: now.addingTimeInterval(-90))
        thinking.background = true
        suite.expect(AgentSessionsSupport.subagentIsWorking(thinking, now: now)
                        && shown([done, thinking], request: request, busy: false) == ["agent-2", "agent-3"],
                     "one in the background works, silent, until marked done, and its request lasts while the session idles")
        thinking.finished = true
        suite.expect(shown([done, thinking], request: request, busy: false).isEmpty
                        && shown([done, thinking], request: request, busy: true) == ["agent-2", "agent-3"],
                     "once all are done the request ends with the session's turn")
        let meta = AgentSessionsSupport.parseSubagent(meta: Data(#"{"agentType":"Explore","description":"Look around","finished":true}"#.utf8),
                                                      id: "agent-1", lastActivity: now)
        let typeless = AgentSessionsSupport.parseSubagent(meta: Data(#"{"description":"Look around"}"#.utf8), id: "x", lastActivity: now)
        let background = AgentSessionsSupport.parseSubagent(
            meta: Data(#"{"agentType":"general-purpose","requestShape":"background","stoppedByUser":true}"#.utf8), id: "x", lastActivity: now)
        suite.expect(background?.background == true && background?.finished == true && meta?.background == false,
                     "a subagent knows it runs in the background, and one the person stopped is done")
        suite.expect(meta?.name == "Explore" && meta?.task == "Look around" && meta?.finished == true
                        && typeless?.name == "Look around" && typeless?.task == nil
                        && AgentSessionsSupport.parseSubagent(meta: Data(#"{"agentType":"Plan"}"#.utf8), id: "x", lastActivity: now)?.name == "Plan"
                        && AgentSessionsSupport.parseSubagent(meta: Data("{}".utf8), id: "x", lastActivity: now) == nil,
                     "a subagent is named by its type and described by its task, or named by the task")
    }

    private static func orphans(_ suite: TestSuite) {
        let owner = AgentPort(port: 3000, pid: 13, name: "node")
        let live = build([row(20, 1), row(21, 20), row(13, 21)], [20: probe(.claude)], listeners: [owner])
        var asked: [Int32] = []
        let tracked = AgentSessionsSupport.tracking([:], sessions: live) { pid in asked.append(pid); return 77 }
        suite.expect(tracked[13]?.ports == [3000] && tracked[13]?.startedAt == 77, "what listens under a session is remembered")
        _ = AgentSessionsSupport.tracking(tracked, sessions: live) { pid in asked.append(pid); return 1 }
        suite.expect(asked == [13], "a process already remembered is not asked about again")
        suite.expect(AgentSessionsSupport.tracking([:], sessions: live) { _ in nil }.isEmpty,
                     "a process whose start cannot be read is never remembered, so never killed")
        suite.expect(AgentSessionsSupport.orphans(tracked: tracked, sessions: live, listeners: [owner]).isEmpty,
                     "a listener still under its session is not orphaned")
        // Its parent session died; the agent that listens is a session itself now.
        let child = build([row(13, 1)], [13: probe(.codex)], listeners: [owner])
        suite.expect(child.map(\.pid) == [13]
                        && AgentSessionsSupport.orphans(tracked: tracked, sessions: child, listeners: [owner]).isEmpty
                        && AgentSessionsSupport.orphans(tracked: tracked, sessions: [AgentSession(id: "x", kind: .codex, pid: 13, identity: 1)],
                                                        listeners: [owner]).isEmpty,
                     "an agent that outlived its parent session is not an orphan to close")
        let after = AgentSessionsSupport.orphans(tracked: tracked, sessions: [], listeners: [owner])
        suite.expect(after.map(\.pid) == [13] && after[0].ports == [3000],
                     "a listener whose session ended and that still listens is orphaned")
        suite.expect(AgentSessionsSupport.orphans(tracked: tracked, sessions: [], listeners: []).isEmpty
                        && AgentSessionsSupport.orphans(tracked: tracked, sessions: [],
                                                        listeners: [AgentPort(port: 4000, pid: 13, name: "node")]).isEmpty,
                     "one that stopped listening on those ports is gone")
        let entries = [PortManagerEntry(port: 3000, protocolName: "TCP", address: "*:3000", pid: 13, processName: "node", startedAt: nil),
                       PortManagerEntry(port: 3000, protocolName: "TCP", address: "[::1]:3000", pid: 13, processName: "node", startedAt: nil)]
        suite.expect(AgentSessionsSupport.ports(from: entries) == [owner], "one port on two addresses is one port")
    }

    private static func liveTab(_ suite: TestSuite) {
        let sessions = (1...5).map { AgentSession(id: String($0), kind: .claude, pid: Int32($0), identity: UInt64($0)) }
        let mixed = sessions.prefix(2).map { $0 } + [AgentSession(id: "h", kind: .hermes, pid: 9, identity: 9),
                                                      AgentSession(id: "c", kind: .codex, pid: 8, identity: 8)]
        suite.expect(AgentSessionsSupport.shown(mixed, providers: [.codex]).map(\.pid) == [9, 8],
                     "an agent the person stopped following is left out, and Hermes has no switch")
        let tree = [AgentSession(id: "a", kind: .claude, pid: 1, identity: 1, log: "/p/a.jsonl"),
                    AgentSession(id: "b", kind: .codex, pid: 2, identity: 2, depth: 1),
                    AgentSession(id: "c", kind: .claude, pid: 0, identity: 0, depth: 2),
                    AgentSession(id: "d", kind: .codex, pid: 3, identity: 3)]
        suite.expect(AgentSessionsSupport.shown(tree, providers: [.codex]).map(\.id) == ["d"]
                        && AgentSessionsSupport.shown(tree, providers: [.claude]).map(\.id) == ["a"]
                        && AgentSessionsSupport.shown(tree, providers: [.claude, .codex]).count == 4,
                     "what hangs beneath an agent the person does not follow goes with it")
        let terminal = AgentHost(pid: 50, name: "Terminal")
        let warm = [AgentSession(id: "w", kind: .claude, pid: 4, identity: 4),
                    AgentSession(id: "w.mcp", kind: .claude, pid: 5, identity: 5, depth: 1),
                    AgentSession(id: "t", kind: .claude, pid: 6, identity: 6, host: terminal),
                    AgentSession(id: "b", kind: .claude, pid: 7, identity: 7, log: "/p/b.jsonl"),
                    AgentSession(id: "x", kind: .codex, pid: 8, identity: 8)]
        suite.expect(AgentSessionsSupport.shown(warm, providers: [.claude, .codex]).map(\.id) == ["t", "b", "x"],
                     "a Claude session no app owns and no one has asked anything yet is left out, with what runs beneath it")
        suite.expect(AgentSessionsSupport.sample(now: now).contains { $0.background } && AgentSessionsSupport.sample(now: now).count > 3
                        && AgentSessionsSupport.sample(now: now).contains { $0.isSubagent && $0.task != nil },
                     "the Settings preview has example rows, one in the background and subagents with tasks")

        let groups = AgentSessionsSupport.groups(tree)
        suite.expect(groups.map(\.id) == ["a", "d"] && groups[0].children.map(\.id) == ["b", "c"] && groups[1].children.isEmpty,
                     "each top session takes all beneath it, however deep")
        suite.expect(AgentSessionsSupport.groups([AgentSession(id: "x", kind: .claude, pid: 0, identity: 0, depth: 1)]).map(\.id) == ["x"],
                     "a child whose parent is not shown stands on its own")
        let tiles = AgentSessionsSupport.rows(["a", "b", "W", "c", "d", "e"], columns: 2) { $0 == "W" }
        suite.expect(tiles == [["a", "b"], ["W"], ["c", "d"], ["e"]]
                        && AgentSessionsSupport.rows(["a", "W", "b"], columns: 2) { $0 == "W" } == [["a"], ["W"], ["b"]]
                        && AgentSessionsSupport.rows(["a", "b", "c", "d"], columns: 3) { _ in false } == [["a", "b", "c"], ["d"]]
                        && AgentSessionsSupport.rows(["a", "b"], columns: 0) { _ in false } == [["a"], ["b"]],
                     "tiles fill rows in reading order, a wide one on its own row")
        suite.expect(AgentSessionsSupport.columns(width: 404, minimum: 124, spacing: 6) == 3
                        && AgentSessionsSupport.columns(width: 300, minimum: 124, spacing: 6) == 2
                        && AgentSessionsSupport.columns(width: 40, minimum: 124, spacing: 6) == 1,
                     "a row holds as many tiles as fit, and at least one")
        var running = AgentActivity()
        running.state = .running
        var finished = AgentActivity()
        finished.state = .finished
        var failed = AgentActivity()
        failed.state = .failed
        let app = AgentHost(pid: 1, name: "Terminal")
        func tone(_ status: AgentSession.Status, _ activity: AgentActivity?, kind: AgentProcessKind = .claude,
                  pid: Int32 = 1, host: AgentHost? = app) -> AgentSession.Tone {
            AgentSessionsSupport.tone(of: AgentSession(id: "s", kind: kind, pid: pid, identity: UInt64(pid), status: status,
                                                       host: host, activity: activity))
        }
        suite.expect(tone(.asking, running) == .asking && tone(.working, running) == .working && tone(.working, finished) == .done
                        && tone(.waiting, running) == .done && tone(.waiting, running, kind: .codex) == .working
                        && tone(.waiting, failed) == .idle,
                     "a session's tone follows the word its state says: asking, at work, or done")
        suite.expect(tone(.working, nil) == .working && tone(.waiting, nil) == .done && tone(.waiting, nil, host: nil) == .idle
                        && tone(.working, nil, host: nil) == .idle,
                     "with no log, a session in an app is done once idle, one in the background says nothing")
        suite.expect(tone(.waiting, running, pid: 0, host: nil) == .done && tone(.working, running, pid: 0, host: nil) == .working,
                     "a subagent is done once it stops")
        let minute = (0..<40).reduce([Double]()) { AgentSessionsSupport.load($0, adding: Double($1)) }
        suite.expect(minute.count == AgentSessionsSupport.loadSamples && minute.last == 39 && minute.first == 10,
                     "a session's CPU history keeps its last minute, the newest last")
    }
}
