// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// AdBlockListStore owns the filter-list lifecycle behind an internal API (the
// U10 embedder API drives it): subscriptions (add/remove/toggle), custom user
// rules, list downloads, the per-site allowlist, and disk persistence. Any
// change rebuilds one engine (KTD4) from all enabled list texts + custom rules
// off the main thread on AdBlockManager's WorkQueue, atomically swaps it in, and
// re-serializes the `.dat` cache. At startup it restores from the warm `.dat`
// cache when valid and re-parses source lists otherwise (R7).
//
// State lives under a base directory: `adblock-config.json` (subscription
// config + custom rules + allowlist), one text file per subscription under
// `lists/`, and `adblock.dat` (the serialized engine). Downloads require HTTPS
// (AdBlockListDownloader) and, when a subscription pins an expected SHA-256, the
// bytes are verified before they replace the stored list (integrity follow-up).
//
// The store runs on the NetworkProcess main run loop; it is not thread-safe.

#pragma once

#if ENABLE(ADBLOCK)

#include <optional>
#include <pal/SessionID.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashSet.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/WeakRef.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

class NetworkProcess;

class AdBlockListStore : public RefCounted<AdBlockListStore> {
public:
    static Ref<AdBlockListStore> create(NetworkProcess&, PAL::SessionID, const String& directory);
    ~AdBlockListStore();

    // A subscription's persisted state, as read back by the embedder API.
    struct SubscriptionInfo {
        String url;
        bool enabled { true };
        String title;
        double lastFetched { 0 }; // WallTime seconds since epoch; 0 == never fetched.
    };

    // Reads persisted config, pushes the allowlist + master enable state to the
    // manager, and restores the engine: warm `.dat` fast path, else re-parse the
    // stored list texts.
    void load(CompletionHandler<void()>&& = [] { });

    // Master enable gate (persisted, mirrored into the manager). Off by default;
    // toggling keeps the compiled engine warm (AdBlockManager::setEnabled).
    void setEnabled(bool);
    bool enabled() const { return m_enabled; }

    // A JSON snapshot of the whole config for the embedder API read-back
    // (subscriptions, allowlist, custom rules, enable state), so a re-instantiated
    // data store can read persisted state straight from the loaded store without a
    // new serializable IPC type.
    String stateJSON() const;

    // Downloads the list over HTTPS, verifies it against the pinned hash (if any),
    // stores its text, and rebuilds. completion(false) on any download/verify
    // failure — the previous list text (if any) is retained (KTD7).
    void addSubscription(const URL&, const String& expectedHash, CompletionHandler<void(bool)>&& = [](bool) { });
    void removeSubscription(const URL&);
    void setSubscriptionEnabled(const URL&, bool);
    void refreshSubscription(const URL&, CompletionHandler<void(bool)>&& = [](bool) { });
    void refreshAllSubscriptions();
    Vector<SubscriptionInfo> subscriptions() const;

    // Custom user rules — one ABP-syntax blob compiled alongside the lists.
    void setCustomRules(const String&);
    String customRules() const { return m_customRules; }

    // Per-site allowlist (R8). Persisted here and mirrored into the manager's
    // runtime host set.
    void setAllowlistedHosts(HashSet<String>&&);
    void addAllowlistedHost(const String&);
    void removeAllowlistedHost(const String&);
    Vector<String> allowlistedHosts() const;

    // The scriptlet/redirect resource library (uBO resources JSON), supplied by
    // the embedder/bundle and baked into the engine at build time. Kept in memory
    // (the warm `.dat` already carries it); re-supply before load() on cold start.
    void setResources(String resourcesJSON);

private:
    AdBlockListStore(NetworkProcess&, PAL::SessionID, const String& directory);

    struct Subscription {
        URL url;
        bool enabled { true };
        String title;
        double lastFetched { 0 };
        String expectedHash; // Pinned lowercase-hex SHA-256; empty == unpinned.
        String filename; // List text file under `lists/`.
    };

    Subscription* findSubscription(const URL&);

    String configPath() const;
    String cachePath() const;
    String listsDirectory() const;
    String listTextPath(const String& filename) const;

    void loadConfig();
    void persistConfig() const;

    void startDownload(const URL&, const String& expectedHash, CompletionHandler<void(bool)>&&);
    void handleDownload(const URL&, const String& expectedHash, std::optional<Vector<uint8_t>>&&, CompletionHandler<void(bool)>&&);

    // Coalesces a burst of config changes into a single compile-and-swap on the
    // next run-loop turn.
    void scheduleRebuild();
    void rebuildEngine();

    const WeakRef<NetworkProcess> m_networkProcess;
    const PAL::SessionID m_sessionID;
    const String m_directory;

    Vector<Subscription> m_subscriptions;
    String m_customRules;
    HashSet<String> m_allowlist;
    String m_resourcesJSON;

    bool m_enabled { false };
    bool m_rebuildScheduled { false };
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
