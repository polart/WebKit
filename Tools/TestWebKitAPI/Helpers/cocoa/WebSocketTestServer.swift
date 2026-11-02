// Copyright (C) 2026 Artem Polunin.
// SPDX-License-Identifier: MPL-2.0

// A project-owned WebSocket handshake server for the adblock Swift Testing
// suites. Upstream's `HTTPServer` only serves routes, so this wraps the same
// `HTTPServerCore` listener with a custom connection handler that answers every
// request with a `101 Switching Protocols` handshake and then holds the
// connection open. Because every connection is upgraded, it serves *only*
// WebSockets; pages and subresources come from a separate `HTTPServer`.

import CryptoKit
import Foundation
import Network

/// A test server that performs a WebSocket handshake on every connection.
@MainActor
public struct WebSocketTestServer: ~Copyable {
    private let storage: HTTPServerCore

    /// Create a plain-TCP (`ws://`) WebSocket handshake server.
    ///
    /// - Throws: Any error that happens during creation of the listener.
    public init() throws {
        self.storage = try HTTPServerCore(protocol: .http) { connection in
            Task {
                await Self.performHandshake(on: connection)
            }
        }
    }

    /// Calls the given closure after starting the server, and then closes the server once finished.
    ///
    /// - Parameter body: A closure that will run while this server is active.
    /// - Returns: The return value, if any, of the `body` closure parameter.
    /// - Throws: Any error thrown by `body`, or by starting the listener.
    public mutating func run<Result: ~Copyable>(
        _ body: (Configuration) async throws -> sending Result
    ) async throws -> sending Result {
        try await storage.startListening()
        let result = try await body(Configuration(port: Int(storage.port)))

        await storage.cancel()
        return result
    }

    private static func performHandshake(on connection: NWConnection) async {
        let request = await connection.receiveHTTPRequest()
        guard let key = webSocketKey(in: request) else {
            await connection.terminate()
            return
        }

        let response =
            "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptValue(for: key))\r\n"
            + "\r\n"

        // The client may already have gone away (e.g. a blocked probe); there is nothing to recover.
        try? await connection.send(Data(response.utf8))
    }

    private static func webSocketKey(in request: Data) -> String? {
        let headerBlock = String(decoding: request, as: UTF8.self)
        for line in headerBlock.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }

            if line[..<colon].caseInsensitiveCompare("Sec-WebSocket-Key") == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // https://datatracker.ietf.org/doc/html/rfc6455#section-4.2.2
    private static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }
}

extension WebSocketTestServer {
    /// A collection of information about the properties of a `WebSocketTestServer`.
    public struct Configuration: Sendable {
        /// The port of the server.
        public let port: Int

        // swift-format-ignore: NeverForceUnwrap
        /// The `ws://` URL of the server, addressed by IP.
        public var url: Foundation.URL {
            // Well formed for every port number, so this cannot fail.
            Foundation.URL(string: "ws://127.0.0.1:\(port)/")!
        }
    }
}
