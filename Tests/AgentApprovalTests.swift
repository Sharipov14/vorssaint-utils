// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

enum AgentApprovalTests {
    static func run(_ suite: TestSuite) {
        suite.run("agent approvals: the hook in Claude's settings") { settings(suite) }
        suite.run("agent approvals: a request and its answer") { requests(suite) }
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
        let question = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"AskUserQuestion","tool_input":{}}"#.utf8)
        let other = Data(#"{"hook_event_name":"PreToolUse","tool_name":"Bash"}"#.utf8)
        suite.expect(AgentApprovalSupport.approval(from: question, id: UUID(), now: now) == nil
                        && AgentApprovalSupport.approval(from: other, id: UUID(), now: now) == nil,
                     "a question, or another event, is left to the terminal")

        func output(_ allow: Bool?) -> String { String(decoding: AgentApprovalSupport.response(allow: allow), as: UTF8.self) }
        suite.expect(output(true).hasSuffix(#"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
                        && output(false).contains(#""behavior":"deny""#)
                        && output(nil).contains("Content-Length: 0\r\n") && output(nil).hasSuffix("\r\n\r\n"),
                     "allow and deny are Claude's decision; no answer is an empty body")
    }
}
