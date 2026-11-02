// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentApprovalTests {
    static func run(_ suite: TestSuite) {
        suite.run("agent approvals: the hook in Claude's settings") { settings(suite) }
        suite.run("agent approvals: a request and its answer") { requests(suite) }
        suite.run("agent approvals: answered in the terminal") { trails(suite) }
    }

    private static let socket = "/Users/o'neil/Library/Application Support/com.vorssaint.utils/agents.sock"

    private static func settings(_ suite: TestSuite) {
        let command = AgentApprovalSupport.command(socket: socket)
        suite.expect(command.contains("--unix-socket '/Users/o'\\''neil/Library/Application Support/com.vorssaint.utils/agents.sock'")
                        && command.hasSuffix("|| true"),
                     "the socket path is quoted for the shell, and a closed app never fails the hook")

        let theirs: [String: Any] = ["hooks": [["type": "command", "command": "node /x/hook.js", "timeout": 5]]]
        let original: [String: Any] = ["model": "opus", "hooks": ["PermissionRequest": [theirs], "Stop": [theirs]]]
        let installed = AgentApprovalSupport.settings(original, installing: command, socket: socket)
        let again = installed.flatMap { AgentApprovalSupport.settings($0, installing: command, socket: socket) }
        let groups = ((again?["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? []
        suite.expect(groups.count == 2 && again?["model"] as? String == "opus"
                        && ((again?["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count == 1,
                     "installing twice adds the hook once, beside the person's own")
        suite.expect(installed.map { AgentApprovalSupport.isInstalled(in: $0, socket: socket) } == true
                        && !AgentApprovalSupport.isInstalled(in: original, socket: socket),
                     "the installed hook is recognized by its socket")
        let older = command.replacingOccurrences(of: "--max-time \(Int(AgentApprovalSupport.questionWait) + 10)", with: "--max-time 40")
        let outdated: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [["type": "command", "command": older, "timeout": 45]]]]]]
        let updated = AgentApprovalSupport.settings(outdated, installing: command, socket: socket)
        let handlers = (((updated?["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]) ?? [])
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
        suite.expect(older != command && !AgentApprovalSupport.isInstalled(in: outdated, socket: socket)
                        && handlers.count == 1 && handlers.first?["command"] as? String == command
                        && handlers.first?["timeout"] as? Int == AgentApprovalSupport.timeout,
                     "an earlier hook that gives up too soon reads as off, and adding it again replaces it")
        suite.expect(AgentApprovalSupport.timeout > Int(AgentApprovalSupport.questionWait) + 10
                        && AgentApprovalSupport.questionWait > AgentApprovalSupport.wait,
                     "curl and Claude outlast the longest card")

        let removed = again.flatMap { AgentApprovalSupport.settings($0, installing: nil, socket: socket) }
        suite.expect(removed.map { NSDictionary(dictionary: $0).isEqual(to: original) } == true,
                     "removing the hook gives back what was there")
        let alone = AgentApprovalSupport.settings([:], installing: command, socket: socket)
            .flatMap { AgentApprovalSupport.settings($0, installing: nil, socket: socket) }
        suite.expect(alone?.isEmpty == true, "a file that had no hooks has none again")

        let shared: [String: Any] = ["hooks": ["PermissionRequest": [["hooks": [
            ["type": "command", "command": "node /x/hook.js"], ["type": "command", "command": command]]]]]]
        let kept = AgentApprovalSupport.settings(shared, installing: nil, socket: socket)
        suite.expect((((kept?["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]])?.first?["hooks"] as? [Any])?.count == 1,
                     "a group shared with another handler keeps that handler")
        let source = #"{"b":[0.1,2.0,-3,true,null,[],{}],"a":{"s":"x/y é \"q\"\n\u0001","n":1.5e-7}}"#
        let parsed = (try? JSONSerialization.jsonObject(with: Data(source.utf8))) ?? [:]
        let written = AgentApprovalSupport.json(parsed)
        suite.expect(written == """
                        {
                          "a": {
                            "n": 1.5e-07,
                            "s": "x/y é \\"q\\"\\n\\u0001"
                          },
                          "b": [
                            0.1,
                            2,
                            -3,
                            true,
                            null,
                            [],
                            {}
                          ]
                        }

                        """, "settings are written as Claude writes them: \(written)")
        suite.expect((try? JSONSerialization.jsonObject(with: Data(written.utf8))).map { NSDictionary(dictionary: $0 as! [String: Any]).isEqual(to: parsed as! [String: Any]) } == true,
                     "what is written reads back the same")
        suite.expect(AgentApprovalSupport.settings(["hooks": "x"], installing: command, socket: socket) == nil
                        && AgentApprovalSupport.settings(["hooks": ["PermissionRequest": "x"]], installing: command, socket: socket) == nil,
                     "hooks of an unknown shape are left alone, not replaced")
    }

    private static func requests(_ suite: TestSuite) {
        let body = Data(#"{"hook_event_name":"PermissionRequest","cwd":"/Users/x/app","tool_name":"Bash","tool_input":{"command":"npm  run\n test","description":"Run tests"}}"#.utf8)
        let head = "POST /permission HTTP/1.1\r\nHost: localhost\r\nContent-Length: \(body.count)\r\n\r\n"
        let whole = Data(head.utf8) + body
        suite.expect(AgentApprovalSupport.request(whole) == .body(body)
                        && AgentApprovalSupport.request(whole.prefix(whole.count - 3)) == .incomplete
                        && AgentApprovalSupport.request(Data(head.utf8).prefix(20)) == .incomplete,
                     "the body is read once all of it has arrived")
        suite.expect(AgentApprovalSupport.request(Data("GET / HTTP/1.1\r\n\r\n".utf8)) == .invalid
                        && AgentApprovalSupport.request(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) == .invalid
                        && AgentApprovalSupport.request(Data("POST / HTTP/1.1\r\n\r\n".utf8)) == .invalid,
                     "anything but a bounded POST is turned away")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let approval = AgentApprovalSupport.approval(from: body, id: UUID(), now: now)
        suite.expect(approval?.tool == "Bash" && approval?.detail == "npm run test" && approval?.folder == "app"
                        && approval?.deadline == now.addingTimeInterval(AgentApprovalSupport.wait),
                     "the card names the tool, its command on one line, and the folder")
        let empty = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#.utf8)
        let unlabeled = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which?","options":[{"label":"A"},{"description":"no label"}]}]}}"#.utf8)
        let plan = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"ExitPlanMode","tool_input":{"plan":"x"}}"#.utf8)
        let other = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)
        suite.expect([empty, unlabeled, plan, other].allSatisfy { AgentApprovalSupport.approval(from: $0, id: UUID(), now: now) == nil },
                     "a question the notch cannot show, a plan, or another event, is left to the terminal")

        let asking = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"Red"},{"label":"Blue","description":"Calm and cool","preview":"b"}],"multiSelect":false},{"question":"Which sizes?","header":"","options":[{"label":"S","description":""},{"label":"M"},{"label":"L"}],"multiSelect":true}]}}"#.utf8)
        let asked = AgentApprovalSupport.approval(from: asking, id: UUID(), now: now)
        let questions = asked?.questions ?? []
        suite.expect(questions == [
            AgentQuestion(text: "Which color?", header: "Color", options: [.init(label: "Red", detail: nil), .init(label: "Blue", detail: "Calm and cool")], multiple: false),
            AgentQuestion(text: "Which sizes?", header: nil, options: [.init(label: "S", detail: nil), .init(label: "M", detail: nil), .init(label: "L", detail: nil)], multiple: true),
        ] && asked?.isQuestion == true && asked?.deadline == now.addingTimeInterval(AgentApprovalSupport.questionWait),
                     "a question keeps its choices, a description that only repeats the label dropped, and waits longer")
        let answers = AgentApprovalSupport.answers(to: questions, picks: [["Blue"], ["S", "my own"]])
        let sent = String(decoding: AgentApprovalSupport.response(allow: true, asked: asked?.asked, answers: answers), as: UTF8.self)
        let decision = (try? JSONSerialization.jsonObject(with: Data((sent.components(separatedBy: "\r\n\r\n").last ?? "").utf8)))
            .flatMap { (($0 as? [String: Any])?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any] }
        let input = decision?["updatedInput"] as? [String: Any]
        let original = (try? JSONSerialization.jsonObject(with: asking) as? [String: Any])
            .flatMap { ($0["tool_input"] as? [String: Any])?["questions"] as? NSArray }
        suite.expect(decision?["behavior"] as? String == "allow"
                        && (input?["questions"] as? NSArray).map { $0.isEqual(original) } == true
                        && NSDictionary(dictionary: input?["answers"] as? [String: Any] ?? [:])
                            .isEqual(to: ["Which color?": "Blue", "Which sizes?": ["S", "my own"]]),
                     "answers go back with Claude's questions as they came: a label, or a list where several are picked")
        suite.expect(AgentApprovalSupport.answers(to: questions, picks: [["Red"], []]).count == 1,
                     "a question left unanswered is left out")

        let offered = Data(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"npm test"},"permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test:*"}],"behavior":"allow","destination":"localSettings"}]}"#.utf8)
        let rules = AgentApprovalSupport.approval(from: offered, id: UUID(), now: now)?.rules
        suite.expect(rules?.count == 1 && AgentApprovalSupport.approval(from: offered, id: UUID(), now: now)?.session == "s1"
                        && approval?.rules == nil && approval?.session == nil,
                     "a request keeps its session and the rules Claude offers, and none when it offers none")
        let always = String(decoding: AgentApprovalSupport.response(allow: true, rules: rules), as: UTF8.self)
        suite.expect(always.contains(#""behavior":"allow""#)
                        && always.contains(#""updatedPermissions":[{"behavior":"allow","destination":"localSettings","rules":[{"ruleContent":"npm test:*","toolName":"Bash"}],"type":"addRules"}]"#)
                        && !String(decoding: AgentApprovalSupport.response(allow: false, rules: rules), as: UTF8.self).contains("updatedPermissions"),
                     "always allows and hands Claude its own rules to keep; a denial keeps none")

        func output(_ allow: Bool?) -> String { String(decoding: AgentApprovalSupport.response(allow: allow), as: UTF8.self) }
        suite.expect(output(true).hasSuffix(#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
                        && output(false).contains(#""behavior":"deny""#)
                        && output(nil).contains("Content-Length: 0\r\n") && output(nil).hasSuffix("\r\n\r\n"),
                     "allow and deny are Claude's decision; no answer is an empty body")
    }

    private static func trails(_ suite: TestSuite) {
        let received = Date(timeIntervalSince1970: 1_800_000_000)
        func body(_ extra: String = "") -> Data {
            Data(#"{"hook_event_name":"PermissionRequest","transcript_path":"/u/.claude/projects/p/s1.jsonl","tool_name":"Bash","tool_input":{"command":"ls","description":"List"}\#(extra)}"#.utf8)
        }
        suite.expect(AgentApprovalSupport.trail(from: body(), received: received)?.path == "/u/.claude/projects/p/s1.jsonl"
                        && AgentApprovalSupport.trail(from: body(#","agent_id":"a08b""#), received: received)?.path
                            == "/u/.claude/projects/p/s1/subagents/agent-a08b.jsonl"
                        && AgentApprovalSupport.trail(from: body(#","agent_id":"../x""#), received: received)?.path
                            == "/u/.claude/projects/p/s1.jsonl",
                     "a request follows its session's transcript, or its subagent's")

        func call(_ id: String, _ command: String, tool: String = "Bash") -> [String: Any] {
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": id, "name": tool,
                                                           "input": ["command": command, "description": "List"]]]]]
        }
        func result(_ id: String, at offset: TimeInterval) -> [String: Any] {
            ["type": "user", "timestamp": ISO8601DateFormatter().string(from: received.addingTimeInterval(offset)),
             "message": ["content": [["type": "tool_result", "tool_use_id": id]]]]
        }
        func settles(_ lines: [[String: Any]]) -> Bool {
            guard var trail = AgentApprovalSupport.trail(from: body(), received: received) else { return false }
            return lines.contains { trail.settles(with: $0) }
        }
        suite.expect(settles([call("old", "ls"), call("t1", "ls"), result("old", at: -60), result("t1", at: 4)])
                        && !settles([call("old", "ls"), call("t1", "ls"), result("old", at: -60)]),
                     "the call's result settles it; the same command's earlier result does not")
        suite.expect(!settles([call("t1", "ls"), call("t2", "pwd"), result("t2", at: 4)])
                        && !settles([call("t1", "ls"), call("r1", "ls", tool: "Read"), result("r1", at: 4)]),
                     "another call's result leaves the card")
        suite.expect(settles([call("t1", "ls -la"), result("t1", at: 4)]) && !settles([call("t1", "ls")]),
                     "a call Claude reworded still settles once it has its result, and not before")
    }
}
