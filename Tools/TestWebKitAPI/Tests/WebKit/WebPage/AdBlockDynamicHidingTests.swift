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

// U8 dynamic cosmetic-hiding coverage. Exercises the mutation-observer agent path
// end-to-end: at document start the WebProcess injects an isolated-world JS agent
// (`AdBlockPageAgent`) that scans the DOM and observes mutations for class/id
// tokens, de-duplicates them per document, and reports never-seen tokens to the
// NetworkProcess over the `HiddenClassIdSelectors` IPC. The engine's generic
// (`simple_class_rules` / `simple_id_rules`) hide selectors come back and are
// applied to the *live* document through U6's `ExtensionStyleSheets` display:none
// pipeline. Maps to brave-core's `CosmeticFilteringDynamic*` / `Generichide`
// browser tests; see `docs/adblock-brave-test-mapping.md` §7.
//
// Observation strategy: the `computedDisplay` probe from the mapping doc
// (`getComputedStyle(el).display === "none"`), read via `callJavaScript`. Unlike
// the static U6 selectors — delivered with the navigation response and applied at
// commit, before first paint — dynamic hiding completes via an *asynchronous* IPC
// round-trip that runs after the document commits. So a single check right after
// `load()` races that round-trip; assertions poll instead. Two nested polls are
// used: an outer poll re-navigates (a fresh document re-arms the agent and re-runs
// its scan against the *current* engine, which is rebuilt asynchronously after any
// rule change), and an inner poll waits for that document's post-commit round-trip
// to land. Fixtures are served `Cache-Control: no-store` so every navigation is a
// fresh network load carrying the current engine's arming/generichide state.
//
// A plain generic class/id rule (`##.foo`, `###bar`) is delivered *only* through
// this dynamic path — adblock-rust routes it to `simple_class_rules` /
// `simple_id_rules`, never to the pre-paint `url_cosmetic_resources` set (see
// `AdBlockCosmeticTests`). So every rule here is written as a plain generic
// class/id rule. The harness injects them as custom rules, which is the only rule
// source these tests have; the meaningful coverage axes are therefore the token
// kind (class vs id), late insertion vs initial scan, the `#@#` exception set, and
// the `$generichide` arming gate — not "default list vs user rule".
//
// `tokensQueriedOnce` observes the WebProcess-side per-document de-duplication
// through a process-global engine-query counter exposed for tests
// (`-_getAdBlockEngineQueryCountWithCompletionHandler:`). It measures the counter
// *delta* across a controlled burst of same-class insertions inside one settled
// document, so it depends on the same per-test engine isolation every other
// adblock suite already relies on (each isolated persistent store drives its own
// process-global engine); no cross-test traffic falls inside the measured window.

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL

@MainActor
struct AdBlockDynamicHidingTests {
    // MARK: An element inserted after load with a matching class is hidden

    @Test
    func lateInsertedElementGetsHidden() async throws {
        // `##.probe` proves the dynamic pipeline is live for this document;
        // `##.late-ad` is the class we insert *after* the initial scan, so hiding it
        // exercises the MutationObserver `childList` path rather than the load-time
        // scan.
        try await withDynamicPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(
                """
                ##.probe
                ##.late-ad
                """
            )
        } body: { page, _ in
            #expect(try await dynamicPipelineLive(page, host: "example.com"))

            // Insert the ad element after load; it is hidden once the mutation is
            // observed, reported, queried, and the selector applied.
            try await insert(page, className: "late-ad", id: "lateAd")
            let hidden = try await AdBlockTest.pollUntil {
                try await isHidden(page, selector: "#lateAd")
            }
            #expect(hidden)

            // Positive control: a late element with no matching rule stays visible,
            // so the hide above is the delivered selector, not a blanket collapse.
            try await insert(page, className: "content", id: "keep")
            #expect(try await staysVisible(page, selector: "#keep"))
        }
    }

    // MARK: A generic id rule hides a dynamically inserted element (id-token path)

    @Test
    func dynamicCustomRuleHides() async throws {
        // The sibling of `lateInsertedElementGetsHidden` for the *id* branch of the
        // dynamic query: `###customAd` lands in `simple_id_rules`, so hiding a late
        // element by id proves the id token is reported and matched, not just class
        // tokens.
        try await withDynamicPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(
                """
                ##.probe
                ###customAd
                """
            )
        } body: { page, _ in
            #expect(try await dynamicPipelineLive(page, host: "example.com"))

            try await insert(page, className: "banner", id: "customAd")
            let hidden = try await AdBlockTest.pollUntil {
                try await isHidden(page, selector: "#customAd")
            }
            #expect(hidden)
        }
    }

    // MARK: 100 same-class insertions cross the IPC as a single engine query

    @Test
    func tokensQueriedOnce() async throws {
        // The agent de-duplicates tokens per document (its `seenClasses` set), so a
        // class already asked about never crosses the IPC again. Inserting 100
        // elements that all share one *new* class must therefore produce exactly one
        // additional engine query. Measured as the counter delta inside one settled
        // document: nothing else queries the engine in that window (no navigation, no
        // subresource loads), so the delta isolates the burst's single query.
        try await withDynamicPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(
                """
                ##.probe
                ##.burst
                """
            )
        } body: { page, store in
            #expect(try await dynamicPipelineLive(page, host: "example.com"))

            // The document is settled (the probe round-trip completed) — snapshot the
            // engine-query counter, then insert the burst.
            let before = await store._getAdBlockEngineQueryCount()
            try await insertBurst(page, className: "burst", firstID: "burst0", count: 100)

            // Wait for the burst's selector to land so its query has definitely been
            // counted before reading the counter back.
            let hidden = try await AdBlockTest.pollUntil {
                try await isHidden(page, selector: "#burst0")
            }
            #expect(hidden)

            let after = await store._getAdBlockEngineQueryCount()
            #expect(after - before == 1)
        }
    }

    // MARK: A `#@#`-excepted class is not hidden even when inserted dynamically

    @Test
    func exceptedClassNotHidden() async throws {
        // `example.com#@#.excepted` adds `.excepted` to the cosmetic exception set the
        // agent is armed with, so the excepted token is filtered out of the dynamic
        // query result. Inserting a `.hideme` control alongside the excepted element
        // pins the round-trip: once the control is hidden, the reply for that batch has
        // been applied, so the excepted element's (visible) fate is decided.
        try await withDynamicPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(
                """
                ##.probe
                ##.hideme
                ##.excepted
                example.com#@#.excepted
                """
            )
        } body: { page, _ in
            #expect(try await dynamicPipelineLive(page, host: "example.com"))

            // Insert the excepted element and a matching control in the same batch.
            try await insert(page, className: "excepted", id: "exc")
            try await insert(page, className: "hideme", id: "ctl")

            // The control is hidden once the batch's reply is applied…
            let controlHidden = try await AdBlockTest.pollUntil {
                try await isHidden(page, selector: "#ctl")
            }
            #expect(controlHidden)

            // …and at that point the excepted element has been decided visible.
            #expect(try await !isHidden(page, selector: "#exc"))
        }
    }

    // MARK: `$generichide` disables the dynamic agent for the page

    @Test
    func generichidePageDisablesDynamic() async throws {
        // Dynamic hiding is armed only when the page is not `generichide`
        // (`dynamicHidingEnabled = !generichide`). With `@@||example.com^$generichide`
        // the agent is never armed on `example.com`, so neither the static probe nor a
        // dynamically inserted generic element is hidden — while the same rules hide on
        // a non-generichide host, proving the engine and rules are otherwise live.
        try await withDynamicPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(
                """
                ##.probe
                ##.generic-ad
                @@||example.com^$generichide
                """
            )
        } body: { page, _ in
            // Control host with no generichide exception: the dynamic path works.
            #expect(try await dynamicPipelineLive(page, host: "other.com"))

            // On the generichide host the agent is disarmed: the static probe stays
            // visible and a dynamically inserted generic element is never hidden.
            try await navigate(page, host: "example.com")
            try await insert(page, className: "generic-ad", id: "genAd")
            #expect(try await staysVisible(page, selector: "#genAd"))
            #expect(try await staysVisible(page, selector: "#probe"))
        }
    }
}

// MARK: - Fixtures & helpers

extension AdBlockDynamicHidingTests {
    // Force HTML parsing (the test server sets no Content-Type) and `no-store` so
    // every navigation is a fresh network load re-evaluated against the current
    // engine's arming/generichide state.
    fileprivate static let fixtureHeaders = ["Content-Type": "text/html", "Cache-Control": "no-store"]

    // A static `.probe` element (hidden via the dynamic path once the pipeline is
    // live) plus an empty container to append late elements into.
    fileprivate static let fixtureHTML = """
        <!DOCTYPE html><html><head></head><body>
        <div id="probe" class="probe">probe</div>
        <div id="container"></div>
        </body></html>
        """

    // Serves the dynamic fixture behind an HTTPS proxy, builds an isolated
    // persistent data store, applies `configure`, and runs `body`. All hosts share
    // the route (the server matches on path only); the *rules* discriminate by host.
    @MainActor
    fileprivate func withDynamicPage(
        configure: (WKWebsiteDataStore) -> Void,
        body: (WebPage, WKWebsiteDataStore) async throws -> Void
    ) async throws {
        let directory = AdBlockTest.uniqueDirectory()

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/dynamic", headers: Self.fixtureHeaders) { Self.fixtureHTML }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            configure(store)

            var configuration = WebPage.Configuration()
            configuration.websiteDataStore = store
            let page = WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())

            try await body(page, store)
        }
    }

    // Navigates the main frame to `host`/dynamic. A fresh navigation (with the
    // fixture's `no-store`) re-arms the agent and re-runs its scan against the
    // current engine.
    @MainActor
    fileprivate func navigate(_ page: WebPage, host: String) async throws {
        try await page.load(URL(string: "https://\(host)/dynamic")).wait()
    }

    // True once the dynamic pipeline is live for `host`: re-navigate until an engine
    // that hides `.probe` is built (outer poll, engine-build latency), waiting each
    // document up to a second for its post-commit dynamic round-trip to land (inner
    // poll). On success the page is left on that settled document, ready for
    // insertions.
    @MainActor
    fileprivate func dynamicPipelineLive(_ page: WebPage, host: String) async throws -> Bool {
        try await AdBlockTest.pollUntil {
            try await navigate(page, host: host)
            return try await AdBlockTest.pollUntil(timeout: .seconds(1)) {
                try await isHidden(page, selector: "#probe")
            }
        }
    }

    // Appends a single `<div>` with `className` and `id` to the document body. The
    // agent's MutationObserver (`childList`, `subtree`) picks up the insertion.
    @MainActor
    fileprivate func insert(_ page: WebPage, className: String, id: String) async throws {
        _ = try await page.callJavaScript(
            """
            const el = document.createElement("div");
            el.className = "\(className)";
            el.id = "\(id)";
            el.textContent = "x";
            document.body.appendChild(el);
            return true;
            """
        )
    }

    // Appends `count` `<div>`s that all share `className`; the first also carries
    // `firstID` so its hide can be polled. All share one class, so the agent's
    // per-document de-duplication reports that class at most once.
    @MainActor
    fileprivate func insertBurst(_ page: WebPage, className: String, firstID: String, count: Int) async throws {
        _ = try await page.callJavaScript(
            """
            for (let i = 0; i < \(count); i++) {
                const el = document.createElement("div");
                el.className = "\(className)";
                if (i === 0) el.id = "\(firstID)";
                document.body.appendChild(el);
            }
            return true;
            """
        )
    }

    // True when `selector`'s element has computed `display: none` (the engine's hide
    // selector was delivered and applied). False when visible or absent.
    @MainActor
    fileprivate func isHidden(_ page: WebPage, selector: String) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            const el = document.querySelector("\(selector)");
            return el ? getComputedStyle(el).display === "none" : false;
            """
        )
        return (result as? Bool) ?? false
    }

    // True when `selector`'s element stays visible for the whole window — used to
    // assert a *negative* (never hidden), which a single check cannot prove because
    // the dynamic hide could still land a moment later. Fails fast if it ever hides.
    @MainActor
    fileprivate func staysVisible(_ page: WebPage, selector: String, for duration: Duration = .seconds(2)) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if try await isHidden(page, selector: selector) {
                return false
            }
            try await _Concurrency.Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
