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

// Shared harness for the adblock Swift Testing suites (U3–U10). First proven by
// U10's `AdBlockAPITests.swift`; factored out here so every deferred suite reuses
// the same isolated-persistent-store + HTTPS-proxy + page-JS-probe setup verbatim
// instead of re-deriving it (see `docs/adblock-brave-test-mapping.md` §1).
//
// The adblock config is per-data-store and only lives on *persistent* sessions,
// so the store is rooted in a temp directory (`_WKWebsiteDataStoreConfiguration(
// directory:)`), and every request is routed through a local HTTPS proxy so that
// hostnames like `ads.example.com` resolve to the test server. Blocking is
// observed from page JS: a `no-cors`, `no-store` fetch of a subresource resolves
// when allowed and rejects (network cancellation) when the NetworkProcess blocks
// it. Because the engine rebuild after a config change is asynchronous with no
// completion handler, assertions poll until the observed state settles.

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL
import struct Foundation.UUID
import class Foundation.FileManager

// A navigation decider that accepts the test server's self-signed trust so
// HTTPS-proxied loads succeed. Mirrors `JSHandleTests.swift`.
@MainActor
struct AdBlockNavigationDecider: WebPage.NavigationDeciding {
    mutating func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.useCredential, challenge.protectionSpace.serverTrust.map(URLCredential.init(trust:)))
    }
}

// Reusable adblock test primitives, namespaced to avoid colliding with the many
// other Swift suites compiled into the TestWebKitAPI module.
enum AdBlockTest {
    // A network filter rule blocking every request to `ads.example.com`.
    static let blockAdsRule = "||ads.example.com^"

    // The cross-origin subresource used as the default block probe.
    static let adSubresourceURL = "https://ads.example.com/ad.js"

    // A per-test temp directory backing an isolated persistent data store.
    static func uniqueDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdBlockTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // Builds an isolated *persistent* data store rooted in `directory`, routing
    // network traffic through `httpsProxy`. Ephemeral stores no-op every adblock
    // SPI call, so persistence is mandatory.
    @MainActor
    static func makeDataStore(directory: URL, httpsProxy: URL?) -> WKWebsiteDataStore {
        let configuration = _WKWebsiteDataStoreConfiguration(directory: directory)
        configuration.httpsProxy = httpsProxy
        return WKWebsiteDataStore._store(with: configuration)
    }

    // Serves a trivial page plus an ad subresource behind an HTTPS proxy, builds
    // an isolated persistent data store, applies `configure` before the page is
    // created, loads `https://example.com/index`, and runs `body`.
    @MainActor
    static func withPage(
        configure: (WKWebsiteDataStore) -> Void,
        body: (WebPage, WKWebsiteDataStore) async throws -> Void
    ) async throws {
        let directory = uniqueDirectory()

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/index") { "<!DOCTYPE html><html><body>main</body></html>" }
            ProxyRoute("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            configure(store)

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
            try await page.load(URL(string: "https://example.com/index")).wait()

            try await body(page, store)
        }
    }

    // True when a `no-cors`/`no-store` fetch of `url` is rejected by a
    // NetworkProcess block, false when it resolves. `no-store` defeats the cache
    // so each poll re-checks against the live engine.
    @MainActor
    static func subresourceBlocked(_ page: WebPage, url: String) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            try {
                await fetch("\(url)", { mode: "no-cors", cache: "no-store" });
                return false;
            } catch (e) {
                return true;
            }
            """
        )
        return (result as? Bool) ?? false
    }

    // Convenience probe for the default ad subresource host.
    @MainActor
    static func adSubresourceBlocked(_ page: WebPage) async throws -> Bool {
        try await subresourceBlocked(page, url: adSubresourceURL)
    }

    // Polls `condition` every 100ms until it is true or the timeout elapses.
    // Returns whether the condition was observed true. Used because engine
    // rebuilds after a config change are asynchronous with no completion handler.
    @MainActor
    static func pollUntil(
        timeout: Duration = .seconds(15),
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if try await condition() {
                return true
            }
            if clock.now >= deadline {
                return false
            }
            try await _Concurrency.Task.sleep(for: .milliseconds(100))
        }
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
