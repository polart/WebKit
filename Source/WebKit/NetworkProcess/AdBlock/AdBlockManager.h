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

    // Engine lifecycle (all applied on the work queue; the swap is atomic).
    void setEngine(Ref<AdBlockEngine>&&);
    void setEngineFromRules(Vector<uint8_t>&&, CompletionHandler<void()>&& = [] { });

    // Loads a versioned `.dat` cache. completion(false) if the file is missing,
    // too large, corrupt, or from an incompatible engine version, so the caller
    // can fall back to re-parsing source lists (KTD7). On success the restored
    // engine is swapped in.
    void loadCacheFile(const String& path, CompletionHandler<void(bool)>&&);
    // Serializes the current engine to a versioned `.dat` cache. completion(false)
    // if there is no engine yet or the write fails.
    void saveCacheFile(const String& path, CompletionHandler<void(bool)>&&);

    // Per-site allowlist (KTD8). Mutated and queried from the caller thread.
    void setAllowlistedHosts(HashSet<String>&&);
    void addAllowlistedHost(const String&);
    void removeAllowlistedHost(const String&);
    bool isAllowlistedHost(const String&) const;

    // Async queries. Each is invoked on and completed on the main run loop.
    // Before any list has loaded, or for an allowlisted host, they complete with
    // the pass-through default without touching the engine.
    void checkRequest(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty, CompletionHandler<void(AdBlockEngine::CheckResult)>&&);
    void cspDirectives(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty, CompletionHandler<void(String)>&&);
    void cosmeticResourcesJSON(const String& url, const String& hostname, CompletionHandler<void(String)>&&);
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
    std::atomic<uint64_t> m_engineQueryCount { 0 };
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
