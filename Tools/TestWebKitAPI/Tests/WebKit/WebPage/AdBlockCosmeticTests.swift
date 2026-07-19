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

// U6 cosmetic-CSS computation + delivery coverage. Exercises the element-hiding
// path end-to-end: `AdBlockManager::cosmeticResources` computes the navigation
// URL's `hide_selectors` on the NetworkProcess work queue,
// `AdBlockRequestCheck`/`NetworkLoadChecker` carry the parsed
// `AdBlockCosmeticResources` to `NetworkResourceLoader`, which sends
// `WebResourceLoader::SetAdBlockCosmeticResources` just before the navigation
// response; the WebProcess pushes each selector into the existing
// content-extensions pending-display-none list, so `ExtensionStyleSheets` applies
// `display: none !important` at document commit — before first paint. Maps to
// brave-core's `CosmeticFiltering*` browser tests (`ad_block_service_browsertest.cc`);
// see `docs/adblock-brave-test-mapping.md` §5.
//
// Observation strategy (the `computedDisplay` probe from the mapping doc): the
// fixture carries a `.ad` element (site-specific target), a `div.generic-ad`
// element (generic misc-selector target), and a control element that is never
// matched. `getComputedStyle(el).display === "none"` read via `callJavaScript`
// tells us whether the engine's selector was delivered and applied. A second,
// stronger probe proves *pre-paint* delivery (R3, the WebKit differentiator): an
// inline `<script>` at parse time records the target's computed display into a
// global, so a `"none"` there means the selector was live at commit, not applied
// eventually.
//
// Because the engine rebuild after a config change is asynchronous with no
// completion handler, and cosmetic resources are computed at document-response
// time, assertions poll by *re-navigating* until the selector set settles.
// Fixtures are served `Cache-Control: no-store` so every navigation is a fresh
// network load carrying the current engine's selectors — the query string can't
// be a cache-buster because the test server matches routes on the full request
// target (path + query).
//
// Two mapping-doc cases are intentionally deferred, both blocked on delivery the
// current U6 pipeline does not implement rather than on the test harness:
//
//  - `customStyleApplied` (`##selector:style(...)`): adblock-rust routes a
//    `:style()` rule to `UrlSpecificResources.procedural_actions` (a JSON-encoded
//    `ProceduralOrActionFilter`), never to `hide_selectors`.
//    `AdBlockCosmeticResourceParser` reads only `hide_selectors`, `exceptions`,
//    `injected_script`, and `generichide`, so custom styles are dropped at the
//    NetworkProcess boundary and cannot reach the document. Revisit when the
//    parser + delivery grow a `procedural_actions` field.
//  - `protects1pAndHides1pContent` (Brave `CosmeticFilteringProtect1p` /
//    `Hide1pContent`): Brave's first-party cosmetic-protection semantics ride the
//    same procedural/action channel and a `$1p`-aware cosmetic path that U6 does
//    not model (U6 delivers plain `hide_selectors` only). Revisit with the
//    procedural pipeline.

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL

@MainActor
struct AdBlockCosmeticTests {
    // MARK: A site-specific `##.ad` rule hides the matching element

    @Test
    func hidesMatchingSelector() async throws {
        try await withCosmeticPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("example.com##.ad")
        } body: { page, _ in
            // The engine build is async; poll (re-navigating) until the selector is
            // delivered and the element is hidden.
            let hidden = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await isHidden(page, selector: "#specificAd")
            }
            #expect(hidden)

            // Positive control: an element the rule never targets stays visible, so
            // the hide above is the delivered selector and not a blanket failure to
            // render the fixture.
            #expect(try await !isHidden(page, selector: "#keep"))
        }
    }

    // MARK: The selector is live at document commit, before first paint (R3)

    @Test
    func hiddenBeforeFirstPaint() async throws {
        // The differentiator: cosmetic selectors are delivered *with* the navigation
        // response and applied by `ExtensionStyleSheets` at commit, so an inline
        // `<script>` running during parse already sees `display: none`. Asserting the
        // parse-time global (not just the eventual computed style) proves there is no
        // flash of the un-hidden ad.
        try await withCosmeticPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("example.com##.ad")
        } body: { page, _ in
            let hiddenAtParseTime = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await parseTimeSpecificDisplayWasNone(page)
            }
            #expect(hiddenAtParseTime)
        }
    }

    // MARK: A site-specific selector is scoped to its own domain

    @Test
    func siteSpecificScoping() async throws {
        try await withCosmeticPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("example.com##.ad")
        } body: { page, _ in
            // On the rule's domain the element is hidden…
            let hiddenOnExample = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await isHidden(page, selector: "#specificAd")
            }
            #expect(hiddenOnExample)

            // …but the same fixture on a different registrable domain (served by the
            // same path-matched route) keeps the element visible, because the
            // selector is keyed to `example.com`.
            try await navigate(page, host: "other.com")
            #expect(try await !isHidden(page, selector: "#specificAd"))
        }
    }

    // MARK: A `#@#` exception rule leaves the element visible

    @Test
    func exceptionRuleUnhides() async throws {
        try await withCosmeticPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("example.com##.ad")
        } body: { page, store in
            // First observe the hide so we know the selector is built and delivered…
            let hidden = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await isHidden(page, selector: "#specificAd")
            }
            #expect(hidden)

            // …then add the unhide exception (which removes the selector from the
            // delivered hide set) and observe the element become visible again.
            store._setAdBlockCustomRules(
                """
                example.com##.ad
                example.com#@#.ad
                """
            )
            let unhidden = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await !isHidden(page, selector: "#specificAd")
            }
            #expect(unhidden)
        }
    }

    // MARK: A subframe's selectors derive from the frame URL, not the top URL

    @Test
    func subframeGetsOwnSelectors() async throws {
        // The rule targets only the *frame* host. The frame's own `.ad` element is
        // hidden once the engine settles, while the top document (`example.com`,
        // unmatched) keeps its `.ad` visible — proving cosmetic resources are keyed
        // to each document's own navigation URL.
        try await withCosmeticPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("cosframe.example.com##.ad")
        } body: { page, _ in
            try await navigate(page, host: "example.com")
            // Top document is unmatched, so its `.ad` element is visible.
            #expect(try await !isHidden(page, selector: "#specificAd"))

            // The frame's `.ad` is hidden once the engine settles.
            let frameAdHidden = try await AdBlockTest.pollUntil {
                try await frameAdIsHidden(page, host: "cosframe.example.com")
            }
            #expect(frameAdHidden)
        }
    }

    // MARK: `$generichide` suppresses generic rules but keeps site-specific ones

    @Test
    func generichideDisablesGenericRules() async throws {
        // Two rules apply on `example.com`: a generic misc-selector (`div.generic-ad`,
        // delivered to every site through `url_cosmetic_resources`) and a
        // site-specific `##.ad`. A `$generichide` exception must drop only the generic
        // selector from the delivered set, leaving the specific one enforced.
        try await withCosmeticPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(
                """
                ##div.generic-ad
                example.com##.ad
                """
            )
        } body: { page, store in
            // Both are hidden before the exception is added.
            let bothHidden = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                let generic = try await isHidden(page, selector: "#genericAd")
                let specific = try await isHidden(page, selector: "#specificAd")
                return generic && specific
            }
            #expect(bothHidden)

            // Adding the generichide exception un-hides the generic element while the
            // site-specific selector keeps hiding its target.
            store._setAdBlockCustomRules(
                """
                ##div.generic-ad
                example.com##.ad
                @@||example.com^$generichide
                """
            )
            let genericSuppressed = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                let genericVisible = try await !isHidden(page, selector: "#genericAd")
                let specificStillHidden = try await isHidden(page, selector: "#specificAd")
                return genericVisible && specificStillHidden
            }
            #expect(genericSuppressed)
        }
    }

    // MARK: Master toggle off ⇒ nothing is hidden

    @Test
    func cosmeticDisabledWhenFlagOff() async throws {
        try await withCosmeticPage { store in
            store._setAdBlockEnabled(false)
            store._setAdBlockCustomRules("example.com##.ad")
        } body: { page, _ in
            // With the master toggle off the engine is never consulted, so no
            // selector is delivered. A single check suffices: "disabled" is a
            // deterministic not-hidden, so there is no rebuild to poll for.
            try await navigate(page, host: "example.com")
            #expect(try await !isHidden(page, selector: "#specificAd"))
        }
    }
}

// MARK: - Fixtures & helpers

extension AdBlockCosmeticTests {
    // Response headers shared by every fixture: force HTML parsing (the test server
    // sets no Content-Type) and `no-store` so each navigation is a fresh network
    // load re-evaluated against the current engine.
    fileprivate static let fixtureHeaders = ["Content-Type": "text/html", "Cache-Control": "no-store"]

    // The main fixture carries three probes: a site-specific target (`.ad`), a
    // generic misc-selector target (`div.generic-ad`), and a control that no rule
    // matches. The inline `<script>` records the site-specific target's *parse-time*
    // computed display so `hiddenBeforeFirstPaint` can prove the selector was live
    // at commit rather than applied eventually.
    fileprivate static let fixtureHTML = """
        <!DOCTYPE html><html><head></head><body>
        <div id="specificAd" class="ad">specific</div>
        <div id="genericAd" class="generic-ad">generic</div>
        <div id="keep" class="content">keep</div>
        <script>
        window.parseTimeSpecificDisplay =
            getComputedStyle(document.getElementById("specificAd")).display;
        </script>
        </body></html>
        """

    // The frame variant reports whether its own `.ad` element is hidden up to the
    // parent. Its inline script runs unconditionally (no CSP here) so it can always
    // postMessage the result.
    fileprivate static let frameFixtureHTML = """
        <!DOCTYPE html><html><head></head><body>
        <div id="frameAd" class="ad">frame ad</div>
        <script>
        const hidden = getComputedStyle(document.getElementById("frameAd")).display === "none";
        parent.postMessage({ frameAdHidden: hidden }, "*");
        </script>
        </body></html>
        """

    // Serves the cosmetic fixtures behind an HTTPS proxy, builds an isolated
    // persistent data store, applies `configure`, and runs `body`. All hosts share
    // these routes (the server matches on path only); the *rules* discriminate by
    // host.
    @MainActor
    fileprivate func withCosmeticPage(
        configure: (WKWebsiteDataStore) -> Void,
        body: (WebPage, WKWebsiteDataStore) async throws -> Void
    ) async throws {
        let directory = AdBlockTest.uniqueDirectory()

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/cosmetic", headers: Self.fixtureHeaders) { Self.fixtureHTML }
            ProxyRoute("/cosframe", headers: Self.fixtureHeaders) { Self.frameFixtureHTML }
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

    // Navigates the main frame to `host`/cosmetic. A fresh navigation (with the
    // fixtures' `no-store`) re-fetches the document so its selectors reflect the
    // current engine state.
    @MainActor
    fileprivate func navigate(_ page: WebPage, host: String) async throws {
        try await page.load(URL(string: "https://\(host)/cosmetic")).wait()
    }

    // True when `selector`'s element has computed `display: none` (the engine's hide
    // selector was delivered and applied). Read from the main content world.
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

    // True when the site-specific target was already hidden at *parse time*, read
    // from the global the fixture's inline `<script>` recorded during parsing. A
    // `"none"` here means the selector was applied at commit, before first paint.
    @MainActor
    fileprivate func parseTimeSpecificDisplayWasNone(_ page: WebPage) async throws -> Bool {
        let result = try await page.callJavaScript("return window.parseTimeSpecificDisplay === \"none\";")
        return (result as? Bool) ?? false
    }

    // Appends a fresh subframe pointing at `host`/cosframe and resolves with the
    // frame's reported `.ad`-hidden result. A new frame per call (with `no-store`)
    // re-checks against the live engine.
    @MainActor
    fileprivate func frameAdIsHidden(_ page: WebPage, host: String) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            return await new Promise((resolve) => {
                const handler = (event) => {
                    if (event.data && "frameAdHidden" in event.data) {
                        window.removeEventListener("message", handler);
                        resolve(event.data.frameAdHidden);
                    }
                };
                window.addEventListener("message", handler);
                const frame = document.createElement("iframe");
                frame.src = "https://\(host)/cosframe";
                document.body.appendChild(frame);
            });
            """
        )
        return (result as? Bool) ?? false
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
