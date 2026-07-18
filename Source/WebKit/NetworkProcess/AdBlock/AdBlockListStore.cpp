// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockListStore.h.

#include "config.h"
#include "AdBlockListStore.h"

#if ENABLE(ADBLOCK)

#include "AdBlockEngine.h"
#include "AdBlockListDownloader.h"
#include "AdBlockManager.h"
#include "Logging.h"
#include "NetworkProcess.h"
#include <pal/crypto/CryptoDigest.h>
#include <wtf/FileSystem.h>
#include <wtf/JSONValues.h>
#include <wtf/RunLoop.h>
#include <wtf/StdLibExtras.h>
#include <wtf/WallTime.h>
#include <wtf/text/MakeString.h>

namespace WebKit {

static constexpr unsigned configFormatVersion = 1;

// Lists are compiled with the most-restrictive scriptlet permission mask (0);
// nothing in this store designates a subscription as trusted, so no list may
// inject privileged scriptlets (U7 security posture).
static constexpr uint8_t restrictivePermissionMask = 0;

static String sha256Hex(std::span<const uint8_t> bytes)
{
    auto digest = PAL::Crypto::CryptoDigest::create(PAL::Crypto::CryptoDigest::Algorithm::SHA_256);
    digest->addBytes(bytes);
    return digest->toHexString();
}

// A 200 response that is an HTML error page rather than ABP text parses to
// near-zero rules; treat anything whose first non-whitespace byte opens a tag as
// not-a-filter-list and reject it (the test-scenario "HTML error page" guard).
static bool looksLikeFilterList(std::span<const uint8_t> bytes)
{
    for (auto byte : bytes) {
        if (byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n')
            continue;
        return byte != '<';
    }
    return false;
}

// A subscription's list-text filename is generated internally as
// "<sha256-hex>.txt" and joined onto lists/ for reads and deletes. The value is
// also persisted in (and read back from) adblock-config.json, so a tampered
// config could carry a path-traversal filename; reject any component that could
// escape lists/ before it ever reaches the filesystem.
static bool isSafeListFilename(const String& filename)
{
    return filename != "."_s && filename != ".."_s && !filename.contains('/') && !filename.contains('\\');
}

static Vector<uint8_t> utf8Bytes(const String& string)
{
    auto utf8 = string.utf8();
    Vector<uint8_t> bytes;
    bytes.append(byteCast<uint8_t>(utf8.span()));
    return bytes;
}

Ref<AdBlockListStore> AdBlockListStore::create(NetworkProcess& networkProcess, PAL::SessionID sessionID, const String& directory)
{
    return adoptRef(*new AdBlockListStore(networkProcess, sessionID, directory));
}

AdBlockListStore::AdBlockListStore(NetworkProcess& networkProcess, PAL::SessionID sessionID, const String& directory)
    : m_networkProcess(networkProcess)
    , m_sessionID(sessionID)
    , m_directory(directory)
{
}

AdBlockListStore::~AdBlockListStore() = default;

String AdBlockListStore::configPath() const
{
    return FileSystem::pathByAppendingComponent(m_directory, "adblock-config.json"_s);
}

String AdBlockListStore::cachePath() const
{
    return FileSystem::pathByAppendingComponent(m_directory, "adblock.dat"_s);
}

String AdBlockListStore::listsDirectory() const
{
    return FileSystem::pathByAppendingComponent(m_directory, "lists"_s);
}

String AdBlockListStore::listTextPath(const String& filename) const
{
    return FileSystem::pathByAppendingComponent(listsDirectory(), filename);
}

auto AdBlockListStore::findSubscription(const URL& url) -> Subscription*
{
    for (auto& sub : m_subscriptions) {
        if (sub.url == url)
            return &sub;
    }
    return nullptr;
}

void AdBlockListStore::loadConfig()
{
    m_subscriptions.clear();
    m_customRules = String { };
    m_allowlist.clear();
    m_enabled = false;

    auto contents = FileSystem::readEntireFile(configPath());
    if (!contents)
        return;

    RefPtr value = JSON::Value::parseJSON(String::fromUTF8(byteCast<char8_t>(contents->span())));
    RefPtr root = value ? value->asObject() : nullptr;
    if (!root) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListStore: config file is not valid JSON; starting empty");
        return;
    }

    m_enabled = root->getBoolean("enabled"_s).value_or(false);
    m_customRules = root->getString("customRules"_s);

    if (RefPtr allowlist = root->getArray("allowlist"_s)) {
        for (auto& host : *allowlist) {
            auto string = host->asString();
            if (!string.isEmpty())
                m_allowlist.add(WTF::move(string));
        }
    }

    if (RefPtr subs = root->getArray("subscriptions"_s)) {
        for (auto& entry : *subs) {
            RefPtr object = entry->asObject();
            if (!object)
                continue;
            auto urlString = object->getString("url"_s);
            URL url { urlString };
            if (!url.isValid())
                continue;
            Subscription sub;
            sub.url = WTF::move(url);
            sub.enabled = object->getBoolean("enabled"_s).value_or(true);
            sub.title = object->getString("title"_s);
            sub.lastFetched = object->getDouble("lastFetched"_s).value_or(0);
            sub.expectedHash = object->getString("expectedHash"_s);
            auto filename = object->getString("filename"_s);
            if (!filename.isEmpty() && !isSafeListFilename(filename)) {
                RELEASE_LOG_ERROR(AdBlock, "AdBlockListStore: rejecting unsafe list filename from config; the list will be re-downloaded");
                filename = String { };
            }
            sub.filename = WTF::move(filename);
            m_subscriptions.append(WTF::move(sub));
        }
    }
}

void AdBlockListStore::persistConfig() const
{
    auto root = JSON::Object::create();
    root->setInteger("version"_s, configFormatVersion);
    root->setBoolean("enabled"_s, m_enabled);
    root->setString("customRules"_s, m_customRules);

    auto allowlist = JSON::Array::create();
    for (auto& host : m_allowlist)
        allowlist->pushString(host);
    root->setArray("allowlist"_s, WTF::move(allowlist));

    auto subs = JSON::Array::create();
    for (auto& sub : m_subscriptions) {
        auto object = JSON::Object::create();
        object->setString("url"_s, sub.url.string());
        object->setBoolean("enabled"_s, sub.enabled);
        object->setString("title"_s, sub.title);
        object->setDouble("lastFetched"_s, sub.lastFetched);
        object->setString("expectedHash"_s, sub.expectedHash);
        object->setString("filename"_s, sub.filename);
        subs->pushObject(WTF::move(object));
    }
    root->setArray("subscriptions"_s, WTF::move(subs));

    FileSystem::makeAllDirectories(m_directory);
    auto json = root->toJSONString().utf8();
    if (!FileSystem::overwriteEntireFile(configPath(), byteCast<uint8_t>(json.span())))
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListStore: failed to write config file");
}

void AdBlockListStore::load(CompletionHandler<void()>&& completion)
{
    loadConfig();

    Ref networkProcess { m_networkProcess.get() };
    Ref manager { networkProcess->adBlockManager() };
    manager->setAllowlistedHosts(HashSet<String> { m_allowlist });
    manager->setEnabled(m_enabled);

    // Warm `.dat` fast path: an intact cache restores the last compiled engine
    // without re-parsing (R7). Any failure (missing/corrupt/version-mismatched)
    // falls back to re-parsing the stored list texts.
    manager->loadCacheFile(cachePath(), [protectedThis = Ref { *this }, completion = WTF::move(completion)](bool didLoad) mutable {
        if (!didLoad)
            protectedThis->rebuildEngine();
        completion();
    });
}

void AdBlockListStore::startDownload(const URL& url, const String& expectedHash, CompletionHandler<void(bool)>&& completion)
{
    if (!url.protocolIs("https"_s)) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListStore: refusing non-HTTPS subscription URL");
        completion(false);
        return;
    }

    Ref networkProcess { m_networkProcess.get() };
    AdBlockListDownloader::create(networkProcess, m_sessionID, url, [protectedThis = Ref { *this }, url, expectedHash, completion = WTF::move(completion)](std::optional<Vector<uint8_t>>&& result) mutable {
        protectedThis->handleDownload(url, expectedHash, WTF::move(result), WTF::move(completion));
    });
}

void AdBlockListStore::handleDownload(const URL& url, const String& expectedHash, std::optional<Vector<uint8_t>>&& result, CompletionHandler<void(bool)>&& completion)
{
    if (!result || result->isEmpty() || !looksLikeFilterList(result->span())) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListStore: subscription download failed or was not a filter list; keeping any previous text");
        completion(false);
        return;
    }

    if (!expectedHash.isEmpty() && !equalIgnoringASCIICase(sha256Hex(result->span()), expectedHash)) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListStore: subscription integrity hash mismatch; rejecting download");
        completion(false);
        return;
    }

    auto* subscription = findSubscription(url);
    if (!subscription) {
        // Removed while the download was in flight.
        completion(false);
        return;
    }

    if (subscription->filename.isEmpty())
        subscription->filename = makeString(sha256Hex(utf8Bytes(url.string()).span()), ".txt"_s);

    FileSystem::makeAllDirectories(listsDirectory());
    if (!FileSystem::overwriteEntireFile(listTextPath(subscription->filename), result->span())) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListStore: failed to write downloaded list text");
        completion(false);
        return;
    }

    subscription->lastFetched = WallTime::now().secondsSinceEpoch().value();
    if (subscription->title.isEmpty()) {
        auto metadata = AdBlockEngine::readListMetadata(result->span());
        if (!metadata.title.isEmpty())
            subscription->title = metadata.title;
    }

    persistConfig();
    scheduleRebuild();
    completion(true);
}

void AdBlockListStore::addSubscription(const URL& url, const String& expectedHash, CompletionHandler<void(bool)>&& completion)
{
    if (auto* existing = findSubscription(url))
        existing->expectedHash = expectedHash;
    else {
        Subscription sub;
        sub.url = url;
        sub.expectedHash = expectedHash;
        m_subscriptions.append(WTF::move(sub));
    }
    persistConfig();
    startDownload(url, expectedHash, WTF::move(completion));
}

void AdBlockListStore::removeSubscription(const URL& url)
{
    bool removed = m_subscriptions.removeAllMatching([&](auto& sub) {
        if (sub.url != url)
            return false;
        if (!sub.filename.isEmpty())
            FileSystem::deleteFile(listTextPath(sub.filename));
        return true;
    });
    if (!removed)
        return;
    persistConfig();
    scheduleRebuild();
}

void AdBlockListStore::setSubscriptionEnabled(const URL& url, bool enabled)
{
    auto* subscription = findSubscription(url);
    if (!subscription || subscription->enabled == enabled)
        return;
    subscription->enabled = enabled;
    persistConfig();
    scheduleRebuild();
}

void AdBlockListStore::refreshSubscription(const URL& url, CompletionHandler<void(bool)>&& completion)
{
    auto* subscription = findSubscription(url);
    if (!subscription) {
        completion(false);
        return;
    }
    startDownload(url, subscription->expectedHash, WTF::move(completion));
}

void AdBlockListStore::refreshAllSubscriptions()
{
    auto urls = m_subscriptions.map([](auto& sub) {
        return sub.url;
    });
    for (auto& url : urls)
        refreshSubscription(url, [](bool) { });
}

Vector<AdBlockListStore::SubscriptionInfo> AdBlockListStore::subscriptions() const
{
    return m_subscriptions.map([](auto& sub) {
        return SubscriptionInfo { sub.url.string(), sub.enabled, sub.title, sub.lastFetched };
    });
}

void AdBlockListStore::setCustomRules(const String& rules)
{
    if (m_customRules == rules)
        return;
    m_customRules = rules;
    persistConfig();
    scheduleRebuild();
}

void AdBlockListStore::setAllowlistedHosts(HashSet<String>&& hosts)
{
    m_allowlist = WTF::move(hosts);
    persistConfig();
    Ref { m_networkProcess.get() }->adBlockManager().setAllowlistedHosts(HashSet<String> { m_allowlist });
}

void AdBlockListStore::addAllowlistedHost(const String& host)
{
    if (!m_allowlist.add(host).isNewEntry)
        return;
    persistConfig();
    Ref { m_networkProcess.get() }->adBlockManager().addAllowlistedHost(host);
}

void AdBlockListStore::removeAllowlistedHost(const String& host)
{
    if (!m_allowlist.remove(host))
        return;
    persistConfig();
    Ref { m_networkProcess.get() }->adBlockManager().removeAllowlistedHost(host);
}

Vector<String> AdBlockListStore::allowlistedHosts() const
{
    return copyToVector(m_allowlist);
}

void AdBlockListStore::setResources(String resourcesJSON)
{
    m_resourcesJSON = WTF::move(resourcesJSON);
}

void AdBlockListStore::setEnabled(bool enabled)
{
    // Always re-assert the manager's query gate. The AdBlockManager is
    // process-global (KTD3: one engine per NetworkProcess, shared across data
    // stores), so another session may have flipped it since this store last set
    // it — a bare `m_enabled == enabled` early-return could otherwise leave the
    // shared gate stale (this store thinks it is enabled while the gate is off).
    // The compiled engine stays warm; only the gate flips.
    Ref { m_networkProcess.get() }->adBlockManager().setEnabled(enabled);

    // Persist only when this store's own value actually changed.
    if (m_enabled == enabled)
        return;
    m_enabled = enabled;
    persistConfig();
}

String AdBlockListStore::stateJSON() const
{
    auto root = JSON::Object::create();
    root->setBoolean("enabled"_s, m_enabled);
    root->setString("customRules"_s, m_customRules);

    auto allowlist = JSON::Array::create();
    for (auto& host : m_allowlist)
        allowlist->pushString(host);
    root->setArray("allowlist"_s, WTF::move(allowlist));

    auto subs = JSON::Array::create();
    for (auto& sub : m_subscriptions) {
        auto object = JSON::Object::create();
        object->setString("url"_s, sub.url.string());
        object->setBoolean("enabled"_s, sub.enabled);
        object->setString("title"_s, sub.title);
        object->setDouble("lastFetched"_s, sub.lastFetched);
        subs->pushObject(WTF::move(object));
    }
    root->setArray("subscriptions"_s, WTF::move(subs));

    return root->toJSONString();
}

void AdBlockListStore::scheduleRebuild()
{
    if (m_rebuildScheduled)
        return;
    m_rebuildScheduled = true;
    RunLoop::mainSingleton().dispatch([protectedThis = Ref { *this }] {
        protectedThis->rebuildEngine();
    });
}

void AdBlockListStore::rebuildEngine()
{
    m_rebuildScheduled = false;

    // Gather the enabled lists' file paths here (cheap); the manager reads their
    // texts on its WorkQueue so the multi-MB reads never block the main run loop.
    Vector<AdBlockManager::ListFileInput> files;
    files.reserveInitialCapacity(m_subscriptions.size());
    for (auto& sub : m_subscriptions) {
        if (!sub.enabled || sub.filename.isEmpty())
            continue;
        files.append({ listTextPath(sub.filename), restrictivePermissionMask });
    }

    // Custom rules are already in memory (a small user-authored blob), so pass
    // them inline rather than through a file read.
    Vector<AdBlockEngine::ListInput> inlineLists;
    if (!m_customRules.isEmpty())
        inlineLists.append({ utf8Bytes(m_customRules), restrictivePermissionMask });

    Ref manager { Ref { m_networkProcess.get() }->adBlockManager() };
    // Compile-and-swap on the WorkQueue, then re-serialize the `.dat` so the warm
    // cache always matches the last compiled enabled set (KTD4, R7).
    manager->setEngineFromListFiles(WTF::move(files), WTF::move(inlineLists), m_resourcesJSON, [manager, cachePath = cachePath()]() mutable {
        manager->saveCacheFile(cachePath, [](bool) { });
    });
}

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
