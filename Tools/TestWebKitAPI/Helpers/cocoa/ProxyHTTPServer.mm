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

#import "config.h"
#import "Helpers/cocoa/ProxyHTTPServer.h"

#import <wtf/text/WTFString.h>

TestWebKitAPI::HTTPResponse proxyMakeHTTPResponse(unsigned statusCode, const WTF::String& body)
{
    return TestWebKitAPI::HTTPResponse(statusCode, { }, body);
}

void proxyAddHTTPResponseHeaderField(TestWebKitAPI::HTTPResponse& response, const WTF::String& name, const WTF::String& value)
{
    response.headerFields.set(name, value);
}

TestWebKitAPI::HTTPServer proxyMakeWebSocketHTTPServer(TestWebKitAPI::HTTPServer::Protocol protocol)
{
    // Defer listening so the Swift wrapper starts the listener from `run()` on the
    // main actor; see ProxyHTTPServer.swift for why the listening (blocking)
    // constructor cannot be used from a Swift-concurrency @MainActor test.
    return TestWebKitAPI::HTTPServer([](TestWebKitAPI::Connection connection) {
        connection.webSocketHandshake();
    }, protocol, TestWebKitAPI::HTTPServer::DeferListening::Yes);
}
