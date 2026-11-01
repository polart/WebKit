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

// Embedder-API coverage. Drives the adblock SPI on `WKWebsiteDataStore`
// (master toggle, subscription CRUD, custom rules, per-site allowlist, state
// read-back) through a real `WebPage` and asserts end-to-end network blocking.
//
// The shared isolated-persistent-store + HTTPS-proxy + fetch-probe harness lives
// in `AdBlockTestSupport.swift` (`AdBlockTest`); see its header for the setup
// rationale.

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKAdBlock
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL

@MainActor
struct AdBlockAPITests {
    // MARK: Scenario 1 — master toggle

    @Test
    func togglingAdBlockBlocksAndUnblocks() async throws {
        try await AdBlockTest.withPage { store in
            store.adBlock.setEnabled(true)
            store.adBlock.setCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, store in
            var settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)

            store.adBlock.setEnabled(false)
            settled = try await AdBlockTest.pollUntil { !(try await AdBlockTest.adSubresourceBlocked(page)) }
            #expect(settled)

            store.adBlock.setEnabled(true)
            settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    // MARK: Scenario 2 — per-site allowlist

    @Test
    func allowlistExemptsSiteFromBlocking() async throws {
        try await AdBlockTest.withPage { store in
            store.adBlock.setEnabled(true)
            store.adBlock.setCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, store in
            var settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)

            // The allowlist keys on the site being visited (the page is on
            // example.com), so the third-party ad on it is let through…
            store.adBlock.addAllowlistHost("example.com")
            settled = try await AdBlockTest.pollUntil { !(try await AdBlockTest.adSubresourceBlocked(page)) }
            #expect(settled)

            // …and blocked again once the site is removed.
            store.adBlock.removeAllowlistHost("example.com")
            settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    @Test
    func allowlistingRequestHostDoesNotExemptItOnOtherSites() async throws {
        try await AdBlockTest.withPage { store in
            store.adBlock.setEnabled(true)
            store.adBlock.setCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, store in
            let settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)

            // Allowlisting the ad server itself is a per-site setting for
            // ads.example.com pages, not a pass for its requests everywhere. The
            // state read is ordered after the add, so the gate is in place before
            // the probe runs.
            store.adBlock.addAllowlistHost("ads.example.com")
            _ = await store.adBlock.state()
            let stillBlocked = try await AdBlockTest.adSubresourceBlocked(page)
            #expect(stillBlocked)
        }
    }

    // MARK: Scenario 3 — subscription CRUD round-trips and persists

    @Test
    func subscriptionStateRoundTripsAndPersistsAcrossRelaunch() async throws {
        let directory = AdBlockTest.uniqueDirectory()
        let listURL = try #require(URL(string: "https://lists.example.com/list.txt"))

        var server = try HTTPServer(protocol: .httpsProxy) {
            Route("/list.txt") {
                "! Title: Test List\n\(AdBlockTest.blockAdsRule)\n"
            }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store.adBlock.setEnabled(true)
            store.adBlock.setCustomRules("||custom.example.com^")
            store.adBlock.addAllowlistHost("allow.example.com")
            store.adBlock.addSubscription(url: listURL, expectedHash: "")

            // The async state read is ordered after the config sends, so it both
            // proves the round-trip and flushes the on-disk config before we
            // restart the process.
            let state = try #require(await store.adBlock.state())
            expectConfig(
                state,
                subscription: listURL,
                customRules: "||custom.example.com^",
                allowlistHost: "allow.example.com"
            )

            // Restart the NetworkProcess; the config must reload from disk.
            store._terminateNetworkProcess()

            let restoredState = try #require(await store.adBlock.state())
            expectConfig(
                restoredState,
                subscription: listURL,
                customRules: "||custom.example.com^",
                allowlistHost: "allow.example.com"
            )
        }
    }

    // MARK: Scenario 4 — SPI applied even when issued before the NetworkProcess launches

    @Test
    func configurationSetBeforeNetworkProcessLaunchIsApplied() async throws {
        let directory = AdBlockTest.uniqueDirectory()

        var server = try HTTPServer(protocol: .httpsProxy) {
            Route("/index") { "<!DOCTYPE html><html><body>main</body></html>" }
            Route("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)

            // Issue every adblock call before any WebPage exists — i.e. before
            // the store's NetworkProcess is launched. The sends must be queued
            // and applied once it starts, not lost.
            store.adBlock.setEnabled(true)
            store.adBlock.setCustomRules(AdBlockTest.blockAdsRule)

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
            try await page.load(URL(string: "https://example.com/index")).wait()

            let settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)
        }
    }
}

// MARK: - Helpers

extension AdBlockAPITests {
    fileprivate func expectConfig(
        _ state: WKAdBlockState,
        subscription: URL,
        customRules: String,
        allowlistHost: String
    ) {
        #expect(state.isEnabled)
        #expect(state.customRules == customRules)
        #expect(state.allowlist.contains(allowlistHost))
        #expect(state.subscriptions.contains { $0.url == subscription })
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
