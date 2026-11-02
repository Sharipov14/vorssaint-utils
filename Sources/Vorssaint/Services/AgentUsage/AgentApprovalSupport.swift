// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// A tool call Claude waits to have allowed, held while the notch asks.
struct AgentApproval: Identifiable, Equatable {
    let id: UUID
    let cwd: String?
    let tool: String
    /// The command, file or address the tool is about to use.
    let detail: String?
    let received: Date
    /// The app the session runs in.
    var host: String?
    /// Answered in the terminal or the editor; the card says so a moment before it goes.
    var answered = false

    var folder: String { cwd.map { ($0 as NSString).lastPathComponent } ?? "" }
    var deadline: Date { received.addingTimeInterval(AgentApprovalSupport.wait) }
}

/// A request's tool call followed through its session's transcript. Claude
/// asks in the terminal at the same time as the hook and, answered there,
/// leaves the hook waiting; the call's result is the sign.
// ponytail: a command allowed in the terminal shows its result only once it
// ends, so a long one keeps its card until then or the wait runs out.
struct AgentApprovalTrail {
    let path: String
    let tool: String
    let input: NSDictionary
    let received: Date
    /// Calls of the tool without a result yet, oldest first: those with the
    /// request's input, then any other, should Claude have reworded it.
    private var same: [String] = []
    private var other: [String] = []

    init(path: String, tool: String, input: NSDictionary, received: Date) {
        self.path = path
        self.tool = tool
        self.input = input
        self.received = received
    }

    /// True once a line gives the call its result. Results logged well
    /// before the request belong to earlier calls and only close those.
    mutating func settles(with object: [String: Any]) -> Bool {
        let items = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch object["type"] as? String {
        case "assistant":
            for item in items where item["type"] as? String == "tool_use" && item["name"] as? String == tool {
                guard let id = item["id"] as? String else { continue }
                if (item["input"] as? NSDictionary)?.isEqual(input) == true { same.append(id) } else { other.append(id) }
            }
        case "user":
            let recent = AgentLogParser.timestamp(object["timestamp"]).map { $0 >= received.addingTimeInterval(-1) } ?? true
            for item in items where item["type"] as? String == "tool_result" {
                guard let id = item["tool_use_id"] as? String else { continue }
                let ours = id == (same.first ?? other.first)
                same.removeAll { $0 == id }
                other.removeAll { $0 == id }
                if ours && recent { return true }
            }
        default: break
        }
        return false
    }
}

/// What a connection has sent so far.
enum AgentHookRequest: Equatable {
    case incomplete
    case invalid
    case body(Data)
}

/// Claude's PermissionRequest hook, handed to the app by curl over a socket
/// only this account can open. With the app closed or the island away, curl
/// prints nothing and Claude asks in the terminal as it always does.
enum AgentApprovalSupport {
    /// How long the notch asks before the terminal does; Claude waits meanwhile.
    static let wait: TimeInterval = 30
    static let socketName = "agents.sock"
    /// `sun_path` holds 104 bytes, the terminating zero included.
    static let socketPathLimit = 103
    static let requestLimit = 4 << 20
    static let pendingLimit = 8
    static let detailLimit = 300
    /// How long a card answered elsewhere says so.
    static let answeredNote: TimeInterval = 3
    /// Read from a transcript when a request comes: its call was written just before.
    static let trailRead = 1024 * 1024
    /// The tools whose question is more than allow or deny stay in the terminal.
    static let terminalTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    // MARK: The hook

    /// curl gives up a little after the notch does, and Claude a little after curl.
    static func command(socket: String) -> String {
        "/usr/bin/curl -s --max-time \(Int(wait) + 10) -H 'Expect:' --unix-socket \(shellQuoted(socket)) "
            + "--data-binary @- http://localhost/permission || true"
    }

    static var timeout: Int { Int(wait) + 15 }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The group added to `hooks.PermissionRequest`.
    static func group(command: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command, "timeout": timeout] as [String: Any]]]
    }

    static func isInstalled(in settings: [String: Any], socket: String) -> Bool {
        groups(in: settings)?.contains { group in
            (group["hooks"] as? [[String: Any]])?.contains { isOurs($0, socket: socket) } == true
        } == true
    }

    /// `settings` with this app's hook removed and, given a command, added
    /// once. Nil when "hooks" or its PermissionRequest list has a shape this
    /// does not know, which is left alone rather than replaced.
    static func settings(_ settings: [String: Any], installing command: String?, socket: String) -> [String: Any]? {
        guard var groups = groups(in: settings) else { return nil }
        var result = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        groups = groups.compactMap { group in
            guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
            let kept = handlers.filter { !isOurs($0, socket: socket) }
            guard kept.count != handlers.count else { return group }
            guard !kept.isEmpty else { return nil }
            var trimmed = group
            trimmed["hooks"] = kept
            return trimmed
        }
        if let command { groups.append(group(command: command)) }
        hooks["PermissionRequest"] = groups.isEmpty ? nil : groups
        result["hooks"] = hooks.isEmpty ? nil : hooks
        return result
    }

    /// The PermissionRequest groups; nil when they cannot be read safely.
    private static func groups(in settings: [String: Any]) -> [[String: Any]]? {
        guard let value = settings["hooks"] else { return [] }
        guard let hooks = value as? [String: Any] else { return nil }
        guard let groups = hooks["PermissionRequest"] else { return [] }
        return groups as? [[String: Any]]
    }

    private static func isOurs(_ handler: [String: Any], socket: String) -> Bool {
        (handler["command"] as? String)?.contains(shellQuoted(socket)) == true
    }

    /// The file as Claude writes it, `JSON.stringify(settings, null, 2)` and a
    /// newline, so a rewrite changes no more than the order of its keys, which
    /// reading it does not keep.
    static func json(_ value: Any, indent: String = "") -> String {
        let inner = indent + "  "
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            return "{\n" + object.keys.sorted().map { inner + quoted($0) + ": " + json(object[$0]!, indent: inner) }
                .joined(separator: ",\n") + "\n" + indent + "}" + (indent.isEmpty ? "\n" : "")
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\n" + array.map { inner + json($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case let string as String:
            return quoted(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            guard ["d", "f"].contains(String(cString: number.objCType)) else { return number.stringValue }
            let double = number.doubleValue
            // JavaScript writes 2.0 as 2; Swift's description is the shortest that reads back the same.
            if let whole = Int64(exactly: double), abs(double) < 1e15 { return String(whole) }
            return double.isFinite ? "\(double)" : "null"
        default:
            return "null"
        }
    }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    // MARK: A request

    /// The body of curl's POST, once all of it has arrived.
    static func request(_ data: Data) -> AgentHookRequest {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 16 << 10 ? .invalid : .incomplete
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8),
              head.hasPrefix("POST ") else { return .invalid }
        let length = head.split(separator: "\r\n").dropFirst().lazy.compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first
        guard let length, length >= 0, length <= requestLimit else { return .invalid }
        let body = data[end.upperBound...]
        return body.count < length ? .incomplete : .body(Data(body.prefix(length)))
    }

    /// What to ask about; nil for anything the terminal should ask itself.
    static func approval(from body: Data, id: UUID, now: Date) -> AgentApproval? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["hook_event_name"] as? String == "PermissionRequest",
              let tool = object["tool_name"] as? String, !tool.isEmpty, !terminalTools.contains(tool) else { return nil }
        let input = object["tool_input"] as? [String: Any] ?? [:]
        let detail = ["command", "file_path", "notebook_path", "url", "pattern", "query", "description"].lazy
            .compactMap { input[$0] as? String }
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        return AgentApproval(id: id, cwd: object["cwd"] as? String, tool: tool,
                             detail: detail.map { String($0.prefix(detailLimit)) }, received: now)
    }

    /// Where the request's call shows: the session's transcript, or a
    /// subagent's own beside it. Nil when the request names none.
    static func trail(from body: Data, received: Date) -> AgentApprovalTrail? {
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let tool = object["tool_name"] as? String,
              let transcript = object["transcript_path"] as? String, transcript.hasSuffix(".jsonl") else { return nil }
        var path = transcript
        if let agent = object["agent_id"] as? String, !agent.isEmpty, !agent.contains("/") {
            path = String(transcript.dropLast(6)) + "/subagents/" + (agent.hasPrefix("agent-") ? agent : "agent-" + agent) + ".jsonl"
        }
        return AgentApprovalTrail(path: path, tool: tool, input: object["tool_input"] as? NSDictionary ?? [:], received: received)
    }

    /// curl prints the body; an empty one leaves Claude to ask in the terminal.
    static func response(allow: Bool?) -> Data {
        var body = Data()
        if let allow {
            var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
            if !allow { decision["message"] = "The person denied this from the notch." }
            let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision] as [String: Any]]
            body = (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
