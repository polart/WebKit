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

// U4 network-request-blocking coverage. Exercises the NetworkProcess blocking
// hook (`NetworkLoadChecker` / `AdBlockRequestCheck`) end-to-end through the U10
// embedder API, using the shared harness in `AdBlockTestSupport.swift`. Maps to
// brave-core's `ad_block_service_browsertest.cc` network cases; see
// `docs/adblock-brave-test-mapping.md` §3.
//
// Scope note: `redirectHopReEvaluated` is covered here via `ProxyRoute.redirect`
// and `blocksWebSocketOpen` via `ProxyHTTPServer`'s WebSocket handshake server
// (`init(webSocketProtocol:)`) — both extend the project-owned `ProxyHTTPServer`
// wrapper (status codes, response headers, redirects, WebSocket handshakes)
// without patching WebKit's own files. Still deferred: `blocksServiceWorkerRequest`
// needs a service-worker registration fixture; and `blocksAboutBlankSubresource`
// is a client-side fixture that first needs a correctness check on how
// `NetworkLoadChecker` sees the top origin for an `about:blank` frame. Both remain
// required by the plan.

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL

@MainActor
struct AdBlockNetworkBlockingTests {
    // MARK: Happy path — a matching subresource is blocked

    @Test
    func blocksMatchingSubresource() async throws {
        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, _ in
            let settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    // MARK: A request matching no rule is never blocked

    @Test
    func allowsNonMatchingSubresource() async throws {
        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, _ in
            // Prove the engine is live (the matching host is blocked)…
            let live = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(live)

            // …then a non-matching host on the same served path still loads.
            // `cdn.example.com` reuses the `/ad.js` route, so a rejection here
            // would be a real block, not a missing fixture.
            let blocked = try await AdBlockTest.subresourceBlocked(page, url: "https://cdn.example.com/ad.js")
            #expect(!blocked)
        }
    }

    // MARK: An `@@` exception rule un-blocks a would-be-blocked request

    @Test
    func exceptionRuleAllows() async throws {
        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, store in
            // First observe the block so we know the engine is built and blocking,
            // then add the exception and observe it un-block after the rebuild.
            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)

            store._setAdBlockCustomRules("\(AdBlockTest.blockAdsRule)\n@@||ads.example.com^\n")
            let unblocked = try await AdBlockTest.pollUntil { !(try await AdBlockTest.adSubresourceBlocked(page)) }
            #expect(unblocked)
        }
    }

    // MARK: A `$third-party` rule blocks cross-site and allows same-site

    @Test
    func thirdPartyRuleDiscriminates() async throws {
        let directory = AdBlockTest.uniqueDirectory()

        // `tracker.com` and `example.com` are distinct registrable domains, so a
        // load of `tracker.com` is third-party from `example.com` and first-party
        // from `tracker.com`. ProxyHTTPServer matches by path only, so both top
        // documents share the `/index` route and both fetch the `/t.js` route.
        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/index") { "<!DOCTYPE html><html><body>main</body></html>" }
            ProxyRoute("/t.js") { "globalThis.__t = true;" }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||tracker.com^$third-party")

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())

            // Cross-site: example.com → tracker.com is third-party → blocked.
            try await page.load(URL(string: "https://example.com/index")).wait()
            let crossSiteBlocked = try await AdBlockTest.pollUntil {
                try await AdBlockTest.subresourceBlocked(page, url: "https://tracker.com/t.js")
            }
            #expect(crossSiteBlocked)

            // Same-site: tracker.com → tracker.com is first-party → allowed.
            try await page.load(URL(string: "https://tracker.com/index")).wait()
            let sameSiteAllowed = try await AdBlockTest.pollUntil {
                !(try await AdBlockTest.subresourceBlocked(page, url: "https://tracker.com/t.js"))
            }
            #expect(sameSiteAllowed)
        }
    }

    // MARK: Blocking applies to requests originating inside a subframe

    @Test
    func blocksInSubframe() async throws {
        let directory = AdBlockTest.uniqueDirectory()

        // The frame document runs the same block probe and reports its result up
        // to the top document via postMessage.
        let frameHTML = """
            <!DOCTYPE html><html><body><script>
            (async () => {
                let blocked;
                try {
                    await fetch("\(AdBlockTest.adSubresourceURL)", { mode: "no-cors", cache: "no-store" });
                    blocked = false;
                } catch (e) {
                    blocked = true;
                }
                parent.postMessage({ frameBlocked: blocked }, "*");
            })();
            </script></body></html>
            """

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/index") { "<!DOCTYPE html><html><body>main</body></html>" }
            ProxyRoute("/frame") { frameHTML }
            ProxyRoute("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
            try await page.load(URL(string: "https://example.com/index")).wait()

            let settled = try await AdBlockTest.pollUntil { try await frameSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    // MARK: A redirect hop is re-evaluated against the engine (R1)

    @Test
    func redirectHopReEvaluated() async throws {
        let directory = AdBlockTest.uniqueDirectory()

        // Both redirect endpoints live on an un-blocked host and 302 to the same
        // `/ad.js` route; only the *target host* differs. ProxyHTTPServer matches
        // by path, so the block decision can only come from re-checking the redirect
        // hop's destination, not the initial (allowed) request URL.
        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/index") { "<!DOCTYPE html><html><body>main</body></html>" }
            ProxyRoute("/ad.js") { "globalThis.__adLoaded = true;" }
            ProxyRoute.redirect("/to-blocked", to: "https://ads.example.com/ad.js")
            ProxyRoute.redirect("/to-allowed", to: "https://cdn.example.com/ad.js")
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
            try await page.load(URL(string: "https://example.com/index")).wait()

            // Allowed initial request → 302 → blocked target: cancelled at the hop.
            let redirectToBlocked = try await AdBlockTest.pollUntil {
                try await AdBlockTest.subresourceBlocked(page, url: "https://safe.example.com/to-blocked")
            }
            #expect(redirectToBlocked)

            // Same redirect shape to an allowed target still loads, proving it is
            // the hop's destination — not the redirect itself — that is blocked.
            let redirectToAllowed = try await AdBlockTest.pollUntil {
                !(try await AdBlockTest.subresourceBlocked(page, url: "https://safe.example.com/to-allowed"))
            }
            #expect(redirectToAllowed)
        }
    }

    // MARK: Regression pin — the subresource path actually blocks and toggles

    // Pins the 2026-07-17 "move the request once" fix: a moved-from
    // `ResourceRequest` had silently disabled *all* subresource/subframe blocking
    // (the engine saw an empty URL and matched nothing) while leaving the
    // WebSocket path intact. Assert the subresource path genuinely blocks, then
    // that clearing the rule restores the load — a straight no-op regression
    // would fail the first `#expect`.
    @Test
    func subresourceBlockThenAllowRegression() async throws {
        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, store in
            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)

            store._setAdBlockCustomRules("")
            let unblocked = try await AdBlockTest.pollUntil { !(try await AdBlockTest.adSubresourceBlocked(page)) }
            #expect(unblocked)
        }
    }

    // MARK: Master toggle off ⇒ nothing is blocked

    @Test
    func flagOffLoadsEverything() async throws {
        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(false)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)
        } body: { page, _ in
            // With the master toggle off the engine is never consulted, so a
            // matching request loads. A single check suffices: "disabled" is a
            // deterministic not-blocked, so there is no rebuild to poll for.
            let blocked = try await AdBlockTest.adSubresourceBlocked(page)
            #expect(!blocked)
        }
    }

    // MARK: A WebSocket to a matching host fails to open (R1)

    // Pins the `NetworkSocketChannel` hook: a matching WebSocket handshake is
    // refused before it opens, a non-matching one connects. The probe talks to a
    // standalone WSS handshake server *directly* (no proxy), and the rule targets
    // that server's own host, so the very endpoint that is blocked here is the one
    // that must open once the rule is cleared — a positive control that rules out
    // a generic (non-adblock) connection failure reading as a false "blocked".
    @Test
    func blocksWebSocketOpen() async throws {
        let directory = AdBlockTest.uniqueDirectory()

        var server = ProxyHTTPServer(webSocketProtocol: .http)

        try await server.run { serverConfiguration in
            let webSocketURL = "ws://127.0.0.1:\(serverConfiguration.port)/"

            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: nil)
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||127.0.0.1^")

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
            try await page.load(html: "<!DOCTYPE html><html><body></body></html>").wait()

            // Matching host: the handshake is refused before the socket opens.
            let blocked = try await AdBlockTest.pollUntil { try await webSocketBlocked(page, url: webSocketURL) }
            #expect(blocked)

            // Clearing the rule lets the very same endpoint open — a positive
            // control that rules out a generic (non-adblock) connection failure
            // reading as a false "blocked".
            store._setAdBlockCustomRules("")
            let opens = try await AdBlockTest.pollUntil { !(try await webSocketBlocked(page, url: webSocketURL)) }
            #expect(opens)
        }
    }
}

// MARK: - Helpers

extension AdBlockNetworkBlockingTests {
    // Appends a fresh subframe that runs the block probe and resolves with the
    // frame's `frameBlocked` result. Each call adds a new frame (with `no-store`
    // defeating the cache) so polling re-checks against the live engine.
    @MainActor
    fileprivate func frameSubresourceBlocked(_ page: WebPage) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            return await new Promise((resolve) => {
                const handler = (event) => {
                    if (event.data && "frameBlocked" in event.data) {
                        window.removeEventListener("message", handler);
                        resolve(event.data.frameBlocked);
                    }
                };
                window.addEventListener("message", handler);
                const frame = document.createElement("iframe");
                frame.src = "https://example.com/frame";
                document.body.appendChild(frame);
            });
            """
        )
        return (result as? Bool) ?? false
    }

    // True when a fresh WebSocket to `url` never opens (the NetworkProcess refuses
    // the handshake), false when it opens. A fresh socket per call re-checks the
    // live engine; the timeout keeps a stalled connection from hanging the poll.
    @MainActor
    fileprivate func webSocketBlocked(_ page: WebPage, url: String) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            return await new Promise((resolve) => {
                let done = false;
                const finish = (blocked) => { if (!done) { done = true; resolve(blocked); } };
                let ws;
                try {
                    ws = new WebSocket("\(url)");
                } catch (e) {
                    finish(true);
                    return;
                }
                ws.onopen = () => { finish(false); ws.close(); };
                ws.onerror = () => finish(true);
                ws.onclose = () => finish(true);
                setTimeout(() => finish(true), 3000);
            });
            """
        )
        // Fail open: a non-Bool result means the probe itself failed to run
        // (not that the socket was blocked), so default to "not blocked" and let
        // the assertion surface a broken probe rather than silently confirm it.
        return (result as? Bool) ?? false
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
