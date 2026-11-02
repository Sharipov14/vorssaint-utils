// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Darwin

/// Claude's permission requests and questions, asked in the notch, and the
/// turns Claude and Codex finish, told there. It listens only while its hook
/// is in Claude's settings and the AI page can show, and nothing starts from
/// `init`. Nothing is allowed or denied without a click: a request left alone,
/// or one Claude stops waiting for, goes back to the terminal.
final class AgentApprovalService: ObservableObject {
    static let shared = AgentApprovalService()

    enum Failure: Error { case unreadable, changed, writeFailed }

    /// `settings.json` as it is and as it would be with the hook added or removed.
    struct Change {
        let original: Data?
        let data: Data
        let command: String
    }

    @Published private(set) var pending: [AgentApproval] = []
    /// The hook is in `~/.claude/settings.json`, as last read.
    @Published private(set) var installed = false

    private let queue = DispatchQueue(label: "com.vorssaint.agent-approvals", qos: .userInitiated)
    private let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    // Main thread.
    private var listener: DispatchSourceRead?
    private var settingsRead = false
    /// Each waiting request's connection; cancelling the source closes it.
    private var connections: [UUID: (source: DispatchSourceRead, fd: Int32)] = [:]
    /// On `queue`: each waiting request's transcript, to see it answered elsewhere.
    private var followers: [UUID: TranscriptFollower] = [:]
    /// What the first card changed about the island, undone after the last.
    private var opened = false
    private var pinned = false

    private init() {}

    /// Nil where the path is too long for a socket.
    var socketPath: String? {
        guard let path = PrivateFileStore.containerURL?.appending(path: AgentApprovalSupport.socketName).path,
              path.utf8.count <= AgentApprovalSupport.socketPathLimit else { return nil }
        return path
    }

    // MARK: Lifecycle

    func syncWithPreferences() {
        guard NotchAgentSupport.isEnabled() else { return stop() }
        if !settingsRead { refresh() }
        if installed { start() } else { stop() }
    }

    /// Reads Claude's settings again, as when the settings page opens.
    func refresh() {
        settingsRead = true
        guard let socketPath else { installed = false; return }
        installed = (try? readSettings()).map { AgentApprovalSupport.isInstalled(in: $0.object, socket: socketPath) } ?? false
    }

    /// Every waiting request goes back to the terminal.
    func stop() {
        for id in Array(connections.keys) { answer(id, allow: nil) }
        // A finished turn needs no hook, and goes on its own.
        for approval in pending where !approval.isFinish { remove(approval.id) }
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        if let socketPath { unlink(socketPath) }
    }

    // MARK: Claude's settings

    /// Throws when the file cannot be read as settings, which are then left alone.
    func change(installing: Bool) throws -> Change {
        guard let socketPath else { throw Failure.writeFailed }
        let (object, original) = try readSettings()
        let command = AgentApprovalSupport.command(socket: socketPath)
        guard let changed = AgentApprovalSupport.settings(object, installing: installing ? command : nil,
                                                          socket: socketPath) else { throw Failure.unreadable }
        return Change(original: original, data: Data(AgentApprovalSupport.json(changed).utf8), command: command)
    }

    /// Writes the change over the exact file it was made from, after a dated
    /// copy beside it; a file that changed since is left alone.
    func apply(_ change: Change) throws {
        let manager = FileManager.default
        let current = manager.fileExists(atPath: settingsURL.path) ? try? Data(contentsOf: settingsURL) : nil
        guard current == change.original else { throw Failure.changed }
        // A symlinked settings file stays a link to the file that changes.
        let target = settingsURL.resolvingSymlinksInPath()
        var mode = 0o600
        if change.original != nil {
            guard (try? manager.copyItem(at: target, to: backupURL())) != nil else { throw Failure.writeFailed }
            mode = ((try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? Int).map { $0 & 0o777 } ?? mode
        } else {
            try? manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // Written beside it and renamed over it, so a failure leaves the original whole.
        let temp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).vorssaint-\(getpid())")
        try? manager.removeItem(at: temp)
        guard manager.createFile(atPath: temp.path, contents: change.data, attributes: [.posixPermissions: 0o600]),
              (try? manager.setAttributes([.posixPermissions: mode], ofItemAtPath: temp.path)) != nil,
              rename(temp.path, target.path) == 0 else {
            try? manager.removeItem(at: temp)
            throw Failure.writeFailed
        }
        refresh()
        syncWithPreferences()
    }

    /// The object and the bytes it came from; no file is empty settings, an
    /// unreadable one is not.
    private func readSettings() throws -> (object: [String: Any], original: Data?) {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return ([:], nil) }
        guard let bytes = try? Data(contentsOf: settingsURL) else { throw Failure.unreadable }
        if bytes.allSatisfy({ [0x20, 0x09, 0x0A, 0x0D].contains($0) }) { return ([:], bytes) }
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { throw Failure.unreadable }
        return (object, bytes)
    }

    /// `settings.json.bak-20261102-174400`, never one that exists.
    private func backupURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = settingsURL.lastPathComponent + ".bak-" + formatter.string(from: Date())
        let folder = settingsURL.deletingLastPathComponent()
        var candidate = folder.appending(path: base)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appending(path: "\(base)-\(number)")
            number += 1
        }
        return candidate
    }

    // MARK: Listening

    private func start() {
        guard listener == nil, let socketPath, let container = PrivateFileStore.containerURL,
              PrivateFileStore.createDirectory(at: container) else { return }
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: socketPath.utf8) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // The folder is the owner's alone; the socket is too.
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, 8) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            unlink(socketPath)
            return
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept(on: fd) }
        source.setCancelHandler { close(fd) }
        listener = source
        source.resume()
    }

    /// On `queue`. Only this account's processes are heard.
    private func accept(on listener: Int32) {
        while true {
            let fd = Darwin.accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var uid = uid_t(), gid = gid_t(), on: Int32 = 1
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            var peer = pid_t(0), peerSize = socklen_t(MemoryLayout<pid_t>.size)
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid(),
                  fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                close(fd)
                continue
            }
            // curl, whose app is the session's.
            if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerSize) != 0 { peer = 0 }
            receive(fd, peer: peer)
        }
    }

    /// On `queue`: the request, read whole within the receive timeout.
    private func receive(_ fd: Int32, peer: pid_t) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            switch AgentApprovalSupport.request(data) {
            case .incomplete:
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { close(fd); return }
                data.append(contentsOf: buffer[..<count])
            case .invalid:
                close(fd)
                return
            case .body(let body):
                let now = Date()
                guard let approval = AgentApprovalSupport.approval(from: body, id: UUID(), now: now) else {
                    Self.send(nil, to: fd)
                    close(fd)
                    return
                }
                let trail = AgentApprovalSupport.trail(from: body, received: now)
                DispatchQueue.main.async { self.hold(approval, fd: fd, peer: peer, trail: trail) }
                return
            }
        }
    }

    // MARK: Asking

    private func hold(_ approval: AgentApproval, fd: Int32, peer: pid_t, trail: AgentApprovalTrail?) {
        var approval = approval
        if peer > 0, let app = ResponsibleProcess.regularAppOwner(of: peer) {
            // "Visual Studio Code", where the running app calls itself "Code".
            approval.host = app.bundleURL.map { FileManager.default.displayName(atPath: $0.path) } ?? app.localizedName
            approval.hostPID = app.processIdentifier
            // Read while curl still runs: it shares Claude's terminal.
            approval.tty = AgentSessionsService.terminal(near: peer)
        }
        // An island that cannot show, locked or away, leaves it to the terminal.
        guard listener != nil, pending.count < AgentApprovalSupport.pendingLimit, present(approval) else {
            Self.send(nil, to: fd)
            close(fd)
            return
        }
        // Readable again only once curl is gone: Claude stopped waiting.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.answer(approval.id, allow: nil) }
        source.setCancelHandler { close(fd) }
        connections[approval.id] = (source, fd)
        source.resume()
        if let trail {
            let id = approval.id
            queue.async { [weak self] in
                guard let self else { return }
                followers[id] = TranscriptFollower(trail, queue: queue) {
                    DispatchQueue.main.async { [weak self] in self?.settle(id) }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + approval.wait) { [weak self] in
            self?.answer(approval.id, allow: nil)
        }
    }

    /// Puts a card in the open island, pinned for it; false when the island
    /// cannot show it, locked or away.
    private func present(_ card: AgentApproval) -> Bool {
        let island = NotchService.shared
        let wasExpanded = island.expanded, wasPinned = island.pinned
        // In first, so the island opens at the size the card takes.
        pending.append(card)
        // Pinned, so the card waits for the click; unfocused, so typing goes on.
        island.open(.agents, pinned: true, takeFocus: false)
        guard island.expanded, island.selected == .agents else {
            pending.removeAll { $0.id == card.id }
            return false
        }
        if pending.count == 1 {
            opened = !wasExpanded
            pinned = !wasPinned
            // The sessions are watched while cards show, for their names and apps.
            AgentSessionsService.shared.pageDidAppear()
        }
        return true
    }

    // MARK: Finished turns

    /// A turn Claude or Codex finished, told on a card a moment, its last reply
    /// and all. `notice` tells it instead where the session's own window is in
    /// front, where the reply cannot be read, or where the island cannot show
    /// it: away, or open on something else, which it does not take over.
    func finish(_ provider: AgentProvider, log: String, project: String, notice: @escaping () -> Void) {
        // A first look at the running sessions says whose app that is.
        AgentSessionsService.shared.pageDidAppear()
        finish(provider, log: log, project: project, notice: notice, looks: 0)
    }

    private func finish(_ provider: AgentProvider, log: String, project: String, notice: @escaping () -> Void, looks: Int) {
        // ponytail: polls for the scan, a few tenths of a second; a callback
        // from the sessions service if it ever takes longer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let sessions = AgentSessionsService.shared
            if !sessions.loaded, looks < 6 {
                self?.finish(provider, log: log, project: project, notice: notice, looks: looks + 1)
                return
            }
            defer { sessions.pageDidDisappear() }
            let session = sessions.sessions.first { $0.log == log }
            let island = NotchService.shared
            guard let self, !(session.map(AgentSessionsService.inFront) ?? false), !island.expanded || island.showsAgentRequests,
                  let reply = Self.tail(of: log).flatMap({ AgentApprovalSupport.reply(inTail: $0, provider: provider) }) else {
                return notice()
            }
            var card = AgentApproval(id: UUID(), cwd: session?.cwd ?? (project.isEmpty ? nil : project), tool: "",
                                     detail: nil, received: Date(),
                                     session: ((log as NSString).lastPathComponent as NSString).deletingPathExtension,
                                     rules: nil)
            card.agent = provider
            card.reply = reply
            card.host = session?.host?.name
            card.hostPID = session?.host?.pid
            // One at a time, in place: the newest says the most.
            if let index = pending.firstIndex(where: \.isFinish) {
                pending[index] = card
            } else if pending.count >= AgentApprovalSupport.pendingLimit || !present(card) {
                return notice()
            }
            expire(card.id)
        }
    }

    /// Goes once its time is up and the pointer is not on the island.
    private func expire(_ id: UUID, after delay: TimeInterval = AgentApprovalSupport.finishWait) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, pending.contains(where: { $0.id == id }) else { return }
            if NotchService.shared.pointerOverIsland { return expire(id, after: 1) }
            remove(id)
        }
    }

    /// OK on a finished turn's card.
    func dismiss(_ id: UUID) { remove(id) }

    /// Goes to the finished session, where its app's name says.
    func showSession(of id: UUID) {
        guard let card = pending.first(where: { $0.id == id }) else { return }
        // Found first: the last card gone, the sessions are no longer watched.
        let sessions = AgentSessionsService.shared
        let session = sessions.sessions.first { $0.log?.hasSuffix("/\(card.session ?? "").jsonl") == true }
        remove(id)
        NotchService.shared.collapse()
        if let session {
            sessions.show(session)
        } else if let pid = card.hostPID, let app = NSRunningApplication(processIdentifier: pid) {
            AgentSessionsService.show(app, tty: nil, cwd: card.cwd)
        }
    }

    /// The last stretch of a log, where its last reply is.
    private static func tail(of path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let read = UInt64(AgentApprovalSupport.replyRead)
        try? handle.seek(toOffset: end > read ? end - read : 0)
        return try? handle.readToEnd()
    }

    /// Claude's questions answered, a pick list each, the card saying so a moment.
    func answer(_ id: UUID, picks: [[String]]) {
        guard connections[id] != nil, let index = pending.firstIndex(where: { $0.id == id }),
              let asked = pending[index].asked else { return }
        reply(id, allow: true, asked: asked, answers: AgentApprovalSupport.answers(to: pending[index].questions, picks: picks))
        pending[index].outcome = .allowed
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentApprovalSupport.answerNote) { [weak self] in
            self?.remove(id)
        }
    }

    /// Allow or deny from a click, the card saying so a moment; nil hands
    /// the question to the terminal. Always keeps the rules Claude offered.
    func answer(_ id: UUID, allow: Bool?, always: Bool = false) {
        guard connections[id] != nil, let index = pending.firstIndex(where: { $0.id == id }) else { return }
        reply(id, allow: allow, rules: always ? pending[index].rules : nil)
        guard let allow else { return remove(id) }
        pending[index].outcome = allow ? .allowed : .denied
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentApprovalSupport.answerNote) { [weak self] in
            self?.remove(id)
        }
    }

    /// Hands the question to the terminal and goes there: the session's tab,
    /// or its editor window.
    func handBack(_ id: UUID) {
        guard let approval = pending.first(where: { $0.id == id }) else { return }
        answer(id, allow: nil)
        NotchService.shared.collapse()
        guard let pid = approval.hostPID, let app = NSRunningApplication(processIdentifier: pid) else { return }
        AgentSessionsService.show(app, tty: approval.tty, cwd: approval.cwd)
    }

    /// Answered in the terminal or the editor: the card says where, then goes.
    private func settle(_ id: UUID) {
        guard connections[id] != nil, let index = pending.firstIndex(where: { $0.id == id }) else { return }
        reply(id, allow: nil)
        pending[index].outcome = .elsewhere
        DispatchQueue.main.asyncAfter(deadline: .now() + AgentApprovalSupport.answeredNote) { [weak self] in
            self?.remove(id)
        }
    }

    /// Ends the request's connection and stops following its transcript.
    private func reply(_ id: UUID, allow: Bool?, rules: NSArray? = nil, asked: NSArray? = nil, answers: [String: Any]? = nil) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        Self.send(allow, rules: rules, asked: asked, answers: answers, to: connection.fd)
        connection.source.cancel()
        queue.async { [weak self] in self?.followers.removeValue(forKey: id)?.source.cancel() }
    }

    /// The card goes; with the last one, the island goes back as it was.
    private func remove(_ id: UUID) {
        guard pending.contains(where: { $0.id == id }) else { return }
        pending.removeAll { $0.id == id }
        let island = NotchService.shared
        if pending.isEmpty {
            if opened { island.collapse() } else if pinned { island.pinned = false }
            opened = false
            pinned = false
            AgentSessionsService.shared.pageDidDisappear()
        }
        // The rest are as tall as they are, or the page behind them comes back.
        if island.expanded { island.refreshPresentation() }
    }

    private static func send(_ allow: Bool?, rules: NSArray? = nil, asked: NSArray? = nil, answers: [String: Any]? = nil,
                             to fd: Int32) {
        let response = AgentApprovalSupport.response(allow: allow, rules: rules, asked: asked, answers: answers)
        _ = response.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// A request's transcript, read on its queue as Claude writes to it, from the
/// stretch just before the request on. Lines stay in memory only.
private final class TranscriptFollower {
    let source: DispatchSourceFileSystemObject
    private var trail: AgentApprovalTrail
    private let handle: FileHandle
    private var offset: UInt64
    /// The next read starts inside a line.
    private var partial: Bool

    /// Nil when the transcript cannot be opened. `settled` runs on `queue`, once.
    init?(_ trail: AgentApprovalTrail, queue: DispatchQueue, settled: @escaping () -> Void) {
        let fd = open(trail.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        guard let handle = FileHandle(forReadingAtPath: trail.path), let end = try? handle.seekToEnd() else {
            close(fd)
            return nil
        }
        let read = UInt64(AgentApprovalSupport.trailRead)
        self.trail = trail
        self.handle = handle
        offset = end > read ? end - read : 0
        partial = offset > 0
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A transcript moved away or gone gets no more lines.
            if !source.data.isDisjoint(with: [.rename, .delete, .revoke]) { return source.cancel() }
            if readAdded() {
                source.cancel()
                settled()
            }
        }
        source.setCancelHandler {
            close(fd)
            try? handle.close()
        }
        source.resume()
        if readAdded() {
            source.cancel()
            settled()
        }
    }

    /// True once a line read gives the call its result.
    private func readAdded() -> Bool {
        let limit = AgentApprovalSupport.trailRead
        while !source.isCancelled {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: limit), !data.isEmpty else { return false }
            let (lines, consumed) = AgentActivitySupport.lines(data, partialStart: partial)
            guard consumed > 0 else {
                // A line longer than a read is skipped; a shorter one is still being written.
                guard data.count == limit else { return false }
                offset += UInt64(limit)
                partial = true
                continue
            }
            offset += UInt64(consumed)
            partial = false
            for line in lines {
                guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                if trail.settles(with: object) { return true }
            }
        }
        return false
    }
}
