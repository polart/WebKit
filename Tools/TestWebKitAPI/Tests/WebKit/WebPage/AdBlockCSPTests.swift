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

// U5 CSP-header-injection coverage. Exercises the `$csp` rule path end-to-end:
// `AdBlockRequestCheck::checkNetworkRequest` fetches the engine's CSP directives
// during the (async) request check, `NetworkLoadChecker` carries them to the
// synchronous `NetworkResourceLoader::didReceiveResponse`, and
// `AdBlock::mergeCSPDirectives` folds them into the document response's
// `Content-Security-Policy` header. Maps to brave-core's `CspRule*` browser tests
// (`ad_block_service_browsertest.cc`); see `docs/adblock-brave-test-mapping.md` §4.
//
// Observation strategy (the `scriptLoaded` probe from the mapping doc, plus a
// parallel style probe): the fixture sets `window.loadedInline = true` from an
// inline `<script>` and hides `#styleProbe` from an inline `<style>`. An injected
// `script-src 'none'` policy stops the inline script (flag stays unset); an
// injected/own `style-src 'none'` policy stops the inline stylesheet (the probe
// keeps its default `block` display). Reading those two page globals via
// `callJavaScript` (main content world, not subject to the page CSP) tells us
// exactly which directives were enforced. Using two *inline* directives means no
// test needs an external resource or image byte-stream to observe enforcement.
//
// Because the engine rebuild after a config change is asynchronous with no
// completion handler, and CSP is applied at document-response time (not on a
// re-fetch of a subresource), assertions poll by *re-navigating* until the
// injected policy settles. Fixtures are served `Cache-Control: no-store` so every
// navigation is a fresh network load carrying the current engine verdict — the
// query string can't be used as a cache-buster because the test server matches
// routes on the full request target (path + query).

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL

@MainActor
struct AdBlockCSPTests {
    // MARK: `$csp=script-src 'none'` stops the document's inline script

    @Test
    func cspRuleBlocksInlineScript() async throws {
        try await withCSPPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||csphost.example.com^$csp=script-src 'none'")
        } body: { page, _ in
            // The engine build is async; poll (re-navigating) until the injected
            // policy takes effect and the inline script stops running.
            let scriptBlocked = try await AdBlockTest.pollUntil {
                try await !navigateAndReadInlineScriptRan(page, host: "csphost.example.com")
            }
            #expect(scriptBlocked)

            // Positive control: a host with no matching rule still runs its inline
            // script, proving the block above is the injected policy and not a
            // generic parse/load failure of the fixture.
            try await navigate(page, host: "safe.example.com")
            #expect(try await inlineScriptRan(page))
        }
    }

    // MARK: An injected policy merges with a response's own CSP header

    @Test
    func cspMergesWithExistingHeader() async throws {
        // `owncsp.example.com/owncsp` already sends `Content-Security-Policy:
        // style-src 'none'`; the rule injects `script-src 'none'`. If the injection
        // *replaced* the header, the inline style would apply again — so proving the
        // style stays blocked *and* the script becomes blocked proves the two
        // policies were merged, not overwritten.
        try await withCSPPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||owncsp.example.com^$csp=script-src 'none'")
        } body: { page, _ in
            let merged = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "owncsp.example.com", path: "/owncsp")
                let scriptBlocked = try await !inlineScriptRan(page)
                let styleBlocked = try await !inlineStyleApplied(page)
                return scriptBlocked && styleBlocked
            }
            #expect(merged)
        }
    }

    // MARK: Two `$csp` rules union their directives

    @Test
    func multipleCspRulesUnion() async throws {
        // Two independent `$csp` rules for the same host contribute a `script-src`
        // and a `style-src` directive; both must be enforced on the one response.
        try await withCSPPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules(
                """
                ||csphost.example.com^$csp=script-src 'none'
                ||csphost.example.com^$csp=style-src 'none'
                """
            )
        } body: { page, _ in
            let bothBlocked = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "csphost.example.com")
                let scriptBlocked = try await !inlineScriptRan(page)
                let styleBlocked = try await !inlineStyleApplied(page)
                return scriptBlocked && styleBlocked
            }
            #expect(bothBlocked)

            // Positive control: neither directive applies to an unmatched host, so
            // both the inline script and inline style are live there.
            try await navigate(page, host: "safe.example.com")
            #expect(try await inlineScriptRan(page))
            #expect(try await inlineStyleApplied(page))
        }
    }

    // MARK: A subframe's CSP derives from the frame URL, not the top URL

    @Test
    func subframeGetsOwnDirectives() async throws {
        // The rule matches only the *frame* host with `style-src 'none'`. The frame's
        // own inline script still runs (script-src is unrestricted) and reports
        // whether its inline stylesheet applied. The top document (`example.com`,
        // unmatched) keeps its inline style, proving the directives are keyed to the
        // frame's own URL rather than the top document's.
        try await withCSPPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||cspframe.example.com^$csp=style-src 'none'")
        } body: { page, _ in
            try await navigate(page, host: "example.com")
            // Top document is unmatched, so its own inline style applies.
            #expect(try await inlineStyleApplied(page))

            // The frame is style-blocked once the engine settles.
            let frameStyleBlocked = try await AdBlockTest.pollUntil {
                try await !frameStyleApplied(page, host: "cspframe.example.com")
            }
            #expect(frameStyleBlocked)
        }
    }

    // MARK: No matching `$csp` rule leaves the response headers unchanged

    @Test
    func noMatchingCspLeavesHeadersUnchanged() async throws {
        // `owncsp.example.com/owncsp` sends its own `style-src 'none'`. With no
        // matching rule, nothing is injected: the inline script runs (no injected
        // `script-src`) and the response's own `style-src` is still honored (inline
        // style blocked). Together those show the engine touched no headers.
        try await withCSPPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||ads.example.com^")
        } body: { page, _ in
            try await navigate(page, host: "owncsp.example.com", path: "/owncsp")
            // Nothing injected ⇒ the inline script is untouched and runs…
            #expect(try await inlineScriptRan(page))
            // …while the response's own CSP is preserved verbatim.
            #expect(try await !inlineStyleApplied(page))
        }
    }

    // MARK: An allowlisted host receives no injection

    @Test
    func cspNotInjectedWhenAllowlisted() async throws {
        try await withCSPPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockCustomRules("||csphost.example.com^$csp=script-src 'none'")
        } body: { page, store in
            // First prove the injection is live for this host…
            let scriptBlocked = try await AdBlockTest.pollUntil {
                try await !navigateAndReadInlineScriptRan(page, host: "csphost.example.com")
            }
            #expect(scriptBlocked)

            // …then allowlist the host (the request host is what the allowlist keys
            // on for a main-frame document) and observe the injection stop.
            store._addAdBlockAllowlistHost("csphost.example.com")
            let injectionStopped = try await AdBlockTest.pollUntil {
                try await navigateAndReadInlineScriptRan(page, host: "csphost.example.com")
            }
            #expect(injectionStopped)
        }
    }
}

// MARK: - Fixtures & helpers

extension AdBlockCSPTests {
    // Response headers shared by every fixture: force HTML parsing (the test server
    // sets no Content-Type) and `no-store` so each navigation is a fresh network
    // load re-evaluated against the current engine.
    fileprivate static let fixtureHeaders = ["Content-Type": "text/html", "Cache-Control": "no-store"]

    // The same headers plus the fixture's *own* `Content-Security-Policy`, used by
    // the merge / no-match cases to prove injected policies combine with (and never
    // clobber) a header the response already carries.
    fileprivate static let ownCSPHeaders = [
        "Content-Type": "text/html",
        "Cache-Control": "no-store",
        "Content-Security-Policy": "style-src 'none'",
    ]

    // A document with two inline probes: an inline `<script>` that sets a global
    // when it runs, and an inline `<style>` that hides `#styleProbe` when it
    // applies. Which probe survives tells us which directives were enforced.
    fileprivate static let fixtureHTML = """
        <!DOCTYPE html><html><head>
        <style>#styleProbe { display: none; }</style>
        <script>window.loadedInline = true;</script>
        </head><body>
        <div id="styleProbe">probe</div>
        </body></html>
        """

    // The frame variant reports its own inline-style result up to the parent. Its
    // inline script is deliberately *not* covered by the frame's CSP so it can run
    // and postMessage even when the stylesheet is blocked.
    fileprivate static let frameFixtureHTML = """
        <!DOCTYPE html><html><head>
        <style>#styleProbe { display: none; }</style>
        </head><body>
        <div id="styleProbe">probe</div>
        <script>
        const applied = getComputedStyle(document.getElementById("styleProbe")).display === "none";
        parent.postMessage({ frameStyleApplied: applied }, "*");
        </script>
        </body></html>
        """

    // Serves the CSP fixtures behind an HTTPS proxy, builds an isolated persistent
    // data store, applies `configure`, and runs `body`. All hosts share these
    // routes (the server matches on path only); the *rules* discriminate by host.
    @MainActor
    fileprivate func withCSPPage(
        configure: (WKWebsiteDataStore) -> Void,
        body: (WebPage, WKWebsiteDataStore) async throws -> Void
    ) async throws {
        let directory = AdBlockTest.uniqueDirectory()

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/csp", headers: Self.fixtureHeaders) { Self.fixtureHTML }
            ProxyRoute("/owncsp", headers: Self.ownCSPHeaders) { Self.fixtureHTML }
            ProxyRoute("/cspframe", headers: Self.fixtureHeaders) { Self.frameFixtureHTML }
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

    // Navigates the main frame to `host`/`path`. A fresh navigation (with the
    // fixtures' `no-store`) re-fetches the document so its CSP reflects the current
    // engine state.
    @MainActor
    fileprivate func navigate(_ page: WebPage, host: String, path: String = "/csp") async throws {
        try await page.load(URL(string: "https://\(host)\(path)")).wait()
    }

    // True when the fixture's inline `<script>` ran (i.e. `script-src` did not block
    // it). Read from the main content world, which is not itself subject to the
    // page's CSP, so reading the global is always allowed.
    @MainActor
    fileprivate func inlineScriptRan(_ page: WebPage) async throws -> Bool {
        let result = try await page.callJavaScript("return window.loadedInline === true;")
        return (result as? Bool) ?? false
    }

    // True when the fixture's inline `<style>` applied (i.e. `style-src` did not
    // block it): the probe element is hidden only when its inline rule took effect.
    @MainActor
    fileprivate func inlineStyleApplied(_ page: WebPage) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            const probe = document.getElementById("styleProbe");
            return probe ? getComputedStyle(probe).display === "none" : false;
            """
        )
        return (result as? Bool) ?? false
    }

    // Convenience: navigate to `host` then read whether the inline script ran, so a
    // poll body reads as a single expression.
    @MainActor
    fileprivate func navigateAndReadInlineScriptRan(_ page: WebPage, host: String) async throws -> Bool {
        try await navigate(page, host: host)
        return try await inlineScriptRan(page)
    }

    // Appends a fresh subframe pointing at `host`/`cspframe` and resolves with the
    // frame's reported inline-style result. A new frame per call (with `no-store`)
    // re-checks against the live engine.
    @MainActor
    fileprivate func frameStyleApplied(_ page: WebPage, host: String) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            return await new Promise((resolve) => {
                const handler = (event) => {
                    if (event.data && "frameStyleApplied" in event.data) {
                        window.removeEventListener("message", handler);
                        resolve(event.data.frameStyleApplied);
                    }
                };
                window.addEventListener("message", handler);
                const frame = document.createElement("iframe");
                frame.src = "https://\(host)/cspframe";
                document.body.appendChild(frame);
            });
            """
        )
        return (result as? Bool) ?? false
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
