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

// U9 filter-list-management + persistence coverage. Drives the list lifecycle
// (`AdBlockListStore`) end-to-end and asserts its effect on real network blocking
// and cosmetic hiding. Maps to brave-core's `ad_block_service_browsertest.cc` /
// `ad_block_service_unittest.cc` / `cosmetic_merge_unittest.cc` list cases; see
// `docs/adblock-brave-test-mapping.md` §8.
//
// Delivery seam. Brave's browser tests never fetch a list over the network to
// assert blocking — they inject list content directly (`UpdateAdBlockInstanceWith
// Rules` → `provider->OnComponentReady(path)`) and reserve the network path for a
// couple of subscription-*state* tests. We mirror that: these tests install list
// bodies through the `_setAdBlockListTextForTesting:forURL:` SPI, which stores the
// text and rebuilds exactly as a completed download would, but without a fetch.
// This is required here, not just convenient: NetworkProcess-originated list
// downloads validate TLS, and `AdBlockListDownloader` cancels the server-trust
// challenge for the test proxy's self-signed certificate, so a real subscription
// download can never complete (and its aborted proxy tunnel trips the shared
// `HTTPServer` teardown assertion). Page navigations and the fetch/cosmetic probes
// still go through the HTTPS proxy as usual — only the *list delivery* is injected.
//
// Persistence and warm/cold `.dat` behavior (R7) is exercised by restarting the
// NetworkProcess (`_terminateNetworkProcess`) and re-loading: on relaunch,
// `NetworkSession::ensureAdBlockListStore` calls `AdBlockListStore::load`, which
// either restores the warm `adblock.dat` or re-parses the stored list texts under
// `lists/`. The `.dat` is re-serialized on a work queue *after* the engine swap,
// so the filesystem tests poll for the on-disk artifact rather than assuming it is
// flushed the instant blocking is observed. There is no parse-counter SPI, so
// `warmDatRestoresAcrossRestart` proves the warm path functionally (the `.dat` is
// written, present on relaunch, and blocking is live) rather than by counting
// parses; a strict "did not re-parse" assertion remains a manual/CI gate, like the
// U3 concurrency cases — hence the name asserts restoration, not the absence of a
// re-parse.
//
// Deferred — the pure `AdBlockListDownloader` cases, all blocked on the test
// harness rather than the product, and all tested a different way by Brave:
//
//  - a real subscription download that then blocks (Brave injects rules for
//    blocking assertions instead of downloading);
//  - malformed / 404 list rejection with previous-list retention, i.e. the
//    `looksLikeFilterList` heuristic and non-2xx guard (Brave's `SubscribeTo404
//    List` asserts subscription *bookkeeping*, not blocking, and its test server
//    cert is trusted network-process-wide — ours is not);
//  - the non-HTTPS URL/redirect guard.
//
// These want either a network-process-trusted test cert or a focused C++ unit test
// of `AdBlockListDownloader`; revisit if either lands.

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL
import class Foundation.FileManager

@MainActor
struct AdBlockListManagementTests {
    // MARK: A custom rule takes effect and reverts on rebuild

    @Test
    func customRuleAddRemove() async throws {
        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
        } body: { page, store in
            // No custom rule yet ⇒ the ad loads.
            #expect(try await !AdBlockTest.adSubresourceBlocked(page))

            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)
            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)

            store._setAdBlockCustomRules("")
            let unblocked = try await AdBlockTest.pollUntil { !(try await AdBlockTest.adSubresourceBlocked(page)) }
            #expect(unblocked)
        }
    }

    // MARK: Installing a list blocks per its rules, no restart

    @Test
    func injectedListBlocksPerRules() async throws {
        let listURL = try #require(URL(string: "https://lists.example.com/list.txt"))

        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
        } body: { page, store in
            // Nothing installed yet, so the ad loads.
            #expect(try await !AdBlockTest.adSubresourceBlocked(page))

            // Installing the list registers the subscription and rebuilds the engine
            // in place — no process restart. Poll until the new list's rule applies.
            store._setAdBlockListText(forTesting: "! Title: Test List\n\(AdBlockTest.blockAdsRule)\n", for: listURL)
            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)
        }
    }

    // MARK: Disabling a list un-blocks; re-enabling re-blocks

    @Test
    func toggleListOffThenOn() async throws {
        let listURL = try #require(URL(string: "https://lists.example.com/list.txt"))

        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
        } body: { page, store in
            store._setAdBlockListText(forTesting: "! Title: Test List\n\(AdBlockTest.blockAdsRule)\n", for: listURL)
            var settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)

            // Disabling the (only) list drops its rules from the rebuilt engine.
            store._setAdBlockSubscription(with: listURL, enabled: false)
            settled = try await AdBlockTest.pollUntil { !(try await AdBlockTest.adSubresourceBlocked(page)) }
            #expect(settled)

            // Re-enabling brings them back from the stored text (no re-fetch).
            store._setAdBlockSubscription(with: listURL, enabled: true)
            settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    // MARK: Custom rules persist across a NetworkProcess restart (R7)

    @Test
    func customRulesSurviveRestart() async throws {
        let directory = AdBlockTest.uniqueDirectory()

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/index") { Self.mainHTML }
            ProxyRoute("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(AdBlockTest.blockAdsRule)

            let page = Self.makePage(store: store)
            try await page.load(URL(string: "https://example.com/index")).wait()

            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)

            try await Self.restart(store: store)

            // The relaunched process reloads the config and rebuilds the engine, so
            // a fresh navigation is blocked again with no re-issued SPI.
            let stillBlocked = try await AdBlockTest.pollUntil {
                try await page.load(URL(string: "https://example.com/index")).wait()
                return try await AdBlockTest.adSubresourceBlocked(page)
            }
            #expect(stillBlocked)
        }
    }

    // MARK: A warm `.dat` is written and restored on restart (R7)

    @Test
    func warmDatRestoresAcrossRestart() async throws {
        let directory = AdBlockTest.uniqueDirectory()
        let listURL = try #require(URL(string: "https://lists.example.com/list.txt"))

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/index") { Self.mainHTML }
            ProxyRoute("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockListText(forTesting: "! Title: Test List\n\(AdBlockTest.blockAdsRule)\n", for: listURL)

            let page = Self.makePage(store: store)
            try await page.load(URL(string: "https://example.com/index")).wait()

            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)

            // The engine is re-serialized to `adblock.dat` on a work queue after the
            // swap; poll for the file to appear so the restart reads a warm cache.
            let datWritten = try await AdBlockTest.pollUntil { Self.findFile(named: "adblock.dat", under: directory) != nil }
            #expect(datWritten)

            try await Self.restart(store: store)

            // On relaunch the warm `.dat` restores the compiled engine, so blocking
            // is live again without re-issuing any SPI. (That the reload avoided a
            // re-parse is a manual/CI gate — there is no parse-counter SPI.)
            let stillBlocked = try await AdBlockTest.pollUntil {
                try await page.load(URL(string: "https://example.com/index")).wait()
                return try await AdBlockTest.adSubresourceBlocked(page)
            }
            #expect(stillBlocked)
        }
    }

    // MARK: A deleted `.dat` rebuilds the engine from the stored list text

    @Test
    func deletedDatRebuildsFromListText() async throws {
        let directory = AdBlockTest.uniqueDirectory()
        let listURL = try #require(URL(string: "https://lists.example.com/list.txt"))

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/index") { Self.mainHTML }
            ProxyRoute("/ad.js") { "globalThis.__adLoaded = true;" }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockListText(forTesting: "! Title: Test List\n\(AdBlockTest.blockAdsRule)\n", for: listURL)

            let page = Self.makePage(store: store)
            try await page.load(URL(string: "https://example.com/index")).wait()

            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)

            let datWritten = try await AdBlockTest.pollUntil { Self.findFile(named: "adblock.dat", under: directory) != nil }
            #expect(datWritten)

            try await Self.terminateAfterFlush(store: store)

            // Delete the warm cache but leave the stored list text under `lists/`.
            // The relaunched store's `load()` must fall back to re-parsing that text.
            let datPath = try #require(Self.findFile(named: "adblock.dat", under: directory))
            try FileManager.default.removeItem(atPath: datPath)
            // Sanity: the stored list text is still present to rebuild from.
            #expect(Self.hasFile(under: directory) { $0.hasSuffix(".txt") && $0.contains("/lists/") })

            // Force the new process to (re)create the store and run load() before the
            // navigation, then poll for the rebuilt-from-text engine to block.
            try await Self.relaunchAndWarm(store: store)
            let rebuiltBlocked = try await AdBlockTest.pollUntil {
                try await page.load(URL(string: "https://example.com/index")).wait()
                return try await AdBlockTest.adSubresourceBlocked(page)
            }
            #expect(rebuiltBlocked)
        }
    }

    // MARK: Rapid toggles coalesce and settle to the last-written state

    @Test
    func concurrentTogglesConverge() async throws {
        let listURL = try #require(URL(string: "https://lists.example.com/list.txt"))

        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
        } body: { page, store in
            store._setAdBlockListText(forTesting: "! Title: Test List\n\(AdBlockTest.blockAdsRule)\n", for: listURL)
            let blocked = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(blocked)

            // Fire many toggles back-to-back with no waiting. This asserts the
            // observable last-write-wins outcome — a burst ending "disabled" must
            // converge to un-blocked. (`scheduleRebuild` is expected to coalesce the
            // burst into a single rebuild, but that only-one-rebuild-occurred claim is
            // not observable here — it stays a manual/CI gate, as there is no
            // rebuild-count SPI, mirroring the warm-`.dat` no-re-parse gate above.)
            for enabled in [false, true, false, true, false] {
                store._setAdBlockSubscription(with: listURL, enabled: enabled)
            }
            var settled = try await AdBlockTest.pollUntil { !(try await AdBlockTest.adSubresourceBlocked(page)) }
            #expect(settled)

            // …and a burst ending "enabled" must converge to blocked.
            for enabled in [true, false, true, false, true] {
                store._setAdBlockSubscription(with: listURL, enabled: enabled)
            }
            settled = try await AdBlockTest.pollUntil { try await AdBlockTest.adSubresourceBlocked(page) }
            #expect(settled)
        }
    }

    // MARK: Network rules union across multiple enabled lists

    @Test
    func multiListNetworkRulesMerge() async throws {
        let listAURL = try #require(URL(string: "https://lista.example.com/list.txt"))
        let listBURL = try #require(URL(string: "https://listb.example.com/list.txt"))

        // Two lists each block a *different* host. Blocking both proves the
        // multi-list engine builder (`AdBlockEngine::createFromLists`) unions the
        // rules across every enabled list rather than replacing one with the next.
        try await AdBlockTest.withPage { store in
            store._setAdBlockEnabled(true)
        } body: { page, store in
            store._setAdBlockListText(forTesting: "! Title: List A\n||adsa.example.com^\n", for: listAURL)
            store._setAdBlockListText(forTesting: "! Title: List B\n||adsb.example.com^\n", for: listBURL)

            let bothBlocked = try await AdBlockTest.pollUntil {
                let a = try await AdBlockTest.subresourceBlocked(page, url: "https://adsa.example.com/ad.js")
                let b = try await AdBlockTest.subresourceBlocked(page, url: "https://adsb.example.com/ad.js")
                return a && b
            }
            #expect(bothBlocked)

            // A host neither list targets still loads — the union did not turn into a
            // blanket block.
            #expect(try await !AdBlockTest.subresourceBlocked(page, url: "https://cdn.example.com/ad.js"))
        }
    }

    // MARK: Cosmetic selectors union across multiple enabled lists

    @Test
    func multiListCosmeticRulesMerge() async throws {
        let directory = AdBlockTest.uniqueDirectory()
        let listAURL = try #require(URL(string: "https://lista.example.com/list.txt"))
        let listBURL = try #require(URL(string: "https://listb.example.com/list.txt"))

        // Each list contributes one site-specific hide selector for the same page.
        // Both elements being hidden proves cosmetic `hide_selectors` are merged
        // across enabled lists (the `cosmetic_merge_unittest.cc` analogue), on the
        // same `createFromLists` path as the network union above.
        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/cosmetic", headers: ["Content-Type": "text/html", "Cache-Control": "no-store"]) {
                Self.cosmeticHTML
            }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockListText(forTesting: "! Title: List A\nexample.com##.adA\n", for: listAURL)
            store._setAdBlockListText(forTesting: "! Title: List B\nexample.com##.adB\n", for: listBURL)

            let page = Self.makePage(store: store)

            let bothHidden = try await AdBlockTest.pollUntil {
                try await page.load(URL(string: "https://example.com/cosmetic")).wait()
                let a = try await Self.isHidden(page, selector: "#adA")
                let b = try await Self.isHidden(page, selector: "#adB")
                return a && b
            }
            #expect(bothHidden)

            // The control element is never targeted by either list.
            #expect(try await !Self.isHidden(page, selector: "#keep"))
        }
    }

    // MARK: `$csp` directives union across multiple enabled lists

    @Test
    func multiListCSPRulesMerge() async throws {
        let directory = AdBlockTest.uniqueDirectory()
        let listAURL = try #require(URL(string: "https://lista.example.com/list.txt"))
        let listBURL = try #require(URL(string: "https://listb.example.com/list.txt"))

        // Each list contributes one `$csp` directive for the same host — one
        // `script-src 'none'`, one `style-src 'none'`. Both being enforced on the one
        // response proves `$csp` policies merge across enabled lists (the
        // `csp_merge_unittest.cc` analogue), on the same `createFromLists` path as the
        // network and cosmetic unions above. `no-store` keeps every navigation a fresh
        // load re-evaluated against the current engine.
        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/csp", headers: ["Content-Type": "text/html", "Cache-Control": "no-store"]) {
                Self.cspHTML
            }
        }

        try await server.run { serverConfiguration in
            let store = AdBlockTest.makeDataStore(directory: directory, httpsProxy: serverConfiguration.httpsProxy)
            store._setAdBlockEnabled(true)
            store._setAdBlockListText(forTesting: "! Title: List A\n||csphost.example.com^$csp=script-src 'none'\n", for: listAURL)
            store._setAdBlockListText(forTesting: "! Title: List B\n||csphost.example.com^$csp=style-src 'none'\n", for: listBURL)

            let page = Self.makePage(store: store)

            // Both injected directives enforced ⇒ the inline script never runs and the
            // inline style never applies.
            let bothEnforced = try await AdBlockTest.pollUntil {
                try await page.load(URL(string: "https://csphost.example.com/csp")).wait()
                let scriptBlocked = try await !Self.inlineScriptRan(page)
                let styleBlocked = try await !Self.inlineStyleApplied(page)
                return scriptBlocked && styleBlocked
            }
            #expect(bothEnforced)

            // A host neither list targets keeps both inline probes live — the union did
            // not turn into a blanket policy.
            try await page.load(URL(string: "https://safe.example.com/csp")).wait()
            #expect(try await Self.inlineScriptRan(page))
            #expect(try await Self.inlineStyleApplied(page))
        }
    }
}

// MARK: - Fixtures & helpers

extension AdBlockListManagementTests {
    fileprivate static let mainHTML = "<!DOCTYPE html><html><body>main</body></html>"

    // Two site-specific cosmetic targets (one per list) plus an untargeted control.
    fileprivate static let cosmeticHTML = """
        <!DOCTYPE html><html><head></head><body>
        <div id="adA" class="adA">ad A</div>
        <div id="adB" class="adB">ad B</div>
        <div id="keep" class="content">keep</div>
        </body></html>
        """

    // Two inline CSP probes: an inline `<script>` that sets a global when it runs,
    // and an inline `<style>` that hides `#styleProbe` when it applies. Which probe
    // survives tells us which injected `$csp` directive was enforced.
    fileprivate static let cspHTML = """
        <!DOCTYPE html><html><head>
        <style>#styleProbe { display: none; }</style>
        <script>window.loadedInline = true;</script>
        </head><body>
        <div id="styleProbe">probe</div>
        </body></html>
        """

    @MainActor
    fileprivate static func makePage(store: WKWebsiteDataStore) -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = store
        return WebPage(configuration: configuration, navigationDecider: AdBlockNavigationDecider())
    }

    // Flushes the on-disk config (the async state read is ordered after prior config
    // sends), then terminates the NetworkProcess. Paired with `relaunchAndWarm`; a
    // test that needs to touch the on-disk state between the two (e.g. delete the
    // `.dat`) calls these halves directly instead of `restart`.
    @MainActor
    fileprivate static func terminateAfterFlush(store: WKWebsiteDataStore) async throws {
        _ = await store._getAdBlockState()
        store._terminateNetworkProcess()
    }

    // Reads state to deterministically relaunch the process and drive
    // `ensureAdBlockListStore()->load()` *before* the caller's next navigation — so
    // the reloaded engine is warming by the time the page reloads.
    @MainActor
    fileprivate static func relaunchAndWarm(store: WKWebsiteDataStore) async throws {
        _ = await store._getAdBlockState()
    }

    // Full restart with nothing to do in between: flush + terminate + relaunch.
    @MainActor
    fileprivate static func restart(store: WKWebsiteDataStore) async throws {
        try await terminateAfterFlush(store: store)
        try await relaunchAndWarm(store: store)
    }

    // True when `selector`'s element has computed `display: none` — the merged
    // cosmetic selector was delivered and applied.
    @MainActor
    fileprivate static func isHidden(_ page: WebPage, selector: String) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            const el = document.querySelector("\(selector)");
            return el ? getComputedStyle(el).display === "none" : false;
            """
        )
        return (result as? Bool) ?? false
    }

    // True when the fixture's inline `<script>` executed — i.e. no injected
    // `script-src` directive blocked it.
    @MainActor
    fileprivate static func inlineScriptRan(_ page: WebPage) async throws -> Bool {
        let result = try await page.callJavaScript("return window.loadedInline === true;")
        return (result as? Bool) ?? false
    }

    // True when the fixture's inline `<style>` applied — i.e. `#styleProbe` computed
    // to `display: none`, meaning no injected `style-src` directive blocked it.
    @MainActor
    fileprivate static func inlineStyleApplied(_ page: WebPage) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            const el = document.getElementById("styleProbe");
            return el ? getComputedStyle(el).display === "none" : false;
            """
        )
        return (result as? Bool) ?? false
    }

    // Recursively finds the first file named `name` under `directory`, returning its
    // path. Used because the adblock storage lives at a WebKit-chosen subpath under
    // the data-store directory (`<general storage>/AdBlock/...`), so the tests locate
    // `adblock.dat` by name rather than hard-coding that layout.
    fileprivate static func findFile(named name: String, under directory: URL) -> String? {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
            return nil
        }
        for case let relative as String in enumerator where relative == name || relative.hasSuffix("/" + name) {
            return directory.appendingPathComponent(relative).path
        }
        return nil
    }

    // True when some file under `directory` has a relative path matching `predicate`.
    fileprivate static func hasFile(under directory: URL, matching predicate: (String) -> Bool) -> Bool {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
            return false
        }
        for case let relative as String in enumerator where predicate("/" + relative) {
            return true
        }
        return false
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
