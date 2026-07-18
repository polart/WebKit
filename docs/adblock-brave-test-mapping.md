# Adblock Integration Test Mapping: brave-core → WebKit U3–U9

Created: 2026-07-19

Maps Brave's **integration** test cases (brave-core's tests that exercise how
adblock-rust is wired into the browser) onto concrete WebKit test cases for
units U3–U9. The goal is to seed the deferred U3–U9 Swift Testing suites without
re-inventing coverage.

**Out of scope by design:** the adblock-rust crate's own tests
(`../adblock-rust/tests/`). Filter parsing and matching correctness are the
engine's responsibility and are already covered upstream — we do not duplicate
them. Everything below is about *integration*: request interception, CSP/cosmetic
injection, scriptlet execution, dynamic hiding, and list lifecycle.

Brave sources referenced (read-only sibling repo):
- `../brave-core/browser/brave_shields/ad_block_service_browsertest.cc` — the core end-to-end suite (~95 tests)
- `../brave-core/browser/brave_shields/ad_block_dat_cache_browsertest.cc`
- `../brave-core/components/brave_shields/content/test/ad_block_service_unittest.cc`
- `../brave-core/components/brave_shields/content/test/{cosmetic_merge,csp_merge,strip_procedural_filters}_unittest.cc`

---

## 1. Test harness baseline

The U10 suite (`Tools/TestWebKitAPI/Tests/WebKit/WebPage/AdBlockAPITests.swift`)
establishes the reusable pattern, which mirrors Brave's browsertest shape almost
one-to-one:

| Step | Brave (`ad_block_service_browsertest.cc`) | WebKit (`AdBlockAPITests.swift`) |
|------|-------------------------------------------|----------------------------------|
| Inject rules directly | `UpdateAdBlockInstanceWithRules(...)` / `UpdateCustomAdBlockInstanceWithRules(...)` | `store._setAdBlockCustomRules(...)`, `store._addAdBlockSubscription(...)` |
| Serve fixtures | `embedded_test_server()` | `HTTPServer(protocol: .httpsProxy)` with `Route(...)` |
| Navigate | `NavigateToURL(url)` | `page.load(URL(...)).wait()` |
| Assert via page JS | `EvalJs(contents, ...)` | `page.callJavaScript(...)` |
| Wait for async rebuild | `WaitForAdBlockServiceThreads()` / observers | `pollUntil { ... }` (100 ms poll, 15 s timeout) |

Reuse `withAdBlockPage`, `makeAdBlockDataStore`, `pollUntil`, and the isolated
persistent-store setup verbatim. New suites live alongside the existing one in
`Tools/TestWebKitAPI/Tests/WebKit/WebPage/` (the plan's original `*.mm` paths
under `Tests/WebKitCocoa/` are superseded by the Swift Testing standard).

### 1.1 Required harness extensions (probes)

The existing `adSubresourceBlocked` fetch-probe covers network blocking only.
Other units need new page-JS probes, each modeled on a specific Brave helper:

| Probe | What it observes | Brave equivalent | Needed by |
|-------|------------------|------------------|-----------|
| `adSubresourceBlocked(page)` *(exists)* | `no-cors`/`no-store` fetch rejects on block | `setExpectations()` + `addImage()` + `kAdsBlocked` counter | U3, U4, U9 |
| `computedDisplay(page, selector)` | `getComputedStyle(el).display === "none"` | `waitCSSSelector('#sel','display','none')` | U6, U8 |
| `scriptLoaded(page, flag)` | a `window.__flag` boolean set by a fixture `<script>` | `window.loadedNonceScript` etc. after `await window.allLoaded` | U5 |
| `globalValue(page, expr)` | evaluate an arbitrary global the scriptlet mutates | `EvalJs(window.someConstant)` in scriptlet tests | U7 |
| test-only IPC/query counter | count of class/id tokens sent over the U8 IPC | (Brave uses `AdBlockServiceTestJsPerformance`) | U8 |

Fixtures to add under the test server (parallel Brave fixtures noted):
- `csp_rules.html` — inline/eval/same-party/third-party/unsafe-inline scripts + a data image, each setting a `window.loaded*` flag (Brave: `content/test/data/csp_rules.html`).
- `cosmetic_filtering.html` — elements with target ids/classes plus a dynamic insertion hook (Brave: `cosmetic_filtering.html`).

---

## 2. U3 — AdBlockEngine service in NetworkProcess

**Unit:** `Source/WebKit/NetworkProcess/AdBlock/AdBlockEngine.{h,cpp}`,
`AdBlockManager.{h,cpp}`. Internal service; now observable end-to-end through the
U10 embedder API. Suite: `AdBlockEngineTests.swift`.

| WebKit test (proposed) | Proves | Brave origin | Probe |
|------------------------|--------|--------------|-------|
| `coldStartWithWarmDat` | Engine ready from `.dat` without re-parse | `ad_block_service_unittest.cc :: LoadsCachedDATFilesOnCreation`, `LoadsOnlyDefaultCachedDATFile` | fetch |
| `coldStartWithoutDat` | Falls back to parsing configured lists | `WorksWithoutCachedDATFiles` | fetch |
| `corruptDatFallsBackAndRewrites` | Corrupt `.dat` → parse fallback + cache rewrite | `DATFailureFallbackWithUninitializedProvider`; `ad_block_dat_cache_browsertest.cc :: FallsBackToFilterList` | fetch + restart |
| `emptyFilterSetDoesNotCrash` | Empty/absent rules is a no-op, not a crash | `EmptyFilterSetDoesNotCrash` | fetch |
| `engineSwapWhileQueryInFlight` | Atomic swap under concurrent queries, no crash/UAF | `ProviderChangeLoadsNewFilterRules`, `CachedDATLoadedThenProviderUpdates` | fetch + rebuild poll |
| `passThroughBeforeListsLoaded` | Queries before any list loads return "allow" | *(WebKit-specific; no Brave analogue)* | fetch |
| `allowlistedHostSkipsEngine` | Allowlisted host completes "allow" before FFI | closest: `SubFrameShieldsOff` (shields-off bypass) | fetch |

Notes: the in-flight-swap and pass-through cases are WebKit-specific concurrency
guarantees (KTD3/KTD4) with no direct Brave test — keep them. TSan-clean under
concurrent query+swap remains a manual/CI gate, not a Swift assertion.

---

## 3. U4 — Network request blocking hook

**Unit:** `NetworkLoadChecker.cpp`, `NetworkSocketChannel.cpp`. Suite:
`AdBlockNetworkBlockingTests.swift`. Directly reuses `adSubresourceBlocked`.

| WebKit test (proposed) | Proves | Brave origin | Probe |
|------------------------|--------|--------------|-------|
| `blocksMatchingSubresource` | Matching request blocked; page otherwise loads | `AdsGetBlockedByDefaultBlocker`, `AdsGetBlockedByCustomBlocker` | fetch |
| `allowsNonMatchingSubresource` | Non-matching request loads | `NotAdsDoNotGetBlockedByDefaultBlocker`, `NotAdsDoNotGetBlockedByCustomBlocker` | fetch |
| `exceptionRuleAllows` | `@@` exception un-blocks | `DefaultBlockCustomException`, `CustomBlockDefaultException` | fetch |
| `thirdPartyRuleDiscriminates` | `$third-party` blocks cross-site, allows same-site | `AdBlockThirdPartyWorksByETLDP1`, `AdBlockThirdPartyWorksForThirdPartyHost` | fetch |
| `blocksInSubframe` | Blocking applies in nested frames | `SubFrame`; bypassed by `SubFrameShieldsOff` | fetch (in-frame) |
| `blocksServiceWorkerRequest` | SW-initiated requests are checked | `ServiceWorkerRequest` | fetch |
| `blocksWebSocketOpen` | WS to a blocked host fails to open | `MAYBE_WebSocketBlocking` | WS open |
| `blocksAboutBlankSubresource` | `about:blank` frame requests checked | `NetworkBlockAboutBlank` | fetch |
| `redirectHopReEvaluated` | 302 to a blocked URL is blocked at the redirect hop | *(weak analogue: `RedirectRulesAreRespected`)* | fetch + redirect route |
| `subresourceBlockThenAllowRegression` | Pins the 2026-07-17 moved-`ResourceRequest` fix | *(WebKit-specific regression pin)* | fetch |
| `flagOffLoadsEverything` | Master toggle off ⇒ nothing blocked | covered via `store._setAdBlockEnabled(false)` | fetch |

Notes: `redirectHopReEvaluated` and `subresourceBlockThenAllowRegression` are
required by the plan (R1 + the regression note) even though Brave has no
matching named test. Brave's ad-counter tests (`TwoSameAdsGetCountedAsOne`,
`TwoDiffAdsGetCountedAsTwo`) map to a blocked-resource **counter**, which WebKit
does not expose yet — defer until/unless a counter API exists.

---

## 4. U5 — CSP header injection hook

**Unit:** `NetworkResourceLoader.cpp` (`didReceiveResponse`). Suite:
`AdBlockCSPTests.swift`. Needs the `scriptLoaded` probe + `csp_rules.html`.

| WebKit test (proposed) | Proves | Brave origin | Probe |
|------------------------|--------|--------------|-------|
| `cspRuleBlocksInlineScript` | `$csp=script-src 'none'` stops inline script | `CspRule` | scriptLoaded flags |
| `cspMergesWithExistingHeader` | Injected policy combines with a response's own CSP | `CspRuleMerging` | scriptLoaded flags |
| `multipleCspRulesUnion` | Two `$csp` rules union their directives | `CspRuleMerging` | scriptLoaded flags |
| `subframeGetsOwnDirectives` | Frame CSP derives from frame URL, not top URL | `CspRuleMerging` (uses `sub.example.com`) | scriptLoaded (in-frame) |
| `noMatchingCspLeavesHeadersUnchanged` | No `$csp` match ⇒ response headers untouched | *(implicit in Brave; assert explicitly)* | header read |
| `cspNotInjectedWhenAllowlisted` | Allowlisted/shields-down host gets no injection | `CspRuleShieldsDown` | scriptLoaded flags |

Lower-level merge semantics (`MergeCspDirectiveInto`) are unit-tested by Brave in
`csp_merge_unittest.cc` (`MergeEmptyIntoNonEmpty`, `MergeNonEmptyIntoEmpty`,
`MergeNonEmptyIntoNonEmpty`). WebKit performs the same comma-join in
`NetworkResourceLoader`; the `cspMergesWithExistingHeader` end-to-end test covers
it, but a focused C++ merge test is optional if the join logic grows.

---

## 5. U6 — Cosmetic CSS computation + delivery

**Unit:** `AdBlockCosmeticResources.{h,cpp}`, `DocumentLoader.cpp`. Suite:
`AdBlockCosmeticTests.swift`. Needs the `computedDisplay` probe +
`cosmetic_filtering.html`.

| WebKit test (proposed) | Proves | Brave origin | Probe |
|------------------------|--------|--------------|-------|
| `hidesMatchingSelector` | `example.com##.ad` hides the element | `CosmeticFilteringSimple` | computedDisplay |
| `hiddenBeforeFirstPaint` | Selector present at commit ⇒ no flash of unhidden ad | *(WebKit-specific rigor; Brave polls with `waitCSSSelector`)* | computedDisplay at parse time |
| `siteSpecificScoping` | Selector hidden only on its domain | implicit in `CosmeticFilteringSimple` (`b.com###...`) | computedDisplay |
| `exceptionRuleUnhides` | `#@#` exception leaves element visible | `CosmeticFilteringUnhide` | computedDisplay |
| `customStyleApplied` | `##selector:style(...)` applies the style | `CosmeticFilteringCustomStyle` | computed style prop |
| `subframeGetsOwnSelectors` | Frame selectors keyed to frame URL | `CosmeticFilteringFrames` | computedDisplay (in-frame) |
| `generichideDisablesGenericRules` | `generichide` suppresses generic selectors | `CosmeticFilteringGenerichide` | computedDisplay |
| `cosmeticDisabledWhenFlagOff` | Master toggle off ⇒ nothing hidden | `CosmeticFilteringDisabled` | computedDisplay |
| `protects1pAndHides1pContent` | 1p protection / 1p-content behavior | `CosmeticFilteringProtect1p`, `CosmeticFilteringHide1pContent` | computedDisplay |

Note: `hiddenBeforeFirstPaint` is the WebKit differentiator (R3 pre-paint
delivery via the pending-selector pipeline). Assert computed style is already
`none` from an inline script at parse time, not just eventually.

---

## 6. U7 — Scriptlet injection

**Unit:** `WebProcess/AdBlock/AdBlockPageAgent.{h,cpp}`. Suite:
`AdBlockScriptletTests.swift`. Needs the `globalValue` probe.

| WebKit test (proposed) | Proves | Brave origin | Probe |
|------------------------|--------|--------------|-------|
| `scriptletRunsBeforePageScripts` | `##+js(set-constant,...)` runs at document start | `CosmeticFilteringWindowScriptlet` | globalValue |
| `scriptletInstantiatedWithArgs` | Template params bound from filter args | `CosmeticFilteringWindowScriptlet` (arg form) | globalValue |
| `noScriptletWithoutMatch` | No matching rule ⇒ no injected side effects | *(assert absence; implicit in Brave)* | globalValue |
| `scriptletRunsInPageWorld` | Effect visible to page scripts (not isolated world) | `CosmeticFilteringWindowScriptlet` | globalValue |
| `scriptletInIframe` | Injection into child frames | `CosmeticFilteringIframeScriptlet` | globalValue (in-frame) |
| `scriptletInAboutBlank` | Injection into `about:blank` documents | `CosmeticFilteringAboutBlankScriptlet` | globalValue (in-frame) |
| `untrustedListPermissionsRestricted` | Untrusted-list scriptlets default to most-restrictive perms | `ScriptletInjectionPermissions` | globalValue |

Brave also has `ScriptletDebugLogsFlagEnabledTest :: CanDebugSetToTrue` and
custom-resource CRUD (`ad_block_custom_resources_browsertest.cc`); both are
out of current U7 scope (no debug-logging flag / custom-resource UI yet).

---

## 7. U8 — Dynamic cosmetic hiding agent + IPC

**Unit:** `AdBlockPageAgent` (mutation observation),
`NetworkConnectionToWebProcess` (+1 async message). Suite:
`AdBlockDynamicHidingTests.swift`. Needs `computedDisplay` + a test-only
IPC/query counter.

| WebKit test (proposed) | Proves | Brave origin | Probe |
|------------------------|--------|--------------|-------|
| `lateInsertedElementGetsHidden` | Element added after load with a matching class is hidden | `CosmeticFilteringDynamic` | computedDisplay (post-insert) |
| `dynamicCustomRuleHides` | Custom generic rule hides dynamic element | `CosmeticFilteringDynamicCustom` | computedDisplay |
| `tokensQueriedOnce` | 100 elements, same class ⇒ one IPC query | *(WebKit-specific; Brave measures via `AdBlockServiceTestJsPerformance`)* | IPC counter |
| `exceptedClassNotHidden` | Excepted class (U6 exception set) not hidden | derived from `CosmeticFilteringUnhide` semantics | computedDisplay |
| `generichidePageDisablesDynamic` | Dynamic generic hiding off on `generichide` pages | `CosmeticFilteringGenerichide` (dynamic path) | computedDisplay |

**Explicitly deferred — procedural filters.** Brave's procedural-filter tests
(`ProceduralFilterHasText`, `MatchesAttr`, `MatchesCss`, `MatchesPath`,
`MinTextLength`, `Upward`, `Xpath`, `DynamicAddedChildHasText`, plus
`strip_procedural_filters_unittest.cc`) exercise `:has-text()`, `:xpath()`, etc.
These are **not in the U8 scope** (class/id generic hiding only). Listed here so
they are not silently dropped — revisit if procedural filtering is added later.

---

## 8. U9 — Filter list management + persistence

**Unit:** `AdBlockListStore.{h,cpp}`, `AdBlockListDownloader.{h,cpp}`. Suite:
`AdBlockListManagementTests.swift`. Reuses the U10 subscription/state/restart
harness (already proven in `AdBlockAPITests.swift`).

| WebKit test (proposed) | Proves | Brave origin | Probe |
|------------------------|--------|--------------|-------|
| `addSubscriptionBlocksPerNewList` | Adding a list URL blocks per its rules, no restart | `SubscribeToListUrlTwice`; `ad_block_service_unittest.cc :: ProviderChangeLoadsNewFilterRules` | fetch + poll |
| `toggleSubscriptionOffThenOn` | Disabling un-blocks; re-enabling re-blocks | `ListEnabled` | fetch + poll |
| `customRuleAddRemove` | Custom rule takes effect / reverts on rebuild | `AdsGetBlockedByCustomBlocker`, `NotAdsDoNotGetBlockedByCustomBlocker` | fetch + poll |
| `customRulesSurviveRestart` | Custom rules persist across NetworkProcess restart | *(covered by U10 `subscriptionStateRoundTrips...`; extend to blocking)* | state + restart |
| `malformedListTreatedAsFailure` | HTML/404 body ⇒ near-zero rules ⇒ previous list retained | `MAYBE_SubscribeTo404List` | fetch + poll |
| `warmDatSkipsReparseOnRestart` | Restart with warm `.dat` ⇒ no re-parse | `LoadsCachedDATFilesOnCreation`, `WorksWithoutCachedDATFiles` | parse-counter / timing |
| `deletedDatRebuildsFromListText` | Missing `.dat` ⇒ rebuild from stored list text | `DATFailureFallbackWithUninitializedProvider` | fetch + restart |
| `concurrentTogglesConverge` | Rapid toggles settle to one consistent engine | *(WebKit-specific; last-write-wins)* | fetch + poll |
| `multiListResultsMerge` | Cosmetic/CSP results merge across enabled lists | `cosmetic_merge_unittest.cc` (9 cases), `csp_merge_unittest.cc` (4 cases) | computedDisplay / scriptLoaded |

Notes: downloads must go through a local `HTTPServer` route (as in the U10
`subscriptionStateRoundTrips...` test). The merge cases have thorough Brave
unit coverage (empty/non-empty, force-hide, generichide interactions) — port the
distinct scenarios rather than a single smoke test.

---

## 9. Brave tests intentionally excluded

Not mapped, with reason:

- **adblock-rust crate tests** — engine correctness, owned upstream (see intro).
- **Ad-blocked counters** — `TwoSameAdsGetCountedAsOne`, `TwoDiffAdsGetCountedAsTwo`: no WebKit counter API yet.
- **Procedural filters** — deferred with U8 (§7); revisit if the feature lands.
- **Adblock-only mode** — `AdblockOnlyMode*`, `ad_block_component_service_manager_unittest.cc`: Brave-specific product mode, not in scope.
- **DeAmp** — `CheckForDeAmpPref`: separate feature.
- **Content picker** — `ContentPicker*`: separate UI feature.
- **CNAME uncloaking** — `CnameCloaked*`, `NoDnsQueriesIssued`: depends on Brave's DNS-based uncloaking; not in the U3–U10 plan.
- **removeparam** — `Removeparam*`: query-parameter stripping, not in current scope.
- **Element collapsing** — `CollapseBlocked{Image,Iframe}`: layout-side collapse, separate from network block (revisit if collapse is added).
- **P3A / metrics, JS-blocked events, devtools reporting** — telemetry/UX surfaces with no WebKit analogue.

---

## 10. Suggested build order

Priority follows dependency order and coverage gap (all of U3–U9 currently lack
automated tests; only U10 is covered):

1. **U4** `AdBlockNetworkBlockingTests` — reuses the existing fetch-probe as-is; highest-value, lowest-friction. Includes the 2026-07-17 regression pin.
2. **U6** `AdBlockCosmeticTests` — add the `computedDisplay` probe + `cosmetic_filtering.html`.
3. **U7** `AdBlockScriptletTests` — add the `globalValue` probe.
4. **U5** `AdBlockCSPTests` — add the `scriptLoaded` probe + `csp_rules.html`.
5. **U9** `AdBlockListManagementTests` — extends the U10 subscription/restart harness to assert blocking.
6. **U8** `AdBlockDynamicHidingTests` — needs the IPC/query counter test hook (most harness work).
7. **U3** `AdBlockEngineTests` — service-level guarantees now observable through U10; the concurrency cases (in-flight swap, pass-through) remain partly manual/TSan.
</content>
</invoke>
