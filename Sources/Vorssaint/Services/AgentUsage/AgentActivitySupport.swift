// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// What a tool call does, in the words the Live tab says it with.
enum AgentToolVerb: Equatable {
    case run, read, edit, search, web, plan, delegate
    /// A tool with no verb of its own, by its name.
    case other(String)
}

struct AgentStep: Equatable {
    let verb: AgentToolVerb
    /// The command, file or query, on one line; empty when the call names none.
    let target: String
}

struct AgentDiffLine: Equatable {
    enum Kind: Equatable { case context, added, removed }
    let kind: Kind
    let text: String
}

/// A file a session changed, with as many of its lines as are kept.
struct AgentFileDiff: Equatable, Identifiable {
    let path: String
    var added = 0
    var removed = 0
    /// In the order they were made.
    var hunks: [[AgentDiffLine]] = []
    /// Lines past the limit were counted, not kept.
    var truncated = false

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// What a session's log says it is doing. Prompts, replies and changed lines
/// are kept only in memory while the Live tab shows, and never written.
struct AgentActivity: Equatable {
    enum State: Equatable { case thinking, running, finished, failed }

    var state: State?
    /// The tool running now, or the last one the turn ran.
    var step: AgentStep?
    var prompt: String?
    var reply: String?
    /// Tool calls still waiting for their result, by call id.
    var pending: [String: AgentStep] = [:]
    /// The files the session changed, the latest first; kept across turns.
    var files: [AgentFileDiff] = []

    var inTurn: Bool { state == .thinking || state == .running }

    /// A new turn starts from nothing.
    mutating func began() {
        state = .thinking
        step = nil
        reply = nil
        pending = [:]
    }

    /// A prompt sent while a turn runs joins it; any other starts one.
    mutating func asked(_ text: String?) {
        guard let text = AgentActivitySupport.prompt(text) else { return }
        if !inTurn { began() }
        prompt = text
    }

    mutating func called(_ id: String, _ step: AgentStep) {
        if !inTurn { began() }
        pending[id] = step
        self.step = step
        state = .running
    }

    mutating func returned(_ id: String) {
        guard pending.removeValue(forKey: id) != nil else { return }
        if pending.isEmpty && state == .running { state = .thinking }
    }

    mutating func replied(_ text: String?) {
        if let text = AgentActivitySupport.line(text.map(AgentActivitySupport.plain), limit: AgentActivitySupport.replyLimit) {
            reply = text
        }
    }

    /// Adds a change to its file, which moves to the top of the list.
    mutating func changed(_ path: String, hunks: [[AgentDiffLine]]) {
        guard !path.isEmpty, !hunks.joined().isEmpty else { return }
        var file = files.firstIndex { $0.path == path }.map { files.remove(at: $0) } ?? AgentFileDiff(path: path)
        var kept = file.hunks.reduce(0) { $0 + $1.count }
        for hunk in hunks where !hunk.isEmpty {
            file.added += hunk.filter { $0.kind == .added }.count
            file.removed += hunk.filter { $0.kind == .removed }.count
            let room = max(0, AgentActivitySupport.diffLineLimit - kept)
            if hunk.count > room { file.truncated = true }
            guard room > 0 else { continue }
            file.hunks.append(Array(hunk.prefix(room)))
            kept += min(room, hunk.count)
        }
        files.insert(file, at: 0)
        if files.count > AgentActivitySupport.fileLimit { files.removeLast(files.count - AgentActivitySupport.fileLimit) }
    }

    mutating func ended(failed: Bool) {
        pending = [:]
        state = failed ? .failed : .finished
    }
}

/// A log an agent may be writing, as its first line describes it.
struct AgentLogCandidate: Equatable {
    /// The file, or `database#session` for OpenCode, as the usage reader names its turns.
    let path: String
    let kind: AgentProcessKind
    let cwd: String
    let created: Date
    let modified: Date
}

/// A running agent whose log is looked for.
struct AgentLogRequest: Equatable {
    let pid: Int32
    let kind: AgentProcessKind
    let cwd: String?
    let started: Date
    /// The log the process holds open or names in its arguments.
    var exact: String?
}

enum AgentActivitySupport {
    static let promptLimit = 140
    static let replyLimit = 200
    static let targetLimit = 80
    /// Read from a log first seen: the turn running now and the changes before it.
    // ponytail: the file list covers this much of a log and what is written
    // while the tab shows; reading a whole transcript would cover the session.
    static let firstRead = 1024 * 1024
    /// Read from a log in one tick at most; the rest waits for the next.
    static let tickRead = 1024 * 1024
    /// Codex runs these besides the person's own CLI sessions, in the same folders.
    static let codexSources: Set<String> = ["cli", "exec"]
    static let fileLimit = 50
    static let diffLineLimit = 600

    // MARK: Text

    /// Text on one line, whitespace collapsed, cut at `limit`; nil when empty.
    static func line(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !words.isEmpty else { return nil }
        return words.count > limit ? String(words.prefix(limit - 1)) + "…" : words
    }

    /// A reply's Markdown read as text: no emphasis, code ticks or heading marks.
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.drop { $0 == "#" } }
            .joined(separator: "\n")
    }

    /// What a person asked, leaving out what the agent itself injects as a
    /// user turn: command output, reminders, environment and instructions.
    static func prompt(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md"), !text.hasPrefix("[Request interrupted") else { return nil }
        return line(text, limit: promptLimit)
    }

    // MARK: Steps

    static func verb(_ tool: String) -> AgentToolVerb {
        switch tool.lowercased() {
        case "bash", "exec_command", "shell", "local_shell_call", "write_stdin", "bashoutput", "killshell":
            return .run
        case "read", "view", "view_image", "notebookread":
            return .read
        case "edit", "multiedit", "write", "notebookedit", "apply_patch", "patch", "create", "str_replace",
             "str_replace_editor", "insert":
            return .edit
        case "grep", "glob", "ls", "list", "find", "codesearch":
            return .search
        case "websearch", "webfetch", "web_search", "web_search_call", "fetch":
            return .web
        case "todowrite", "update_plan", "todo", "enterplanmode", "exitplanmode":
            return .plan
        case "task", "agent", "spawn_agent":
            return .delegate
        default:
            // MCP tools arrive as mcp__server__tool.
            guard tool.hasPrefix("mcp__") else { return .other(tool) }
            return .other(tool.dropFirst(5).components(separatedBy: "__").joined(separator: " · "))
        }
    }

    static func step(tool: String, input: [String: Any]) -> AgentStep {
        AgentStep(verb: verb(tool), target: target(input))
    }

    /// The command, file, pattern or query a call names, whichever comes first.
    static func target(_ input: [String: Any]) -> String {
        for key in ["command", "cmd"] {
            if let text = input[key] as? String, let line = line(text, limit: targetLimit) { return line }
            // Codex passes a command as its argv, often a shell with a script.
            if let argv = input[key] as? [String], !argv.isEmpty {
                let script = argv.count >= 3 && ["-c", "-lc"].contains(argv[1]) ? argv[2...].joined(separator: " ")
                    : argv.joined(separator: " ")
                if let line = line(script, limit: targetLimit) { return line }
            }
        }
        for key in ["file_path", "path", "filePath", "notebook_path"] {
            if let path = input[key] as? String, !path.isEmpty { return (path as NSString).lastPathComponent }
        }
        for key in ["pattern", "query", "url", "description"] {
            if let line = line(input[key] as? String, limit: targetLimit) { return line }
        }
        return ""
    }

    // MARK: Changes

    /// The hunks of a unified diff, past any file headers before the first.
    static func hunks(unified lines: [String]) -> [[AgentDiffLine]] {
        var result: [[AgentDiffLine]] = []
        var hunk: [AgentDiffLine] = []
        var inHunk = false
        for line in lines {
            if line.hasPrefix("@@") {
                if !hunk.isEmpty { result.append(hunk) }
                hunk = []
                inHunk = true
                continue
            }
            // A removed line can itself start with dashes, so headers count only before a hunk.
            if !inHunk && (line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("Index:") || line.hasPrefix("===")) {
                continue
            }
            if let parsed = diffLine(line) { hunk.append(parsed) }
        }
        if !hunk.isEmpty { result.append(hunk) }
        return result
    }

    private static func diffLine(_ line: String) -> AgentDiffLine? {
        switch line.first {
        case "+": return AgentDiffLine(kind: .added, text: String(line.dropFirst()))
        case "-": return AgentDiffLine(kind: .removed, text: String(line.dropFirst()))
        case " ": return AgentDiffLine(kind: .context, text: String(line.dropFirst()))
        case nil: return AgentDiffLine(kind: .context, text: "")
        default: return nil
        }
    }

    /// The files a Codex patch adds or updates, with its hunks; a deleted
    /// file's lines are not in the patch.
    static func patchChanges(_ patch: String) -> [(path: String, hunks: [[AgentDiffLine]])] {
        var result: [(path: String, hunks: [[AgentDiffLine]])] = []
        var path: String?
        var hunks: [[AgentDiffLine]] = []
        var hunk: [AgentDiffLine] = []
        func close() {
            if !hunk.isEmpty { hunks.append(hunk) }
            hunk = []
        }
        func flush() {
            close()
            if let path, !hunks.isEmpty { result.append((path, hunks)) }
            path = nil
            hunks = []
        }
        for line in patch.components(separatedBy: "\n") {
            if let file = ["*** Update File: ", "*** Add File: "].first(where: line.hasPrefix) {
                flush()
                path = String(line.dropFirst(file.count))
            } else if line.hasPrefix("*** ") {
                if line.hasPrefix("*** Delete File: ") || line == "*** End Patch" { flush() }
            } else if line.hasPrefix("@@") {
                close()
            } else if path != nil, let parsed = diffLine(line) {
                hunk.append(parsed)
            }
        }
        flush()
        return result
    }

    /// The lines between two versions of a text, unchanged ones kept as context.
    static func hunk(old: String, new: String) -> [AgentDiffLine] {
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        let difference = after.difference(from: before)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var lines: [AgentDiffLine] = []
        var i = 0, j = 0
        while i < before.count || j < after.count {
            if i < before.count, removed.contains(i) {
                lines.append(AgentDiffLine(kind: .removed, text: before[i]))
                i += 1
            } else if j < after.count, inserted.contains(j) {
                lines.append(AgentDiffLine(kind: .added, text: after[j]))
                j += 1
            } else {
                if i < before.count { lines.append(AgentDiffLine(kind: .context, text: before[i])) }
                i += 1
                j += 1
            }
        }
        return lines
    }

    /// A new file's lines, every one added.
    static func added(_ content: String) -> [AgentDiffLine] {
        content.components(separatedBy: "\n").map { AgentDiffLine(kind: .added, text: $0) }
    }

    // MARK: Logs

    /// A line of Claude Code's transcript. Request blobs repeat earlier
    /// messages and subagents write files of their own, so only the session's
    /// own user and assistant lines count.
    static func applyClaude(_ object: [String: Any], to activity: inout AgentActivity) {
        // Claude notes the prompt again now and then, so a read that starts
        // after it, in a long turn, still knows what was asked.
        if object["type"] as? String == "last-prompt" {
            if let text = prompt(object["lastPrompt"] as? String) { activity.prompt = text }
            return
        }
        guard object["isSidechain"] as? Bool != true, object["isMeta"] as? Bool != true,
              let message = object["message"] as? [String: Any] else { return }
        let items = message["content"] as? [[String: Any]] ?? []
        switch object["type"] as? String {
        case "user":
            if let result = object["toolUseResult"] as? [String: Any] {
                if let path = result["filePath"] as? String {
                    let patch = (result["structuredPatch"] as? [[String: Any]] ?? []).compactMap { $0["lines"] as? [String] }
                    if !patch.isEmpty {
                        activity.changed(path, hunks: patch.flatMap { hunks(unified: $0) })
                    } else if result["type"] as? String == "create", let content = result["content"] as? String {
                        activity.changed(path, hunks: [added(content)])
                    }
                }
                // Claude also notes what a shell command changed in its files.
                for file in (result["bashEditDiff"] as? [String: Any])?["files"] as? [[String: Any]] ?? [] {
                    guard let path = file["filePath"] as? String else { continue }
                    let lines = (file["hunks"] as? [[String: Any]] ?? []).compactMap { $0["lines"] as? [String] }
                    activity.changed(path, hunks: lines.flatMap { hunks(unified: $0) })
                }
            }
            if let text = message["content"] as? String { return userText(text, to: &activity) }
            for item in items {
                switch item["type"] as? String {
                case "tool_result": if let id = item["tool_use_id"] as? String { activity.returned(id) }
                case "text": userText(item["text"] as? String ?? "", to: &activity)
                default: break
                }
            }
        case "assistant":
            if object["isApiErrorMessage"] as? Bool == true { return activity.ended(failed: true) }
            for item in items {
                switch item["type"] as? String {
                case "tool_use":
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { continue }
                    activity.called(id, step(tool: name, input: item["input"] as? [String: Any] ?? [:]))
                case "text": activity.replied(item["text"] as? String)
                default: break
                }
            }
            if message["stop_reason"] as? String == "end_turn" { activity.ended(failed: false) }
        default: break
        }
    }

    private static func userText(_ text: String, to activity: inout AgentActivity) {
        if text.hasPrefix("[Request interrupted") { return activity.ended(failed: false) }
        activity.asked(text)
    }

    /// A line of a Codex rollout.
    static func applyCodex(_ object: [String: Any], to activity: inout AgentActivity) {
        guard let payload = object["payload"] as? [String: Any] else { return }
        let callID = payload["call_id"] as? String ?? ""
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("event_msg", "task_started"):
            activity.began()
        case ("event_msg", "user_message"):
            activity.asked(payload["message"] as? String)
        case ("response_item", "message"):
            let texts = (payload["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            if payload["role"] as? String == "user" {
                texts.forEach { activity.asked($0) }
            } else if payload["role"] as? String == "assistant" {
                activity.replied(texts.last)
            }
        case ("response_item", "function_call"):
            let arguments = (payload["arguments"] as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]
            activity.called(callID, step(tool: payload["name"] as? String ?? "", input: arguments))
        case ("response_item", "custom_tool_call"):
            let name = payload["name"] as? String ?? ""
            guard name == "apply_patch" else { return activity.called(callID, step(tool: name, input: [:])) }
            let changes = patchChanges(payload["input"] as? String ?? "")
            activity.called(callID, AgentStep(verb: .edit, target: changes.first.map { ($0.path as NSString).lastPathComponent } ?? ""))
            for change in changes { activity.changed(change.path, hunks: change.hunks) }
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"):
            activity.returned(callID)
        case ("response_item", "web_search_call"):
            activity.step = AgentStep(verb: .web, target: line((payload["action"] as? [String: Any])?["query"] as? String,
                                                               limit: targetLimit) ?? "")
        case ("event_msg", "task_complete"):
            activity.replied(payload["last_agent_message"] as? String)
            // A turn that broke off still completes, naming its error.
            activity.ended(failed: payload["error"] is [String: Any])
        case ("event_msg", "turn_aborted"):
            activity.ended(failed: false)
        case ("event_msg", "error"):
            activity.ended(failed: true)
        default: break
        }
    }

    /// An event of Copilot CLI's session log. Subagents share it; only the
    /// person's own agent moves the session.
    // ponytail: tool fields follow Copilot's published event schema, not a log
    // seen here; check against a real session-state log when one is at hand.
    static func applyCopilot(_ object: [String: Any], to activity: inout AgentActivity) {
        guard (object["agentId"] as? String ?? "").isEmpty, let data = object["data"] as? [String: Any] else { return }
        switch object["type"] as? String {
        case "user.message":
            activity.asked(data["content"] as? String)
        case "assistant.message":
            for request in data["toolRequests"] as? [[String: Any]] ?? [] {
                guard let id = request["toolCallId"] as? String else { continue }
                let arguments = request["arguments"] as? [String: Any] ?? [:]
                activity.called(id, step(tool: request["name"] as? String ?? "", input: arguments))
                guard let path = arguments["path"] as? String else { continue }
                if let text = arguments["file_text"] as? String {
                    activity.changed(path, hunks: [added(text)])
                } else if let old = arguments["old_str"] as? String, let new = arguments["new_str"] as? String {
                    activity.changed(path, hunks: [hunk(old: old, new: new)])
                }
            }
            if !["thinking", "commentary"].contains(data["phase"] as? String ?? "") {
                activity.replied(data["content"] as? String)
            }
        case "tool.execution_complete":
            if let id = data["toolCallId"] as? String { activity.returned(id) }
        case "assistant.turn_end":
            // Each tool round ends a turn of its own; only one with nothing
            // left to run ends the person's.
            if activity.pending.isEmpty && activity.state == .thinking { activity.ended(failed: false) }
        case "abort", "session.shutdown":
            activity.ended(failed: false)
        case "session.error":
            activity.ended(failed: true)
        default: break
        }
    }

    /// A row of OpenCode's `part` table, with the role of the message it belongs to.
    // ponytail: tool parts follow OpenCode's schema; none were in the local
    // database to check against.
    static func applyOpenCode(part: [String: Any], id: String, role: String?, to activity: inout AgentActivity) {
        switch part["type"] as? String {
        case "text":
            if role == "user" { activity.asked(part["text"] as? String) } else { activity.replied(part["text"] as? String) }
        case "tool":
            let state = part["state"] as? [String: Any] ?? [:]
            let call = part["callID"] as? String ?? id
            switch state["status"] as? String {
            case "pending", "running":
                activity.called(call, step(tool: part["tool"] as? String ?? "", input: state["input"] as? [String: Any] ?? [:]))
            default:
                activity.returned(call)
                let input = state["input"] as? [String: Any] ?? [:]
                if let diff = (state["metadata"] as? [String: Any])?["diff"] as? String,
                   let path = (input["filePath"] ?? input["path"]) as? String {
                    activity.changed(path, hunks: hunks(unified: diff.components(separatedBy: "\n")))
                }
            }
        case "step-finish":
            if part["reason"] as? String == "stop" { activity.ended(failed: false) }
        default: break
        }
    }

    /// Complete lines in `data`, which starts mid-line when `partialStart`;
    /// and how many bytes they took, so a line still being written is read whole next time.
    static func lines(_ data: Data, partialStart: Bool) -> (lines: [Data], consumed: Int) {
        guard let last = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        var pieces = data[data.startIndex..<last].split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if partialStart, !pieces.isEmpty { pieces.removeFirst() }
        return (pieces.map { Data($0) }, last - data.startIndex + 1)
    }

    // MARK: Which log

    /// A Codex rollout's first line; nil for a thread Codex runs for an app.
    static func codexCandidate(head: [String: Any], path: String, modified: Date) -> AgentLogCandidate? {
        guard head["type"] as? String == "session_meta", let meta = head["payload"] as? [String: Any],
              let cwd = meta["cwd"] as? String, let created = AgentLogParser.timestamp(meta["timestamp"]),
              // Older logs name no source; a subagent's is an object.
              meta["source"].map({ ($0 as? String).map(codexSources.contains) ?? false }) ?? true else { return nil }
        return AgentLogCandidate(path: path, kind: .codex, cwd: cwd, created: created, modified: modified)
    }

    /// A Copilot log's first event.
    static func copilotCandidate(head: [String: Any], path: String, modified: Date) -> AgentLogCandidate? {
        guard head["type"] as? String == "session.start", let data = head["data"] as? [String: Any],
              let created = AgentLogParser.timestamp(head["timestamp"]) else { return nil }
        let context = data["context"] as? [String: Any] ?? [:]
        guard let cwd = ["cwd", "gitRoot"].compactMap({ context[$0] as? String }).first(where: { !$0.isEmpty }) else { return nil }
        return AgentLogCandidate(path: path, kind: .copilot, cwd: cwd, created: created, modified: modified)
    }

    /// The value after the first of `flags`, as `flag value` or `flag=value`;
    /// `codex resume <id>` names its session the same way.
    static func argument(after flags: [String], in argv: [String]) -> String? {
        for (index, word) in argv.enumerated() {
            if flags.contains(word), argv.indices.contains(index + 1), !argv[index + 1].hasPrefix("-") {
                return argv[index + 1]
            }
            if let flag = flags.first(where: { word.hasPrefix($0 + "=") }) { return String(word.dropFirst(flag.count + 1)) }
        }
        return nil
    }

    /// A file only that agent's session log can be: a Codex rollout or a
    /// Copilot event log. OpenCode keeps every session in one database.
    static func isLog(_ path: String, kind: AgentProcessKind) -> Bool {
        let name = (path as NSString).lastPathComponent
        switch kind {
        case .codex: return path.contains("/.codex") && name.hasPrefix("rollout-") && name.hasSuffix(".jsonl")
        case .copilot: return path.contains("/session-state/") && name == "events.jsonl"
        default: return false
        }
    }

    /// The log each process writes. One it holds open or names is certain.
    /// Otherwise the one process of an agent in a folder takes the folder's
    /// newest log begun since it started; two in one folder could each own
    /// either, so neither gets one.
    static func links(_ requests: [AgentLogRequest], candidates: [AgentLogCandidate]) -> [Int32: String] {
        var result: [Int32: String] = [:]
        for request in requests { if let exact = request.exact { result[request.pid] = exact } }
        let claimed = Set(result.values)
        let open = requests.filter { $0.exact == nil }
        let groups = Dictionary(grouping: open) { "\($0.kind.rawValue)\u{0}\($0.cwd ?? "")" }
        for group in groups.values where group.count == 1 {
            guard let request = group.first, let cwd = request.cwd else { continue }
            let since = request.started.addingTimeInterval(-AgentSessionsSupport.startTolerance)
            let newest = candidates.filter {
                $0.kind == request.kind && $0.cwd == cwd && $0.created >= since && !claimed.contains($0.path)
            }.max { $0.modified < $1.modified }
            if let newest { result[request.pid] = newest.path }
        }
        return result
    }
}
