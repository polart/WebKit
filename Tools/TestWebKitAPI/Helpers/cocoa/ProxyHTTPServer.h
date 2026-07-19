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

#pragma once

#ifdef __cplusplus

#import "Helpers/cocoa/HTTPServer.h"

// Project-owned Swift-interop shims backing `ProxyHTTPServer.swift`. These live
// outside the upstream `HTTPServer.{h,mm}` so those files stay pristine and keep
// merging cleanly with upstream WebKit; every capability our adblock suites need
// beyond a plain string route is bridged here instead. Each shim exists because
// Swift C++ interop cannot express the call directly:
//   - it cannot select the overloaded `HTTPResponse(statusCode, headers, body)`
//     constructor, nor mutate the response's header `HashMap`;
//   - it cannot build the `Function<void(Connection)>` that the connection-handler
//     `HTTPServer` constructor (the only WebSocket-capable one) requires.

// Builds a response carrying a non-default status code (headers start empty; add
// them with proxyAddHTTPResponseHeaderField). Mirrors the upstream `hashMapSet`
// shim style.
TestWebKitAPI::HTTPResponse proxyMakeHTTPResponse(unsigned statusCode, const WTF::String& body);

// Adds a single response header field (e.g. `Location` for a redirect, or
// `Content-Type`) to a response built by proxyMakeHTTPResponse.
void proxyAddHTTPResponseHeaderField(TestWebKitAPI::HTTPResponse&, const WTF::String& name, const WTF::String& value);

// Builds a server that performs a WebSocket handshake on every incoming
// connection, using the connection-handler `HTTPServer` constructor + the
// `Connection::webSocketHandshake` helper (the same pattern as
// `Tests/WebKit/WKWebView/WebSocket.mm`). Because it upgrades *every* connection,
// a WebSocket server is standalone — pages/subresources are served by a separate
// route-based `ProxyHTTPServer`. Listening is deferred (`DeferListening::Yes`) so
// the Swift wrapper starts the listener from `run()` on the main actor, the same
// as the route constructor; see `ProxyHTTPServer.swift` for why a synchronously
// listening constructor cannot be used from a Swift-concurrency @MainActor test.
TestWebKitAPI::HTTPServer proxyMakeWebSocketHTTPServer(TestWebKitAPI::HTTPServer::Protocol);

#endif // __cplusplus
