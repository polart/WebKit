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

// U7 scriptlet-injection coverage. Exercises the `##+js(...)` path end-to-end:
// the engine's `injected_script` (assembled by adblock-rust from the scriptlet
// resource library at `url_cosmetic_resources` time) rides the U6 cosmetic
// payload to the WebProcess, where `WebResourceLoader::setAdBlockCosmeticResources`
// stashes it on the page's `AdBlockPageAgent` and
// `WebLocalFrameLoaderClient::dispatchDidClearWindowObjectInWorld` injects it into
// the committed document's *main* JS world at document start, before page scripts.
// Maps to brave-core's `CosmeticFiltering*Scriptlet` / `ScriptletInjectionPermissions`
// browser tests (`ad_block_service_browsertest.cc`); see
// `docs/adblock-brave-test-mapping.md` §6.
//
// Loading the scriptlet library: a `##+js(name, ...)` rule only produces an
// `injected_script` when the engine has a resource library that defines `name`.
// This mirrors brave-core exactly — its scriptlet browser tests call the test
// helper `UpdateAdBlockResources(resourcesJSON)` before injecting any `+js` rule.
// The WebKit analogue is the `_setAdBlockResources:` SPI added for these tests
// (`WKWebsiteDataStorePrivate` → `SetAdBlockResources` IPC →
// `AdBlockListStore::setResources`), the embedder path to the previously
// caller-less in-memory `setResources` hook the U9/U10 plan earmarked. The suite
// installs a tiny library of self-contained scriptlets (`Self.resourcesJSON`) —
// same JSON shape brave-core uses: `[{name, aliases, kind:{mime}, content:<base64>,
// permission?}]`.
//
// Observation strategy (the `globalValue` probe from the mapping doc): each
// scriptlet mutates a `window` global (or a page API); the fixture's own inline
// `<script>` then reads that global from the page's main world into a second
// global, and the test reads *that* via `callJavaScript` (which evaluates in the
// `.page` main world). Reading through the fixture's own script — rather than
// only the probe — is what proves main-world injection (a page script cannot see
// an isolated-world global), matching Brave's anti-adblock-parity intent.
//
// Because the engine rebuild after a config change is asynchronous with no
// completion handler, and the scriptlet is computed at document-response time,
// assertions poll by *re-navigating* until the injection settles. Fixtures are
// served `Cache-Control: no-store` so every navigation is a fresh network load
// carrying the current engine's scriptlet — the query string can't be a
// cache-buster because the test server matches routes on the full request target
// (path + query).
//
// Two mapping-doc cases are intentionally deferred, both blocked on the delivery
// model rather than on the test harness:
//
//  - `scriptletInAboutBlank` (Brave `CosmeticFilteringAboutBlankScriptlet`): the
//    injected script rides the *network response* of the frame's navigation
//    (`WebResourceLoader::setAdBlockCosmeticResources`). An `about:blank` document
//    has no network load, so nothing is stashed for it and no scriptlet runs. U7
//    does not model Brave's inherit-parent-URL cosmetic path for URL-less
//    documents (about:blank / srcdoc / data:). Revisit if that path is added.
//  - The *positive* half of `untrustedListPermissionsRestricted` (a sufficiently
//    permissioned list injecting a privileged scriptlet): every list is compiled
//    with the most-restrictive scriptlet permission mask (0, `AdBlockListStore`),
//    and no SPI sets a list's mask, so only the restrictive default — a privileged
//    scriptlet is *not* injected — is observable here. The full 0/insufficient/
//    sufficient escalation Brave tests needs a per-list permission API first.

#if ENABLE_SWIFTUI && ENABLE_CXX_INTEROP

import Testing
@_spi(Testing) import WebKit
private import TestWebKitAPILibrary
private import WebKit_Private._WKWebsiteDataStoreConfiguration
private import WebKit_Private.WKWebsiteDataStorePrivate
import struct Swift.String
import struct Foundation.URL
import struct Foundation.Data

@MainActor
struct AdBlockScriptletTests {
    // MARK: A `##+js(...)` scriptlet runs at document start, before page scripts

    @Test
    func scriptletRunsBeforePageScripts() async throws {
        // `set-ran` sets `window.__scriptletRan`. The fixture's first inline script
        // records whether that global was *already* set when the page's own script
        // ran; a `true` there means the scriptlet executed before page scripts.
        try await withScriptletPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockResources(Self.resourcesJSON)
            store._setAdBlockCustomRules("example.com##+js(set-ran)")
        } body: { page, _ in
            let ranBeforePageScripts = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await boolGlobal(page, "window.__pageSawScriptletRan")
            }
            #expect(ranBeforePageScripts)
        }
    }

    // MARK: Template parameters are bound from the filter's args

    @Test
    func scriptletInstantiatedWithArgs() async throws {
        // `set-arg` is a `{{1}}`-template scriptlet; the filter supplies `hello`, so
        // the injected script assigns exactly that string. Reading it back proves the
        // filter's argument was substituted into the resource template.
        try await withScriptletPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockResources(Self.resourcesJSON)
            store._setAdBlockCustomRules("example.com##+js(set-arg,hello)")
        } body: { page, _ in
            let boundArg = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await stringGlobal(page, "window.__pageSawArg") == "hello"
            }
            #expect(boundArg)
        }
    }

    // MARK: No matching rule ⇒ no injected side effects

    @Test
    func noScriptletWithoutMatch() async throws {
        // The resource library is loaded and a `+js` rule exists, but it targets a
        // *different* host. On `example.com` nothing should be injected, so the
        // scriptlet global stays absent — the injection is keyed to the matched rule,
        // not merely to the library being present.
        try await withScriptletPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockResources(Self.resourcesJSON)
            store._setAdBlockCustomRules("other.com##+js(set-ran)")
        } body: { page, _ in
            // First prove the mechanism is live for the host the rule *does* match, so
            // this is a genuine no-match and not a rule that never built.
            let ranOnOther = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "other.com")
                return try await boolGlobal(page, "window.__pageSawScriptletRan")
            }
            #expect(ranOnOther)

            // On the unmatched host the scriptlet global is never defined.
            try await navigate(page, host: "example.com")
            #expect(try await isUndefined(page, "window.__scriptletRan"))
        }
    }

    // MARK: The scriptlet runs in the page's main world (page scripts observe it)

    @Test
    func scriptletRunsInPageWorld() async throws {
        // `hijack-gcs` overwrites `window.getComputedStyle`. The fixture's own page
        // script then *calls* `getComputedStyle` and records the result; seeing the
        // scriptlet's sentinel colour proves the override was installed in the same
        // (main) world the page executes in — an isolated-world injection would leave
        // the page's `getComputedStyle` untouched.
        try await withScriptletPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockResources(Self.resourcesJSON)
            store._setAdBlockCustomRules("example.com##+js(hijack-gcs)")
        } body: { page, _ in
            let hijackedInPageWorld = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await stringGlobal(page, "window.__hijackedColor") == "Impossible value"
            }
            #expect(hijackedInPageWorld)
        }
    }

    // MARK: Injection reaches child frames, keyed to the frame's own URL

    @Test
    func scriptletInIframe() async throws {
        // The rule targets only the *frame* host. The frame's own scriptlet runs and
        // its inline script reports the result up to the parent, while the top
        // document (`example.com`, unmatched) gets no injection — proving the
        // scriptlet is delivered per-document against each frame's navigation URL.
        try await withScriptletPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockResources(Self.resourcesJSON)
            store._setAdBlockCustomRules("sfframe.example.com##+js(set-ran)")
        } body: { page, _ in
            try await navigate(page, host: "example.com")
            // Top document is unmatched, so its scriptlet global is absent.
            #expect(try await isUndefined(page, "window.__scriptletRan"))

            // The frame's scriptlet runs once the engine settles.
            let frameRan = try await AdBlockTest.pollUntil {
                try await frameScriptletRan(page, host: "sfframe.example.com")
            }
            #expect(frameRan)
        }
    }

    // MARK: A privileged scriptlet is not injected from an untrusted (mask-0) list

    @Test
    func untrustedListPermissionsRestricted() async throws {
        // `set-privileged` requires a non-default permission bit; every list is
        // compiled with the most-restrictive mask (0), so it must never inject. The
        // co-located non-privileged `set-ran` *does* inject, so the assertion is a
        // real permission gate and not a blanket failure to build the rules.
        try await withScriptletPage { store in
            store._setAdBlockEnabled(true)
            store._setAdBlockResources(Self.resourcesJSON)
            store._setAdBlockCustomRules(
                """
                example.com##+js(set-ran)
                example.com##+js(set-privileged)
                """
            )
        } body: { page, _ in
            // Wait until the permitted scriptlet has injected (engine settled)…
            let permittedRan = try await AdBlockTest.pollUntil {
                try await navigate(page, host: "example.com")
                return try await boolGlobal(page, "window.__pageSawScriptletRan")
            }
            #expect(permittedRan)

            // …and confirm the privileged one was gated out in the same run.
            #expect(try await isUndefined(page, "window.__privileged"))
        }
    }
}

// MARK: - Fixtures & helpers

extension AdBlockScriptletTests {
    // Response headers shared by every fixture: force HTML parsing (the test server
    // sets no Content-Type) and `no-store` so each navigation is a fresh network
    // load re-evaluated against the current engine.
    fileprivate static let fixtureHeaders = ["Content-Type": "text/html", "Cache-Control": "no-store"]

    // The main fixture's inline `<script>` reads, from the page's own main world,
    // whatever the injected scriptlet left behind and reflects it into stable
    // globals the test can poll: whether `set-ran` fired before page scripts, the
    // `set-arg` template value, and the `hijack-gcs` sentinel colour. Absent
    // scriptlets leave the reflections at their false/null defaults.
    fileprivate static let fixtureHTML = """
        <!DOCTYPE html><html><head></head><body>
        <script>
        window.__pageSawScriptletRan = (window.__scriptletRan === true);
        window.__pageSawArg = (typeof window.__scriptletArg === "string") ? window.__scriptletArg : null;
        try {
            window.__hijackedColor = window.getComputedStyle(document.body).color;
        } catch (e) {
            window.__hijackedColor = null;
        }
        </script>
        </body></html>
        """

    // The frame variant reports whether its own scriptlet ran, up to the parent. Its
    // inline script runs unconditionally so it can always postMessage the result.
    fileprivate static let frameFixtureHTML = """
        <!DOCTYPE html><html><head></head><body>
        <script>
        parent.postMessage({ frameScriptletRan: (window.__scriptletRan === true) }, "*");
        </script>
        </body></html>
        """

    // The scriptlet resource library, in brave-core's `UpdateAdBlockResources`
    // JSON shape. Each `content` is a self-contained scriptlet body, base64-encoded
    // as adblock-rust expects. `set-arg` uses a `{{1}}` template parameter; the
    // others are literal. `set-privileged` carries a non-default permission bit so
    // the restrictive-default test can prove it is gated out.
    fileprivate static var resourcesJSON: String {
        let entries = [
            resource(name: "set-ran.js", body: "window.__scriptletRan = true;"),
            resource(name: "set-arg.js", body: "window.__scriptletArg = \"{{1}}\";"),
            resource(
                name: "hijack-gcs.js",
                body: "window.getComputedStyle = function () { return { color: \"Impossible value\" }; };"
            ),
            resource(name: "set-privileged.js", body: "window.__privileged = true;", permission: 1),
        ]
        return "[\(entries.joined(separator: ","))]"
    }

    // Builds one resource-library entry: `{name, aliases, kind:{mime}, content:<base64>, permission?}`.
    fileprivate static func resource(name: String, body: String, permission: Int? = nil) -> String {
        let encoded = Data(body.utf8).base64EncodedString()
        let permissionField = permission.map { ",\"permission\":\($0)" } ?? ""
        return """
            {"name":"\(name)","aliases":[],"kind":{"mime":"application/javascript"},"content":"\(encoded)"\(permissionField)}
            """
    }

    // Serves the scriptlet fixtures behind an HTTPS proxy, builds an isolated
    // persistent data store, applies `configure`, and runs `body`. All hosts share
    // these routes (the server matches on path only); the *rules* discriminate by
    // host.
    @MainActor
    fileprivate func withScriptletPage(
        configure: (WKWebsiteDataStore) -> Void,
        body: (WebPage, WKWebsiteDataStore) async throws -> Void
    ) async throws {
        let directory = AdBlockTest.uniqueDirectory()

        var server = ProxyHTTPServer(protocol: .httpsProxy) {
            ProxyRoute("/scriptlet", headers: Self.fixtureHeaders) { Self.fixtureHTML }
            ProxyRoute("/scriptletframe", headers: Self.fixtureHeaders) { Self.frameFixtureHTML }
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

    // Navigates the main frame to `host`/scriptlet. A fresh navigation (with the
    // fixtures' `no-store`) re-fetches the document so its scriptlet reflects the
    // current engine state.
    @MainActor
    fileprivate func navigate(_ page: WebPage, host: String) async throws {
        try await page.load(URL(string: "https://\(host)/scriptlet")).wait()
    }

    // True when `expr` evaluates to boolean `true` in the page's main world.
    @MainActor
    fileprivate func boolGlobal(_ page: WebPage, _ expr: String) async throws -> Bool {
        let result = try await page.callJavaScript("return \(expr) === true;")
        return (result as? Bool) ?? false
    }

    // The string value of `expr` in the page's main world, or nil when it is not a
    // string (unset / wrong type).
    @MainActor
    fileprivate func stringGlobal(_ page: WebPage, _ expr: String) async throws -> String? {
        let result = try await page.callJavaScript(
            "return (typeof (\(expr)) === \"string\") ? (\(expr)) : null;"
        )
        return result as? String
    }

    // True when `expr` is `undefined` in the page's main world (the scriptlet that
    // would define it did not run).
    @MainActor
    fileprivate func isUndefined(_ page: WebPage, _ expr: String) async throws -> Bool {
        let result = try await page.callJavaScript("return typeof (\(expr)) === \"undefined\";")
        return (result as? Bool) ?? false
    }

    // Appends a fresh subframe pointing at `host`/scriptletframe and resolves with
    // whether the frame's own scriptlet ran. A new frame per call (with `no-store`)
    // re-checks against the live engine.
    @MainActor
    fileprivate func frameScriptletRan(_ page: WebPage, host: String) async throws -> Bool {
        let result = try await page.callJavaScript(
            """
            return await new Promise((resolve) => {
                const handler = (event) => {
                    if (event.data && "frameScriptletRan" in event.data) {
                        window.removeEventListener("message", handler);
                        resolve(event.data.frameScriptletRan);
                    }
                };
                window.addEventListener("message", handler);
                const frame = document.createElement("iframe");
                frame.src = "https://\(host)/scriptletframe";
                document.body.appendChild(frame);
            });
            """
        )
        return (result as? Bool) ?? false
    }
}

#endif // ENABLE_SWIFTUI && ENABLE_CXX_INTEROP
