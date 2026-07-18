// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// AdBlockManager is the NetworkProcess-lifetime adblock service. It owns the
// current AdBlockEngine and confines every engine query to a dedicated serial
// WorkQueue (KTD3), so the not-Send+Sync rust engine is only ever touched from
// one thread. Callers issue async queries from the main run loop and receive
// completions back on it. A per-host allowlist (KTD8) is consulted before any
// engine query — allowlisted hosts short-circuit to "allow" and never reach the
// engine. Engine swaps are atomic: an in-flight query, dispatched earlier on the
// serial queue, always completes against the engine that was current when it ran.

#pragma once

#if ENABLE(ADBLOCK)

#include "AdBlockEngine.h"
#include "Shared/AdBlock/AdBlockCosmeticResources.h"
#include <atomic>
#include <span>
#include <wtf/CompletionHandler.h>
#include <wtf/HashSet.h>
#include <wtf/Lock.h>
#include <wtf/Ref.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/WorkQueue.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class AdBlockManager : public ThreadSafeRefCounted<AdBlockManager> {
public:
    static Ref<AdBlockManager> create();
    ~AdBlockManager();

    // A list backed by a text file, read on the work queue at compile time. The
    // permission mask gates which scriptlets the list may inject (0 == most
    // restrictive).
    struct ListFileInput {
        String path;
        uint8_t permissionMask { 0 };
    };

    // Engine lifecycle (all applied on the work queue; the swap is atomic).
    void setEngine(Ref<AdBlockEngine>&&);
    void setEngineFromRules(Vector<uint8_t>&&, CompletionHandler<void()>&& = [] { });
    // Assembles a single engine from all enabled lists + the scriptlet/redirect
    // resource library on the work queue and atomically swaps it in (KTD4). The
    // list-text files are read on the work queue too, so no disk I/O touches the
    // main run loop; already-in-memory lists (e.g. custom rules) are passed
    // inline. The list store (U9) uses this for compile-and-swap on any
    // subscription change.
    void setEngineFromListFiles(Vector<ListFileInput>&&, Vector<AdBlockEngine::ListInput>&& inlineLists, String resourcesJSON, CompletionHandler<void()>&& = [] { });

    // Loads a versioned `.dat` cache. completion(false) if the file is missing,
    // too large, corrupt, or from an incompatible engine version, so the caller
    // can fall back to re-parsing source lists (KTD7). On success the restored
    // engine is swapped in.
    void loadCacheFile(const String& path, CompletionHandler<void(bool)>&&);
    // Serializes the current engine to a versioned `.dat` cache. completion(false)
    // if there is no engine yet or the write fails.
    void saveCacheFile(const String& path, CompletionHandler<void(bool)>&&);

    // Master enable gate (U10 embedder API). While disabled, every query
    // short-circuits to the pass-through default without touching the engine, so
    // toggling adblock off is instant and keeps the compiled engine warm for an
    // equally instant re-enable. Default off: nothing blocks until the embedder
    // enables it. Set from the main run loop, read on any thread.
    void setEnabled(bool enabled) { m_enabled.store(enabled, std::memory_order_relaxed); }
    bool isEnabled() const { return m_enabled.load(std::memory_order_relaxed); }

    // Per-site allowlist (KTD8). Mutated and queried from the caller thread.
    void setAllowlistedHosts(HashSet<String>&&);
    void addAllowlistedHost(const String&);
    void removeAllowlistedHost(const String&);
    bool isAllowlistedHost(const String&) const;

    // Async queries. Each is invoked on and completed on the main run loop.
    // Before any list has loaded, or for an allowlisted host, they complete with
    // the pass-through default without touching the engine.
    void checkRequest(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty, CompletionHandler<void(AdBlockEngine::CheckResult)>&&);
    // The navigation's CSP directives (U5) and cosmetic resources — hide
    // selectors, exceptions, scriptlet, generichide flag (U6) — for a document/
    // subframe load, fetched in a single WorkQueue round-trip: the two engine
    // queries share one dispatch out and one hop back, so the latency-sensitive
    // navigation path pays one round-trip, not two. The url_cosmetic_resources
    // JSON is parsed into the struct on the work queue (never the main thread —
    // R3 pre-paint budget); both results are isolated and delivered together on
    // the main run loop.
    void cspAndCosmeticResources(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty, CompletionHandler<void(String cspDirectives, AdBlockCosmeticResources)>&&);
    void hiddenClassIdSelectors(Vector<String>&& classes, Vector<String>&& ids, Vector<String>&& exceptions, const String& hostname, CompletionHandler<void(Vector<String>)>&&);

    // Number of queries that actually reached the engine. A test hook: an
    // allowlisted host or a query issued before any list loaded never increments
    // it. Thread-safe.
    uint64_t engineQueryCount() const { return m_engineQueryCount.load(std::memory_order_relaxed); }

    // On-disk cache format helper, exposed for tests: prepends the magic +
    // version header the loader validates.
    static Vector<uint8_t> encodeCache(std::span<const uint8_t> payload);

private:
    AdBlockManager();

    // Runs on m_queue. Returns false without mutating state on any guard failure.
    bool loadCacheOnQueue(const String& path);

    const Ref<WorkQueue> m_queue;
    // Only touched on m_queue.
    RefPtr<AdBlockEngine> m_engine;
    mutable Lock m_allowlistLock;
    HashSet<String> m_allowlist WTF_GUARDED_BY_LOCK(m_allowlistLock);
    std::atomic<bool> m_enabled { false };
    std::atomic<uint64_t> m_engineQueryCount { 0 };
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
