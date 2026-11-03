// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Talks to chat providers. Nothing it sends or receives is logged.
enum NotchChatClient {
    /// No cookies, no cache and no stored credentials go along.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": "Vorssaint/\(AppInfo.version)"]
        return URLSession(configuration: configuration)
    }()

    /// A failed reply's body is read this far, enough for any error message.
    private static let errorBodyLimit = 16_384

    /// The reply as it arrives, piece by piece. Cancelling the consuming task
    /// closes the connection.
    static func stream(provider: ChatProvider, model: String, messages: [ChatMessage],
                       system: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try NotchChatSupport.request(provider: provider, model: model, messages: messages,
                                                               system: system, key: ChatKeychain.key(for: provider))
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status / 100 != 2 {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count >= errorBodyLimit { break }
                        }
                        throw NotchChatSupport.failure(status: status, body: body) ?? NotchChatFailure.badResponse
                    }
                    for try await line in bytes.lines {
                        switch NotchChatSupport.event(line: line, wire: provider.wire) {
                        case .text(let text): continuation.yield(text)
                        case .done: continuation.finish(); return
                        case .error(let message): throw NotchChatFailure.server(status, message.isEmpty ? nil : message)
                        case nil: continue
                        }
                    }
                    // Some servers close the stream without a closing event.
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The server's chat models.
    static func models(provider: ChatProvider) async throws -> [String] {
        let request = try NotchChatSupport.modelsRequest(provider: provider, key: ChatKeychain.key(for: provider))
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let failure = NotchChatSupport.failure(status: status, body: data) { throw failure }
            return NotchChatSupport.models(from: data)
        } catch {
            throw mapped(error)
        }
    }

    private static func mapped(_ error: Error) -> Error {
        switch error {
        case is NotchChatFailure, is CancellationError: return error
        case let error as URLError where error.code == .cancelled: return CancellationError()
        case is URLError: return NotchChatFailure.offline
        default: return Task.isCancelled ? CancellationError() : NotchChatFailure.badResponse
        }
    }
}
