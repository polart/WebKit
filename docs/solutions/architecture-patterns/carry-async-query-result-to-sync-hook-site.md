---
title: Carry an async engine result forward to a synchronous hook site
date: 2026-07-17
category: architecture-patterns
module: NetworkProcess adblock integration
problem_type: architecture_pattern
component: service_object
severity: medium
applies_when:
  - "A hook site is synchronous but the data it needs comes from a thread- or process-confined async service"
  - "Making the sync site async would force a large continuation-style refactor of surrounding code"
  - "The async data is derivable earlier in the same operation's lifecycle, during an already-async phase"
tags: [webkit, networkprocess, adblock, async, workqueue, ipc, csp, hook]
---

# Carry an async engine result forward to a synchronous hook site

## Context

The adblock engine (`AdBlockManager`) confines every query to a dedicated serial `WorkQueue` because adblock-rust's `Engine` is not `Send+Sync` under the `single-thread` feature (KTD3). Every query is therefore **async** — issued from the main run loop and completed back on it (see the query methods in `Source/WebKit/NetworkProcess/AdBlock/AdBlockManager.h`).

U5 needed engine-provided CSP directives applied to document responses inside `NetworkResourceLoader::didReceiveResponse` (`Source/WebKit/NetworkProcess/NetworkResourceLoader.cpp`). But `didReceiveResponse` is **synchronous**: it mutates `m_response`, runs a long sequence of validation/CSP/COEP checks, and sends the response — all inline. There is no way to synchronously query the WorkQueue-confined engine there, and injecting an async hop mid-function would mean restructuring the entire response path into continuations.

## Guidance

When a synchronous hook site needs a value from a thread/process-confined async service, **do not make the sync site async.** Instead:

1. **Fetch during the nearest already-async phase of the same operation.** For a network load, the request-check phase (`NetworkLoadChecker::check` → `checkRequest`) is already async and always completes *before* the response is received.
2. **Carry the result on an object whose lifetime spans both phases.** Store it on the per-load `NetworkLoadChecker` (`m_adBlockCSPDirectives`, exposed via `adBlockCSPDirectives()`).
3. **Apply it synchronously at the hook site** by reading the carried value — a 2-line hook, no async hop:

```cpp
// NetworkResourceLoader::didReceiveResponse, after m_response is established
#if ENABLE(ADBLOCK)
    if (networkLoadChecker)
        AdBlock::mergeCSPDirectives(m_response, networkLoadChecker->adBlockCSPDirectives());
#endif
```

The fetch is folded into the existing U4 block-check glue (`AdBlock::checkNetworkRequest` in `AdBlockRequestCheck.cpp`) so the check performs both the block query and, for document/subdocument destinations, the CSP query — the completion hands back `(request, blocked, cspDirectives)`. Non-document loads carry an empty string, so the response-time hook is inherently scoped without needing its own destination test.

## Why This Matters

- **The sync path stays sync.** No continuation refactor of `didReceiveResponse`, and the surgical-hook budget (R9: 1–5 lines behind `#if ENABLE(ADBLOCK)` per pristine core file) is preserved — only `NetworkResourceLoader.cpp` is touched, with 2 lines.
- **It is race-free by construction, not by luck.** The carry object is populated during a phase that is *ordered before* the consuming phase in the same operation. The request check must complete before the network load is issued, which must complete before the response arrives — so the value is always present (or deliberately empty) by the time the sync site reads it. This is stronger than firing a second parallel async query near response time and hoping it resolves first.
- **Redirects self-correct.** Because the fetch rides the request check and redirects re-enter the check, the carried value reflects the final landed URL.

The failure mode this avoids: a naive "query the engine at response time" either blocks the response thread (impossible — the engine is on another queue) or bolts an async continuation onto a synchronous function, ballooning a 2-line hook into a rewrite and creating a race between the late query and the outgoing response.

## When to Apply

- The consumer is a synchronous WebKit hook (response handling, commit-time application, layout) and the producer is a `WorkQueue`/IPC-confined async service.
- The needed value is a pure function of state available during an earlier async phase of the same operation (the request URL, frame URL, resource type).
- Reach for it again in U6 (cosmetic CSS computed network-side and carried to the WebProcess for commit-time application follows the same shape — see the adblock integration plan).

Do **not** use it when the value genuinely cannot be computed until the sync moment (then the sync site must itself become async, or the work must move); or when no already-async earlier phase exists to piggyback on.

## Examples

**Before (naive — forces the response path async):**

```cpp
// Hypothetical: query the engine inside didReceiveResponse
adBlockManager().cspDirectives(url, ..., [this](String csp) {
    // Now the ENTIRE rest of didReceiveResponse — validateResponse, CSP
    // frame-ancestors interruption, COEP, send() — must move into this
    // continuation. A 2-line need became a function rewrite, and the
    // response is now waiting on a cross-queue round trip.
});
```

**After (carry-forward):**

```cpp
// Phase 1 — during the already-async request check (AdBlockRequestCheck.cpp):
//   checkNetworkRequest completion returns (request, blocked, cspDirectives)
//   NetworkLoadChecker stores it:
protectedThis->m_adBlockCSPDirectives = WTF::move(cspDirectives);

// Phase 2 — synchronous read at the hook site (shown above):
AdBlock::mergeCSPDirectives(m_response, networkLoadChecker->adBlockCSPDirectives());
```

`mergeCSPDirectives` also comma-joins with any existing `Content-Security-Policy` header per CSP2 and rejects control-character-bearing directives before injection — but that is CSP-specific; the transferable idea is the fetch-early-carry-forward structure.

## Related

- `docs/plans/2026-07-11-001-feature-adblock-integration-plan.md` — U5 (CSP hook), and U6 (cosmetic CSS delivery), which reuses this shape.
- U4 network blocking established the async request-check hook this fetch piggybacks on (`AdBlock::checkNetworkRequest`).
