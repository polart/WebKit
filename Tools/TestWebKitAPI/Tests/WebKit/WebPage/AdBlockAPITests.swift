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

// U10 embedder-API coverage. Drives the adblock SPI on `WKWebsiteDataStore`
// (master toggle, subscription CRUD, custom rules, per-site allowlist, state
// read-back) through a real `WebPage` and asserts end-to-end network blocking.
//
// The adblock config is per-data-store and only lives on *persistent* sessions,
// so these tests build an isolated persistent store rooted in a temp directory
// (`_WKWebsiteDataStoreConfiguration(directory:)`), and route every request
// through a local HTTPS proxy so hostnames like `ads.example.com` resolve to the
// test server. Blocking is observed from page JS: a `no-cors`, `no-store` fetch
// of a subresource resolves when allowed and rejects (network cancellation) when
// the NetworkProcess blocks it. Because the engine rebuild after a config change
// is asynchronous with no completion handler, assertions poll until the observed
// state settles.

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

@MainActor
private struct AdBlockNavigationDecider: WebPage.NavigationDeciding {
    mutating func decideAuthenticationChallengeDisposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        (.useCredential, challenge.protectionSpace.serverTrust.map(URLCredential.init(trust:)))
    }
}

// A network filter rule blocking every request to `ads.example.com`.
private let blockAdsRule = "||ads.example.com^"

// The cross-origin subresource used as the block probe.
private let adSubresourceURL = "https://ads.example.com/ad.js"

@MainActor
struct AdBlockAPITests {
    // MARK: Scenario 1 — master toggle

    @Test
    func togglingAdBlockBlocksAndUnblocks() async throws {
        try await withAdBlockPage(configure: { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(blockAdsRule)
        }) { page, store in
            var settled = try await pollUntil { try await adSubresourceBlocked(page) }
            #expect(settled)

            store._setAdBlockEnabled(false)
            settled = try await pollUntil { !(try await adSubresourceBlocked(page)) }
            #expect(settled)

            store._setAdBlockEnabled(true)
            settled = try await pollUntil { try await adSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    // MARK: Scenario 2 — per-site allowlist

    @Test
    func allowlistExemptsHostFromBlocking() async throws {
        try await withAdBlockPage(configure: { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(blockAdsRule)
        }) { page, store in
            var settled = try await pollUntil { try await adSubresourceBlocked(page) }
            #expect(settled)

            store._addAdBlockAllowlistHost("ads.example.com")
            settled = try await pollUntil { !(try await adSubresourceBlocked(page)) }
            #expect(settled)

            store._removeAdBlockAllowlistHost("ads.example.com")
            settled = try await pollUntil { try await adSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    // MARK: Scenario 3 — subscription CRUD round-trips and persists

    @Test
    func subscriptionStateRoundTripsAndPersistsAcrossRelaunch() async throws {
        let directory = uniqueDirectory()
        let listURL = try #require(URL(string: "https://lists.example.com/list.txt"))

        var server = HTTPServer(protocol: .httpsProxy) {
            Route("/list.txt") {
                "! Title: Test List\n\(blockAdsRule)\n"
            }
        }

        try await server.run { serverConfiguration in
            let store = makeAdBlockDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||custom.example.com^")
            store._addAdBlockAllowlistHost("allow.example.com")
            store._addAdBlockSubscription(with: listURL, expectedHash: "")

            // The async state read is ordered after the config sends, so it both
            // proves the round-trip and flushes the on-disk config before we
            // restart the process.
            let state = await store._getAdBlockState()
            try expectConfig(
                state,
                subscription: listURL.absoluteString,
                customRules: "||custom.example.com^",
                allowlistHost: "allow.example.com"
            )

            // Restart the NetworkProcess; the config must reload from disk (R7).
            store._terminateNetworkProcess()

            let restoredState = await store._getAdBlockState()
            try expectConfig(
                restoredState,
                subscription: listURL.absoluteString,
                customRules: "||custom.example.com^",
                allowlistHost: "allow.example.com"
            )
        }
    }

    // MARK: Scenario 4 — SPI applied even when issued before the NetworkProcess launches

    @Test
    func configurationSetBeforeNetworkProcessLaunchIsApplied() async throws {
        let directory = uniqueDirectory()

        var server = HTTPServer(protocol: .httpsProxy) {
            Route("/index") { "<!DOCTYPE html><html><body>main</body></html>" }
            Route("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = makeAdBlockDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)

            // Issue every adblock call before any WebPage exists — i.e. before
            // the store's NetworkProcess is launched. The sends must be queued
            // and applied once it starts, not lost.
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(blockAdsRule)

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
            try await page.load(URL(string: "https://example.com/index")).wait()

            let settled = try await pollUntil { try await adSubresourceBlocked(page) }
            #expect(settled)
        }
    }
}

// MARK: - Helpers

extension AdBlockAPITests {
    // Serves a trivial page plus an ad subresource behind an HTTPS proxy, builds
    // an isolated persistent data store, applies `configure` before the page is
    // created, loads the page, and runs `body`.
    fileprivate func withAdBlockPage(
        configure: (WKWebsiteDataStore) -> Void,
        body: (WebPage, WKWebsiteDataStore) async throws -> Void
    ) async throws {
        let directory = uniqueDirectory()

        var server = HTTPServer(protocol: .httpsProxy) {
            Route("/index") { "<!DOCTYPE html><html><body>main</body></html>" }
            Route("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = makeAdBlockDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            configure(store)

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
            try await page.load(URL(string: "https://example.com/index")).wait()

            try await body(page, store)
        }
    }

    // True when a `no-cors`/`no-store` fetch of the ad subresource is rejected
    // by a NetworkProcess block, false when it resolves.
    fileprivate func adSubresourceBlocked(_ page: WebPage) async throws -> Bool {
        let result = try await page.callJavaScript("""
            try {
                await fetch("\(adSubresourceURL)", { mode: "no-cors", cache: "no-store" });
                return false;
            } catch (e) {
                return true;
            }
            """)
        return (result as? Bool) ?? false
    }

    fileprivate func expectConfig(
        _ state: [AnyHashable: Any]?,
        subscription: String,
        customRules: String,
        allowlistHost: String
    ) throws {
        let state = try #require(state)
        #expect((state["enabled"] as? Bool) == true)
        #expect((state["customRules"] as? String) == customRules)

        let allowlist = try #require(state["allowlist"] as? [String])
        #expect(allowlist.contains(allowlistHost))

        let subscriptions = try #require(state["subscriptions"] as? [[String: Any]])
        #expect(subscriptions.contains { ($0["url"] as? String) == subscription })
    }
}

private func uniqueDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("AdBlockAPITests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
private func makeAdBlockDataStore(directory: URL, httpsProxy: URL?) -> WKWebsiteDataStore {
    let configuration = _WKWebsiteDataStoreConfiguration(directory: directory)
    configuration.httpsProxy = httpsProxy
    return WKWebsiteDataStore._store(with: configuration)
}

// Polls `condition` every 100ms until it is true or the timeout elapses.
// Returns whether the condition was observed true. Used because engine rebuilds
// after a config change are asynchronous with no completion handler.
@MainActor
private func pollUntil(
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

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
