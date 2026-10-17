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
// It also owns the filter list catalog (U11): the manifest from
// brave/adblock-resources that says which lists exist, which are on by default,
// and which source URLs make up each one. Catalog lists live alongside
// subscriptions rather than inside them — see the "Filter list catalog" section
// below for why — and are the only lists compiled with a non-zero scriptlet
// permission mask.
//
// State lives under a base directory: `adblock-config.json` (subscription
// config + custom rules + allowlist + per-catalog-list state), one text file
// per subscription and per catalog list under `lists/`, and `adblock.dat` (the
// serialized engine). Downloads require HTTPS (AdBlockListDownloader) and, when
// a subscription pins an expected SHA-256, the bytes are verified before they
// replace the stored list (integrity follow-up).
//
// The store runs on the NetworkProcess main run loop; it is not thread-safe.

#pragma once

#if ENABLE(ADBLOCK)

#include "AdBlockCatalog.h"
#include <optional>
#include <pal/SessionID.h>
#include <wtf/CompletionHandler.h>
#include <wtf/HashMap.h>
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

    // Installs `text` as the stored list body for `url` directly, exactly as a
    // successful download would (registers the subscription if new, writes the
    // text under `lists/`, then persists + rebuilds), but bypasses the network
    // fetch, TLS validation, and content heuristics. This is the delivery seam
    // used by the API tests to exercise multi-list assembly, warm/cold `.dat`,
    // and persistence without a live download — the analogue of Brave's
    // `UpdateAdBlockInstanceWithRules` / `provider->OnComponentReady(path)`. The
    // downloader's own guards are covered separately, not through this path.
    void setSubscriptionListText(const URL&, const String& text);
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

    // --- Filter list catalog (U11) ---
    //
    // The catalog (brave/adblock-resources `filter_lists/list_catalog.json`) is
    // the manifest of lists the browser offers. It is reference data that can
    // change under us, so it is deliberately *not* persisted here and lives
    // alongside — not inside — m_subscriptions: only the user's per-list choice
    // and the downloaded list text are this store's to keep. Catalog lists are
    // compiled with their catalog-declared permission mask; user-added
    // subscriptions stay at the most-restrictive 0.

    // A catalog list as reported to the embedder API.
    struct CatalogListInfo {
        String uuid;
        String title;
        String description;
        String supportURL;
        Vector<String> languages;
        bool hidden { false };
        bool enabled { false };
        bool defaultEnabled { false };
        double lastFetched { 0 }; // WallTime seconds since epoch; 0 == never fetched.
    };

    // Installs the catalog document, re-resolves which lists should be enabled
    // (catalog defaults, one-time locale preselection, and any remembered user
    // choice), starts a download for every enabled list whose text is missing,
    // and rebuilds. Safe to call on every launch with a bundled snapshot and
    // again when a fresher catalog arrives.
    void setCatalog(const String& catalogJSON);
    Vector<CatalogListInfo> catalogLists() const;
    // Overrides the catalog default for one list and remembers that the user
    // chose, so a later catalog update will not undo it. Hidden lists have no UI
    // toggle and ignore this.
    void setCatalogListEnabled(const String& uuid, bool);
    // Re-downloads every enabled catalog list.
    void refreshCatalogLists();

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

    // What this store keeps for a catalog list, keyed by catalog uuid. The
    // catalog supplies everything else (title, sources, permission mask), so a
    // list can be re-pointed upstream without orphaning the user's choice.
    struct CatalogListState {
        bool enabled { false };
        // The user toggled this list explicitly, so catalog/locale defaults no
        // longer apply to it — Brave's `list_touched` gate.
        bool userTouched { false };
        double lastFetched { 0 };
    };

    Subscription* findSubscription(const URL&);
    const AdBlockCatalogEntry* findCatalogEntry(const String& uuid) const;

    // Resolves whether a catalog list should be compiled in: platform support
    // first, then a hidden+default list's force-on, then the user's remembered
    // choice, then the catalog default.
    bool isCatalogListEnabled(const AdBlockCatalogEntry&) const;
    // Seeds m_catalogState for lists this store has not seen before, applying
    // catalog defaults and — exactly once per profile, mirroring Brave's
    // kAdBlockCheckedAllDefaultRegions — preselecting lists matching the system
    // locale. Returns true if any state changed.
    bool applyCatalogDefaults();

    String catalogListFilename(const String& uuid) const;
    // Fetches `sources` in order, concatenating the bodies into one list text
    // (one catalog entry is one parse unit, exactly as its upstream CRX
    // component would be). Sources are fetched one at a time so the assembled
    // order is the catalog order; separate lists download concurrently. Any
    // failed source abandons the whole list and keeps the previously stored
    // text, rather than compiling a half-assembled list.
    void fetchCatalogSources(String uuid, Vector<URL>&& sources, size_t index, Vector<uint8_t>&& accumulated);
    void startCatalogListDownload(const AdBlockCatalogEntry&);
    void installCatalogListText(const String& uuid, std::span<const uint8_t>);

    String configPath() const;
    String cachePath() const;
    String listsDirectory() const;
    String listTextPath(const String& filename) const;

    void loadConfig();
    void persistConfig() const;

    void startDownload(const URL&, const String& expectedHash, CompletionHandler<void(bool)>&&);
    void handleDownload(const URL&, const String& expectedHash, std::optional<Vector<uint8_t>>&&, CompletionHandler<void(bool)>&&);

    // Stores `bytes` as `subscription`'s on-disk list body (lazily assigning a
    // hash-derived filename), stamps `lastFetched`, fills an empty title from the
    // list metadata, then persists config and schedules a rebuild. Shared by the
    // download-completion path (`handleDownload`) and the direct-injection testing
    // seam (`setSubscriptionListText`) so the two cannot drift. Returns false only
    // on a disk-write failure.
    bool installListText(Subscription&, std::span<const uint8_t> bytes);

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

    Vector<AdBlockCatalogEntry> m_catalog;
    HashMap<String, CatalogListState> m_catalogState;
    // SHA-256 of the catalog document the persisted state was derived from, so
    // the embedder re-sending the same bundled catalog on every launch is
    // recognised as a no-op instead of forcing a recompile past the warm cache.
    String m_catalogFingerprint;

    bool m_enabled { false };
    bool m_rebuildScheduled { false };
    bool m_didPreselectRegionalLists { false };
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
