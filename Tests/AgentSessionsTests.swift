// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentSessionsTests {
    static func run(_ suite: TestSuite) {
        suite.run("agent sessions: which processes are agents") { recognizing(suite) }
        suite.run("agent sessions: the process tree") { tree(suite) }
        suite.run("agent sessions: Claude's files") { claudeFiles(suite) }
        suite.run("agent sessions: orphaned ports") { orphans(suite) }
        suite.run("agent sessions: card") { card(suite) }
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
        suite.expect(AgentSessionsSupport.kind(executablePath: nil, comm: "claude", argv: ["claude", "bg-spare", "--bg-spare", "/tmp/x.claim.sock"]) == .claude
                        && AgentSessionsSupport.requiresSessionFile(argv: ["claude", "bg-spare", "--bg-spare", "/tmp/x"])
                        && !AgentSessionsSupport.requiresSessionFile(argv: ["claude", "--continue"]),
                     "a spare helper is a session only when a session file says so")
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

        let working = AgentSubagent(id: "agent-1", title: "Explore", lastActivity: now.addingTimeInterval(-5))
        let done = AgentSubagent(id: "agent-2", title: "Old", lastActivity: now.addingTimeInterval(-31))
        let nested = build(rows, [20: probe(.claude, age: 900)], files: [20: file!], subagents: ["abc-1": [working]])
        suite.expect(nested.map(\.title) == ["fix tests", "Explore"] && nested[1].isSubagent && nested[1].depth == 1
                        && nested[1].pid == 0,
                     "a subagent is listed under its parent, with nothing to kill")
        suite.expect(AgentSessionsSupport.subagentIsWorking(lastActivity: working.lastActivity, now: now)
                        && !AgentSessionsSupport.subagentIsWorking(lastActivity: done.lastActivity, now: now),
                     "only a subagent that wrote in the last 30 seconds is working")
        let meta = AgentSessionsSupport.parseSubagent(meta: Data(#"{"agentType":"Explore","description":"Look around"}"#.utf8),
                                                      id: "agent-1", lastActivity: now)
        suite.expect(meta?.title == "Look around"
                        && AgentSessionsSupport.parseSubagent(meta: Data(#"{"agentType":"Plan"}"#.utf8), id: "x", lastActivity: now)?.title == "Plan",
                     "a subagent is named by its description, or else its type")
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

    private static func card(_ suite: TestSuite) {
        let sessions = (1...5).map { AgentSession(id: String($0), kind: .claude, pid: Int32($0), identity: UInt64($0)) }
        let preview = AgentSessionsSupport.preview(sessions)
        suite.expect(preview.rows.map(\.pid) == [1, 2, 3] && preview.hidden == 2, "the card shows three and counts the rest")
        suite.expect(AgentSessionsSupport.preview(Array(sessions.prefix(2))).hidden == 0, "nothing is hidden below the limit")
        let mixed = sessions.prefix(2).map { $0 } + [AgentSession(id: "h", kind: .hermes, pid: 9, identity: 9),
                                                      AgentSession(id: "c", kind: .codex, pid: 8, identity: 8)]
        suite.expect(AgentSessionsSupport.shown(mixed, providers: [.codex]).map(\.pid) == [9, 8],
                     "an agent the person stopped following is left out, and Hermes has no switch")
        let tree = [AgentSession(id: "a", kind: .claude, pid: 1, identity: 1),
                    AgentSession(id: "b", kind: .codex, pid: 2, identity: 2, depth: 1),
                    AgentSession(id: "c", kind: .claude, pid: 0, identity: 0, depth: 2),
                    AgentSession(id: "d", kind: .codex, pid: 3, identity: 3)]
        suite.expect(AgentSessionsSupport.shown(tree, providers: [.codex]).map(\.id) == ["d"]
                        && AgentSessionsSupport.shown(tree, providers: [.claude]).map(\.id) == ["a"]
                        && AgentSessionsSupport.shown(tree, providers: [.claude, .codex]).count == 4,
                     "what hangs beneath an agent the person does not follow goes with it")
        suite.expect(AgentSessionsSupport.sample(now: now).contains { $0.background } && AgentSessionsSupport.sample(now: now).count > 3,
                     "the Settings preview has example rows, one in the background")
    }
}
