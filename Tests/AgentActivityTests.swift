// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentActivityTests {
    static func run(_ suite: TestSuite) {
        suite.run("agent activity: Claude's transcript") { claude(suite) }
        suite.run("agent activity: Codex's rollout") { codex(suite) }
        suite.run("agent activity: Copilot and OpenCode") { copilotAndOpenCode(suite) }
        suite.run("agent activity: steps and lines") { steps(suite) }
        suite.run("agent activity: which log") { links(suite) }
        suite.run("agent activity: changed files") { changes(suite) }
        suite.run("agent activity: what the row says") { wording(suite) }
    }

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func claudeUser(_ content: Any, extra: [String: Any] = [:]) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content": content]].merging(extra) { $1 }
    }

    private static func claudeAssistant(_ items: [[String: Any]], stop: String? = nil) -> [String: Any] {
        var message: [String: Any] = ["role": "assistant", "content": items]
        message["stop_reason"] = stop
        return ["type": "assistant", "message": message]
    }

    private static func claude(_ suite: TestSuite) {
        var activity = AgentActivity()
        func feed(_ object: [String: Any]) { AgentActivitySupport.applyClaude(object, to: &activity) }

        feed(claudeUser("<command-name>/clear</command-name>"))
        feed(claudeUser("Caveat: the messages below", extra: ["isMeta": true]))
        suite.expect(activity.state == nil && activity.prompt == nil, "commands and injected turns are not prompts")

        feed(claudeUser("Add a dark\n  mode toggle"))
        suite.expect(activity.state == .thinking && activity.prompt == "Add a dark mode toggle", "a prompt starts a turn on one line")

        feed(claudeAssistant([["type": "tool_use", "id": "t1", "name": "Edit",
                               "input": ["file_path": "/Users/x/app/Sources/View.swift", "old_string": "a", "new_string": "b"]]],
                             stop: "tool_use"))
        suite.expect(activity.state == .running && activity.step == AgentStep(verb: .edit, target: "View.swift"),
                     "a tool call is the step, by its file's name")

        feed(["type": "api-request-blob", "message": ["role": "assistant",
                                                      "content": [["type": "tool_use", "id": "old", "name": "Bash", "input": [:]]]]])
        feed(claudeAssistant([["type": "tool_use", "id": "s1", "name": "Bash", "input": ["command": "ls"]]])
                .merging(["isSidechain": true]) { $1 })
        suite.expect(activity.step?.target == "View.swift" && activity.pending.count == 1,
                     "request blobs and a subagent's lines do not move the session")

        feed(claudeUser([["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]))
        suite.expect(activity.state == .thinking && activity.pending.isEmpty, "a tool's result returns the turn to thinking")

        feed(claudeAssistant([["type": "text", "text": "Done, the toggle is in Settings."]], stop: "end_turn"))
        suite.expect(activity.state == .finished && activity.reply == "Done, the toggle is in Settings.",
                     "the reply that ends the turn is kept")

        feed(claudeUser("Now add tests"))
        suite.expect(activity.state == .thinking && activity.reply == nil && activity.step == nil,
                     "a new prompt clears the last turn's reply and step")
        feed(claudeUser([["type": "text", "text": "[Request interrupted by user]"]]))
        suite.expect(activity.state == .finished && activity.prompt == "Now add tests", "an interruption ends the turn")

        var late = AgentActivity()
        AgentActivitySupport.applyClaude(["type": "last-prompt", "lastPrompt": "Refactor the parser"], to: &late)
        suite.expect(late.prompt == "Refactor the parser" && late.state == nil,
                     "a read starting mid-turn learns the prompt from Claude's note of it")

        feed(claudeUser("Try again"))
        feed(claudeAssistant([["type": "text", "text": "API Error: 529"]]).merging(["isApiErrorMessage": true]) { $1 })
        suite.expect(activity.state == .failed, "an API error fails the turn")

        // A turn's start is its first line read; a subagent's file is read as a sidechain.
        var turn = AgentActivity()
        let side: [String: Any] = ["isSidechain": true]
        AgentActivitySupport.applyClaude(claudeUser("Find the bug", extra: ["timestamp": "2027-01-15T08:00:00.000Z"]), to: &turn)
        var reply = claudeAssistant([["type": "text", "text": "On it"]])
        reply["timestamp"] = "2027-01-15T08:00:09.000Z"
        reply["message"] = (reply["message"] as? [String: Any] ?? [:]).merging(["model": "claude-opus-5-5"]) { $1 }
        AgentActivitySupport.applyClaude(reply, to: &turn)
        suite.expect(turn.turnStarted == AgentTimestamp.parse("2027-01-15T08:00:00.000Z") && turn.model == "claude-opus-5-5",
                     "a turn starts at its prompt's time, and a reply names its model")
        var notice = claudeAssistant([["type": "text", "text": "No response requested."]])
        notice["message"] = (notice["message"] as? [String: Any] ?? [:]).merging(["model": "<synthetic>"]) { $1 }
        AgentActivitySupport.applyClaude(notice, to: &turn)
        AgentActivitySupport.applyClaude(claudeUser("Next", extra: ["timestamp": "2027-01-15T09:00:00.000Z"]), to: &turn)
        suite.expect(turn.model == "claude-opus-5-5" && turn.turnStarted == AgentTimestamp.parse("2027-01-15T08:00:00.000Z"),
                     "Claude's own notices name no model, and a prompt during a turn joins it")
        var sub = AgentActivity()
        AgentActivitySupport.applyClaude(claudeUser("Look around", extra: side), to: &sub)
        AgentActivitySupport.applyClaude(claudeUser("Not mine", extra: side), to: &turn)
        suite.expect(sub.prompt == nil && turn.prompt == "Next", "a session's file skips its subagents' lines")
        AgentActivitySupport.applyClaude(claudeUser("Look around", extra: side), to: &sub, sidechain: true)
        AgentActivitySupport.applyClaude(claudeAssistant([["type": "tool_use", "id": "s1", "name": "Grep",
                                                           "input": ["pattern": "TODO"]]]).merging(side) { $1 },
                                         to: &sub, sidechain: true)
        suite.expect(sub.prompt == "Look around" && sub.state == .running && sub.step?.verb == .search,
                     "a subagent's own file is read for its task and steps")
    }

    private static func codex(_ suite: TestSuite) {
        var activity = AgentActivity()
        func feed(_ type: String, _ payload: [String: Any]) {
            AgentActivitySupport.applyCodex(["type": type, "payload": payload], to: &activity)
        }

        feed("event_msg", ["type": "task_started", "turn_id": "1"])
        feed("response_item", ["type": "message", "role": "user",
                               "content": [["type": "input_text", "text": "<environment_context>cwd</environment_context>"]]])
        feed("response_item", ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Run the tests"]]])
        suite.expect(activity.state == .thinking && activity.prompt == "Run the tests", "Codex's own context is not the prompt")

        feed("response_item", ["type": "function_call", "name": "exec_command", "call_id": "c1",
                               "arguments": #"{"cmd":["bash","-lc","npm test"],"workdir":"/x"}"#])
        suite.expect(activity.state == .running && activity.step == AgentStep(verb: .run, target: "npm test"),
                     "a shell call shows its script")
        feed("response_item", ["type": "function_call_output", "call_id": "c1", "output": "ok"])
        suite.expect(activity.state == .thinking, "its output returns the turn to thinking")

        feed("response_item", ["type": "custom_tool_call", "name": "apply_patch", "call_id": "c2",
                               "input": "*** Begin Patch\n*** Update File: src/app.ts\n@@\n-a\n+b\n*** End Patch"])
        suite.expect(activity.step == AgentStep(verb: .edit, target: "app.ts"), "a patch shows the first file it touches")
        feed("response_item", ["type": "custom_tool_call_output", "call_id": "c2", "output": "ok"])
        feed("event_msg", ["type": "task_complete", "last_agent_message": "All tests pass."])
        suite.expect(activity.state == .finished && activity.reply == "All tests pass.", "the turn ends with its last message")

        feed("event_msg", ["type": "task_started"])
        feed("event_msg", ["type": "turn_aborted"])
        suite.expect(activity.state == .finished, "an aborted turn is over")
        feed("event_msg", ["type": "task_started"])
        feed("event_msg", ["type": "task_complete", "last_agent_message": NSNull(), "error": ["message": "stream closed"]])
        suite.expect(activity.state == .failed, "a turn that completes with an error failed")
    }

    private static func copilotAndOpenCode(_ suite: TestSuite) {
        var copilot = AgentActivity()
        func event(_ type: String, _ data: [String: Any], agent: String? = nil) {
            var object: [String: Any] = ["type": type, "data": data]
            object["agentId"] = agent
            AgentActivitySupport.applyCopilot(object, to: &copilot)
        }
        event("user.message", ["content": "Fix the login bug"])
        event("assistant.message", ["content": "", "toolRequests": [["toolCallId": "r1", "name": "bash",
                                                                      "arguments": ["command": "git status"]]]])
        suite.expect(copilot.state == .running && copilot.step == AgentStep(verb: .run, target: "git status"),
                     "a Copilot tool request is the step")
        event("assistant.turn_end", [:])
        suite.expect(copilot.state == .running, "a tool round's turn end does not end the person's turn")
        event("tool.execution_start", ["toolCallId": "s1", "toolName": "view"], agent: "helper")
        event("tool.execution_complete", ["toolCallId": "r1"])
        event("assistant.message", ["content": "Fixed.", "phase": "response"])
        event("assistant.turn_end", [:])
        suite.expect(copilot.state == .finished && copilot.reply == "Fixed.", "the final round ends it with its reply")

        var openCode = AgentActivity()
        func part(_ data: [String: Any], id: String = "p", role: String = "assistant") {
            AgentActivitySupport.applyOpenCode(part: data, id: id, role: role, to: &openCode)
        }
        part(["type": "text", "text": "Rename the module"], role: "user")
        part(["type": "tool", "callID": "k1", "tool": "edit",
              "state": ["status": "running", "input": ["filePath": "/x/src/mod.ts"]]])
        suite.expect(openCode.state == .running && openCode.step == AgentStep(verb: .edit, target: "mod.ts"),
                     "an OpenCode tool part running is the step")
        part(["type": "tool", "callID": "k1", "tool": "edit", "state": ["status": "completed"]])
        part(["type": "text", "text": "Renamed."])
        part(["type": "step-finish", "reason": "stop"])
        suite.expect(openCode.state == .finished && openCode.reply == "Renamed." && openCode.prompt == "Rename the module",
                     "a step that stops ends the turn")
    }

    private static func steps(_ suite: TestSuite) {
        suite.expect(AgentActivitySupport.verb("mcp__github__create_issue") == .other("github · create_issue")
                        && AgentActivitySupport.verb("Frobnicate") == .other("Frobnicate")
                        && AgentActivitySupport.verb("WebFetch") == .web && AgentActivitySupport.verb("Task") == .delegate,
                     "tools without a verb go by their name, MCP ones by server and tool")
        suite.expect(AgentActivitySupport.target(["pattern": "TODO", "path": "/x/y/Sources"]) == "Sources"
                        && AgentActivitySupport.target([:]).isEmpty,
                     "a call's file comes before its pattern")
        suite.expect(AgentActivitySupport.line(String(repeating: "a", count: 300), limit: 10)?.count == 10
                        && AgentActivitySupport.line(" \n ", limit: 10) == nil
                        && AgentActivitySupport.line("IntelliJ IDEA", limit: 10) == "IntelliJ…",
                     "a line is cut to its limit with no space before the ellipsis, and blank text is none")

        let chunk = Data("tail of a line\n{\"a\":1}\n{\"b\":2}\n{\"c\"".utf8)
        let read = AgentActivitySupport.lines(chunk, partialStart: true)
        suite.expect(read.lines.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#]
                        && read.consumed == chunk.count - 4,
                     "a read starting mid-line skips it and leaves the unfinished last line for later")
        suite.expect(AgentActivitySupport.lines(Data("{\"c\"".utf8), partialStart: false).consumed == 0,
                     "a line without its end is not read yet")
    }

    private static func links(_ suite: TestSuite) {
        let started = now.addingTimeInterval(-600)
        func candidate(_ path: String, kind: AgentProcessKind = .codex, cwd: String = "/x/app",
                       created: Double, modified: Double) -> AgentLogCandidate {
            AgentLogCandidate(path: path, kind: kind, cwd: cwd, created: now.addingTimeInterval(-created),
                              modified: now.addingTimeInterval(-modified))
        }
        let logs = [candidate("old", created: 3600, modified: 1), candidate("new", created: 300, modified: 20),
                    candidate("newest", created: 200, modified: 5), candidate("copilot", kind: .copilot, created: 100, modified: 1),
                    candidate("elsewhere", cwd: "/x/other", created: 100, modified: 1)]
        let one = AgentLogRequest(pid: 1, kind: .codex, cwd: "/x/app", started: started)
        suite.expect(AgentActivitySupport.links([one], candidates: logs) == [1: "newest"],
                     "the one Codex in a folder takes its newest log begun since it started")
        let two = AgentLogRequest(pid: 2, kind: .codex, cwd: "/x/app", started: started)
        suite.expect(AgentActivitySupport.links([one, two], candidates: logs).isEmpty,
                     "two in one folder could own either log, so neither gets one")
        var held = two
        held.exact = "newest"
        suite.expect(AgentActivitySupport.links([one, held], candidates: logs) == [1: "new", 2: "newest"],
                     "a log held open is certain, and leaves the other process alone in its folder")

        let vscode: [String: Any] = ["type": "session_meta",
                                     "payload": ["cwd": "/x/app", "timestamp": "2027-01-15T08:00:00.000Z", "source": "vscode"]]
        let cli: [String: Any] = ["type": "session_meta", "payload": ["cwd": "/x/app", "timestamp": "2027-01-15T08:00:00.000Z"]]
        let subagent: [String: Any] = ["type": "session_meta",
                                       "payload": ["cwd": "/x/app", "timestamp": "2027-01-15T08:00:00.000Z",
                                                   "source": ["subagent": "review"]]]
        suite.expect(AgentActivitySupport.codexCandidate(head: vscode, path: "a", modified: now) == nil
                        && AgentActivitySupport.codexCandidate(head: subagent, path: "a", modified: now) == nil
                        && AgentActivitySupport.codexCandidate(head: cli, path: "a", modified: now)?.cwd == "/x/app",
                     "the threads Codex runs for an app or a subagent are no CLI session's")

        suite.expect(AgentActivitySupport.argument(after: ["resume"], in: ["codex", "resume", "019e-ab"]) == "019e-ab"
                        && AgentActivitySupport.argument(after: ["--resume"], in: ["copilot", "--resume=s1"]) == "s1"
                        && AgentActivitySupport.argument(after: ["resume"], in: ["codex", "resume", "--last"]) == nil,
                     "a resumed session is named after its flag")
        suite.expect(AgentActivitySupport.isLog("/Users/x/.codex/sessions/2027/01/15/rollout-a.jsonl", kind: .codex)
                        && !AgentActivitySupport.isLog("/Users/x/.codex/log/codex-tui.log", kind: .codex)
                        && AgentActivitySupport.isLog("/Users/x/.copilot/session-state/s1/events.jsonl", kind: .copilot),
                     "only a session log held open links a process")
    }

    private static func wording(_ suite: TestSuite) {
        let text = FeatureStrings.notchAgents(.enUS)
        var session = AgentSession(id: "1", kind: .claude, pid: 1, identity: 1, status: .working)
        suite.expect(text.activity(of: session) == nil, "a session whose log is unknown says nothing more")
        session.activity = AgentActivity(state: .running, step: AgentStep(verb: .edit, target: "App.swift"))
        suite.expect(text.activity(of: session) == "Edits · App.swift", "a running step reads as verb and target")
        session.status = .waiting
        suite.expect(text.activity(of: session) == "Done", "Claude's file saying idle outranks a log cut short")
        session.status = .asking
        suite.expect(text.activity(of: session) == "Needs you", "a session waiting on the person says so first")
        session.status = .waiting
        session.activity = AgentActivity(state: .finished, reply: "All set.")
        suite.expect(text.activity(of: session) == "Done · All set.", "a finished turn shows its reply")

        let file = AgentSessionsSupport.parseClaudeFile(Data(#"""
            {"pid":7,"sessionId":"s","startedAt":1800000000000,"status":"waiting","waitingFor":"approve Bash"}
            """#.utf8))
        suite.expect(file?.asking == true && file?.waitingFor == "approve Bash" && file?.working == nil,
                     "Claude's session file says when it waits on the person")
    }

    private static func changes(_ suite: TestSuite) {
        typealias Line = AgentDiffLine
        suite.expect(AgentActivitySupport.hunks(unified: ["--- a/x", "+++ b/x", "@@ -1,2 +1,2 @@", " keep", "--- rule", "+=== rule",
                                                          "@@ -9 +9 @@", "-old", "+new", "\\ No newline at end of file"])
                        == [[Line(kind: .context, text: "keep"), Line(kind: .removed, text: "-- rule"), Line(kind: .added, text: "=== rule")],
                            [Line(kind: .removed, text: "old"), Line(kind: .added, text: "new")]],
                     "headers count only before a hunk, so a removed line starting with dashes stays")

        let patch = "*** Begin Patch\n*** Update File: src/a.ts\n@@ fn\n ctx\n-x\n+y\n*** Add File: src/b.ts\n+one\n+two\n"
            + "*** Delete File: src/c.ts\n*** End Patch"
        let changes = AgentActivitySupport.patchChanges(patch)
        suite.expect(changes.map(\.path) == ["src/a.ts", "src/b.ts"]
                        && changes[0].hunks == [[Line(kind: .context, text: "ctx"), Line(kind: .removed, text: "x"), Line(kind: .added, text: "y")]]
                        && changes[1].hunks.joined().allSatisfy { $0.kind == .added },
                     "a Codex patch gives each updated and added file its lines")

        suite.expect(AgentActivitySupport.hunk(old: "a\nb\nc", new: "a\nB\nc")
                        == [Line(kind: .context, text: "a"), Line(kind: .removed, text: "b"), Line(kind: .added, text: "B"),
                            Line(kind: .context, text: "c")],
                     "two versions of a text interleave what changed between what stayed")

        var activity = AgentActivity()
        AgentActivitySupport.applyClaude(claudeUser([["type": "tool_result", "tool_use_id": "t", "content": "ok"]],
            extra: ["toolUseResult": ["filePath": "/x/View.swift",
                                      "structuredPatch": [["oldStart": 1, "lines": [" a", "-b", "+c", "+d"]]]]]), to: &activity)
        AgentActivitySupport.applyClaude(claudeUser([["type": "tool_result", "tool_use_id": "u", "content": "ok"]],
            extra: ["toolUseResult": ["type": "create", "filePath": "/x/New.swift", "content": "one\ntwo",
                                      "structuredPatch": [] as [Any]]]), to: &activity)
        AgentActivitySupport.applyClaude(claudeUser([["type": "tool_result", "tool_use_id": "v", "content": "ok"]],
            extra: ["toolUseResult": ["filePath": "/x/View.swift", "structuredPatch": [["lines": ["-e"]]]]]), to: &activity)
        var shell = AgentActivity()
        AgentActivitySupport.applyClaude(claudeUser([["type": "tool_result", "tool_use_id": "w", "content": ""]],
            extra: ["toolUseResult": ["stdout": "", "bashEditDiff": ["files": [["filePath": "/x/sed.txt",
                                                                                  "hunks": [["lines": ["-a", "+b"]]]]]]]]), to: &shell)
        suite.expect(shell.files.first?.path == "/x/sed.txt" && shell.files.first?.added == 1,
                     "what a shell command changed counts as the session's change")
        suite.expect(activity.files.map(\.name) == ["View.swift", "New.swift"]
                        && activity.files[0].added == 2 && activity.files[0].removed == 2 && activity.files[0].hunks.count == 2
                        && activity.files[1].added == 2,
                     "Claude's patches add up per file, a new file counts every line, and the latest file leads")
        activity.began()
        suite.expect(activity.files.count == 2, "a new turn keeps the session's changed files")

        var big = AgentActivity()
        big.changed("/x/huge.txt", hunks: [AgentActivitySupport.added(String(repeating: "l\n", count: AgentActivitySupport.diffLineLimit + 50))])
        suite.expect(big.files[0].added == AgentActivitySupport.diffLineLimit + 51 && big.files[0].truncated
                        && big.files[0].hunks.joined().count == AgentActivitySupport.diffLineLimit,
                     "lines past the limit are counted but not kept")
        for index in 0...AgentActivitySupport.fileLimit { big.changed("/x/\(index)", hunks: [[Line(kind: .added, text: "")]]) }
        suite.expect(big.files.count == AgentActivitySupport.fileLimit && big.files.first?.path == "/x/\(AgentActivitySupport.fileLimit)",
                     "only the latest files are kept")

        var copilot = AgentActivity()
        AgentActivitySupport.applyCopilot(["type": "assistant.message", "data": ["toolRequests": [
            ["toolCallId": "e", "name": "str_replace_editor", "arguments": ["path": "/x/a.py", "old_str": "x = 1", "new_str": "x = 2"]]]]],
            to: &copilot)
        var openCode = AgentActivity()
        AgentActivitySupport.applyOpenCode(part: ["type": "tool", "callID": "k", "tool": "edit",
                                                  "state": ["status": "completed", "input": ["filePath": "/x/b.ts"],
                                                            "metadata": ["diff": "Index: /x/b.ts\n--- /x/b.ts\n+++ /x/b.ts\n@@ -1 +1 @@\n-a\n+b\n"]]],
                                           id: "p", role: "assistant", to: &openCode)
        suite.expect(copilot.files.first?.added == 1 && copilot.files.first?.removed == 1
                        && openCode.files.first?.path == "/x/b.ts" && openCode.files.first?.added == 1,
                     "Copilot's edit arguments and OpenCode's diff become changed files")
    }
}
