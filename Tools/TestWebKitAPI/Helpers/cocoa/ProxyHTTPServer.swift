// Copyright (C) 2026 the WebKit adblock integration authors.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions
// are met:
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in the
//    documentation and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
// THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
// PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
// BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
// THE POSSIBILITY OF SUCH DAMAGE.

// A project-owned test HTTP server for the adblock Swift Testing suites. It is a
// deliberate parallel of the upstream `HTTPServer.swift` wrapper, wrapping the
// same battle-tested C++ `TestWebKitAPI::HTTPServer` (HTTPS-proxy TLS-MITM and
// all) so that hostnames like `ads.example.com` resolve to the test server. The
// upstream wrapper only bridges plain string routes; every extra capability our
// suites need — custom status codes, response headers, redirects, and WebSocket
// handshakes — lives here instead of being patched into WebKit's own files, so
// upstream merges stay clean. The interop that Swift cannot express directly is
// bridged by the shims in `ProxyHTTPServer.h`. Some duplication of the upstream
// wrapper is accepted as the cost of that isolation.

#if ENABLE_CXX_INTEROP

import Foundation
private import TestWebKitAPILibrary.Helpers.cocoa.HTTPServer
private import TestWebKitAPILibrary.Helpers.cocoa.ProxyHTTPServer
import struct Swift.String

/// A description of an HTTP server route with a path and a response.
///
/// Mirrors the upstream `Route`, adding a status code, response headers, and
/// redirect convenience. Named `ProxyRoute` to avoid colliding with the upstream
/// `Route` in the same test module.
public struct ProxyRoute: Sendable {
    fileprivate struct HeaderField: Sendable {
        let name: String
        let value: String
    }

    fileprivate struct Storage: Sendable {
        let pathComponents: [String]
        let response: String
        let statusCode: Int
        let headerFields: [HeaderField]
    }

    fileprivate let children: [Storage]

    fileprivate init(children: [Storage]) {
        self.children = children
    }

    fileprivate init(path: String, response: String, statusCode: Int, headerFields: [HeaderField]) {
        self.children = [
            Storage(pathComponents: [path], response: response, statusCode: statusCode, headerFields: headerFields)
        ]
    }

    /// Creates a route from a group of child routes.
    ///
    /// - Parameters:
    ///   - path: The path of this route. If this value is non-empty, it must start with `/`.
    ///   - route: The children of this route; each child has its full path prepended by the path of this route.
    public init(_ path: String, @ProxyRouteBuilder _ route: () -> ProxyRoute) {
        self.children = route().children
            .map {
                Storage(
                    pathComponents: [path] + $0.pathComponents,
                    response: $0.response,
                    statusCode: $0.statusCode,
                    headerFields: $0.headerFields
                )
            }
    }

    /// Creates a route whose response data is a String.
    ///
    /// - Parameters:
    ///   - path: The path of this route. If this value is non-empty, it must start with `/`.
    ///   - statusCode: The HTTP status code to respond with. Defaults to 200.
    ///   - headers: Additional response header fields, e.g. `Location` for a redirect or `Content-Type`.
    ///   - response: The response body to be used.
    public init(_ path: String, statusCode: Int = 200, headers: [String: String] = [:], _ response: () -> String) {
        self.init(
            path: path,
            response: response(),
            statusCode: statusCode,
            headerFields: headers.map { HeaderField(name: $0.key, value: $0.value) }
        )
    }

    /// Creates a route that responds with an HTTP redirect to `location`.
    ///
    /// - Parameters:
    ///   - path: The path of this route. If this value is non-empty, it must start with `/`.
    ///   - location: The absolute URL to redirect to, sent as the `Location` header.
    ///   - statusCode: The 3xx status code to use. Defaults to 302 (Found).
    /// - Returns: A ``ProxyRoute`` that responds with the redirect.
    public static func redirect(_ path: String, to location: String, statusCode: Int = 302) -> ProxyRoute {
        ProxyRoute(path, statusCode: statusCode, headers: ["Location": location]) { "" }
    }
}

/// A result builder used to create a ``ProxyRoute``.
@resultBuilder
public struct ProxyRouteBuilder {
    /// Create a ``ProxyRoute`` from a group of routes.
    public static func buildBlock(_ components: ProxyRoute...) -> ProxyRoute {
        .init(children: components.flatMap(\.children))
    }
}

/// A test HTTP server with predefined responses, plus a WebSocket handshake mode.
@MainActor
public struct ProxyHTTPServer: ~Copyable {
    /// A protocol describing how an HTTP connection handles requests.
    public enum `Protocol`: Sendable {
        /// The HTTP protocol.
        case http

        /// The HTTPS protocol.
        case https

        /// The HTTPS protocol, using a legacy version of TLS.
        case httpsWithLegacyTLS

        /// The HTTP2 protocol.
        case http2

        /// The HTTPS proxy protocol.
        case httpsProxy

        /// The HTTPS proxy protocol with authentication.
        case httpsProxyWithAuthentication
    }

    private var storage: TestWebKitAPI.RefCountedHTTPServer

    // Both constructors defer listening so `run` starts the listener and observes
    // the ready state on the main actor. (This flag is retained so a future
    // eagerly-listening server can opt out of `run` starting it a second time.)
    private let listensLazily: Bool

    /// Create a server from a group of routes.
    ///
    /// - Parameters:
    ///   - protocol: The HTTP protocol to use for this server.
    ///   - route: A group of routes that correspond to a mapping of request paths to responses.
    public init(protocol: `Protocol`, @ProxyRouteBuilder _ route: () -> ProxyRoute) {
        var entries = unsafe TestWebKitAPI.__CxxHTTPServer.ResponseMap()

        let routes = route().children
        for child in routes {
            let path = child.pathComponents.joined()
            // statusCode defaults to 200 and headerFields is usually empty, so this
            // matches plain string-body routes while letting a route opt into a
            // custom status code and header fields.
            var response = unsafe proxyMakeHTTPResponse(UInt32(child.statusCode), WTF.String(child.response))
            for header in child.headerFields {
                unsafe proxyAddHTTPResponseHeaderField(&response, WTF.String(header.name), WTF.String(header.value))
            }
            unsafe hashMapSet(&entries, consuming: .init(path), consuming: response)
        }

        unsafe self.storage = .init(consuming: .init(consuming: entries, .init(`protocol`), consuming: .init(), nil, .init(), .Yes))
        self.listensLazily = true
    }

    /// Create a server that performs a WebSocket handshake on every connection.
    ///
    /// Because every connection is upgraded, such a server serves *only*
    /// WebSockets — pages and subresources come from a separate route-based
    /// ``ProxyHTTPServer``.
    ///
    /// Like the route constructor, this defers listening: the underlying
    /// WebSocket-capable `HTTPServer` is built without starting its listener, and
    /// ``run(_:)`` starts it via `startListening`. This matters under Swift
    /// concurrency because the listener reports readiness on the main dispatch
    /// queue and WebKit's `CompletionHandler` asserts thread affinity — so the
    /// readiness callback must be *created* on the main actor (in ``run(_:)``) and
    /// delivered there while the actor is suspended at its `await`. A listening
    /// constructor would either block the main actor (deadlock) or, if built off
    /// the main actor, trip that thread assertion.
    ///
    /// - Parameter protocol: The protocol to use for this server.
    public init(webSocketProtocol protocol: `Protocol`) {
        unsafe self.storage = .init(consuming: proxyMakeWebSocketHTTPServer(.init(`protocol`)))
        self.listensLazily = true
    }

    /// Calls the given closure after starting the server, and then closes the server once finished.
    ///
    /// - Parameter body: A closure that will run while this server is active.
    /// - Returns: The return value, if any, of the `body` closure parameter.
    /// - Throws: Any error thrown by `body`.
    public mutating func run<Result, E>(
        _ body: (Configuration) async throws(E) -> sending Result
    ) async throws(E) -> sending Result where E: Error, Result: ~Copyable {
        if listensLazily {
            await withCheckedContinuation { continuation in
                unsafe self.storage.pointee.startListening(
                    consuming: .init(
                        {
                            continuation.resume()
                        },
                        WTF.ThreadLikeAssertion(WTF.CurrentThreadLike())
                    )
                )
            }
        }

        let port = unsafe Int(storage.pointee.port())
        let configuration = Configuration(port: port)

        let result = try await body(configuration)

        await withCheckedContinuation { continuation in
            unsafe self.storage.pointee.cancel(
                consuming: .init(
                    {
                        continuation.resume()
                    },
                    WTF.ThreadLikeAssertion(WTF.CurrentThreadLike())
                )
            )
        }

        return result
    }
}

extension TestWebKitAPI.__CxxHTTPServer.`Protocol` {
    fileprivate init(_ protocol: ProxyHTTPServer.`Protocol`) {
        self =
            switch `protocol` {
            case .http: .Http
            case .https: .Https
            case .httpsWithLegacyTLS: .HttpsWithLegacyTLS
            case .http2: .Http2
            case .httpsProxy: .HttpsProxy
            case .httpsProxyWithAuthentication: .HttpsProxyWithAuthentication
            }
    }
}

extension ProxyHTTPServer {
    /// A collection of information about the properties of a `ProxyHTTPServer`.
    public struct Configuration: Sendable {
        /// The port of the server.
        public let port: Int

        /// The URL representing the HTTPS proxy for the server.
        public var httpsProxy: Foundation.URL? {
            Foundation.URL(string: "https://127.0.0.1:\(port)/")
        }

        /// The URL representing the `wss://` endpoint for a WebSocket server.
        public var webSocketURL: Foundation.URL? {
            Foundation.URL(string: "wss://127.0.0.1:\(port)/")
        }
    }
}

#endif // ENABLE_CXX_INTEROP
