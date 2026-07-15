// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockManager.h.

#include "config.h"
#include "AdBlockManager.h"

#if ENABLE(ADBLOCK)

#include <algorithm>
#include <array>
#include <wtf/Assertions.h>
#include <wtf/FileSystem.h>
#include <wtf/RunLoop.h>
#include <wtf/StdLibExtras.h>

namespace WebKit {

// On-disk `.dat` cache framing. The magic + version byte let the loader reject a
// cache written by an incompatible adblock-rust version (bump cacheFormatVersion
// whenever the pinned engine's serialization format changes) and the size cap
// bounds how much untrusted data is read/deserialized in the NetworkProcess.
static constexpr std::array<uint8_t, 4> cacheMagic { { 'W', 'K', 'A', 'B' } };
static constexpr uint8_t cacheFormatVersion = 1;
static constexpr size_t cacheHeaderSize = cacheMagic.size() + 1;
static constexpr size_t maxCacheFileSize = 256 * MB;

static Vector<String> isolatedCopyStrings(const Vector<String>& strings)
{
    return strings.map([](auto& string) { return string.isolatedCopy(); });
}

Ref<AdBlockManager> AdBlockManager::create()
{
    return adoptRef(*new AdBlockManager());
}

AdBlockManager::AdBlockManager()
    : m_queue(WorkQueue::create("com.webkit.AdBlock"_s))
{
}

AdBlockManager::~AdBlockManager() = default;

void AdBlockManager::setEngine(Ref<AdBlockEngine>&& engine)
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, engine = WTF::move(engine)]() mutable {
        m_engine = WTF::move(engine);
    });
}

void AdBlockManager::setEngineFromRules(Vector<uint8_t>&& rules, CompletionHandler<void()>&& completion)
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, rules = WTF::move(rules), completion = WTF::move(completion)]() mutable {
        m_engine = AdBlockEngine::createFromRules(rules.span());
        RunLoop::mainSingleton().dispatch(WTF::move(completion));
    });
}

Vector<uint8_t> AdBlockManager::encodeCache(std::span<const uint8_t> payload)
{
    Vector<uint8_t> encoded;
    encoded.reserveInitialCapacity(cacheHeaderSize + payload.size());
    encoded.append(std::span<const uint8_t> { cacheMagic });
    encoded.append(cacheFormatVersion);
    encoded.append(payload);
    return encoded;
}

bool AdBlockManager::loadCacheOnQueue(const String& path)
{
    auto size = FileSystem::fileSize(path);
    if (!size || *size < cacheHeaderSize || *size > maxCacheFileSize) {
        WTFLogAlways("AdBlockManager: cache file missing or size out of bounds; re-parsing source lists");
        return false;
    }

    auto contents = FileSystem::readEntireFile(path);
    if (!contents) {
        WTFLogAlways("AdBlockManager: cache file could not be read; re-parsing source lists");
        return false;
    }

    auto bytes = contents->span();
    if (bytes.size() < cacheHeaderSize || bytes.size() > maxCacheFileSize) {
        WTFLogAlways("AdBlockManager: cache file size out of bounds after read; re-parsing source lists");
        return false;
    }
    if (!std::equal(cacheMagic.begin(), cacheMagic.end(), bytes.begin())) {
        WTFLogAlways("AdBlockManager: cache file magic mismatch; re-parsing source lists");
        return false;
    }
    if (bytes[cacheMagic.size()] != cacheFormatVersion) {
        WTFLogAlways("AdBlockManager: cache format version mismatch; re-parsing source lists");
        return false;
    }

    auto engine = AdBlockEngine::createFromSerializedPayload(bytes.subspan(cacheHeaderSize));
    if (!engine) {
        WTFLogAlways("AdBlockManager: cache payload failed to deserialize; re-parsing source lists");
        return false;
    }

    m_engine = WTF::move(engine);
    return true;
}

void AdBlockManager::loadCacheFile(const String& path, CompletionHandler<void(bool)>&& completion)
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, path = path.isolatedCopy(), completion = WTF::move(completion)]() mutable {
        bool didLoad = loadCacheOnQueue(path);
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion), didLoad]() mutable {
            completion(didLoad);
        });
    });
}

void AdBlockManager::saveCacheFile(const String& path, CompletionHandler<void(bool)>&& completion)
{
    m_queue->dispatch([this, protectedThis = Ref { *this }, path = path.isolatedCopy(), completion = WTF::move(completion)]() mutable {
        bool didSave = false;
        if (RefPtr engine = m_engine) {
            auto encoded = encodeCache(engine->serialize().span());
            didSave = FileSystem::overwriteEntireFile(path, encoded.span()).has_value();
            if (!didSave)
                WTFLogAlways("AdBlockManager: failed to write cache file");
        }
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion), didSave]() mutable {
            completion(didSave);
        });
    });
}

void AdBlockManager::setAllowlistedHosts(HashSet<String>&& hosts)
{
    HashSet<String> isolated;
    isolated.reserveInitialCapacity(hosts.size());
    for (auto& host : hosts)
        isolated.add(host.isolatedCopy());

    Locker locker { m_allowlistLock };
    m_allowlist = WTF::move(isolated);
}

void AdBlockManager::addAllowlistedHost(const String& host)
{
    Locker locker { m_allowlistLock };
    m_allowlist.add(host.isolatedCopy());
}

void AdBlockManager::removeAllowlistedHost(const String& host)
{
    Locker locker { m_allowlistLock };
    m_allowlist.remove(host);
}

bool AdBlockManager::isAllowlistedHost(const String& host) const
{
    Locker locker { m_allowlistLock };
    return m_allowlist.contains(host);
}

void AdBlockManager::checkRequest(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty, CompletionHandler<void(AdBlockEngine::CheckResult)>&& completion)
{
    if (isAllowlistedHost(hostname)) {
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion)]() mutable {
            completion(AdBlockEngine::CheckResult { });
        });
        return;
    }

    m_queue->dispatch([this, protectedThis = Ref { *this }, url = url.isolatedCopy(), hostname = hostname.isolatedCopy(), sourceHostname = sourceHostname.isolatedCopy(), requestType = requestType.isolatedCopy(), isThirdParty, completion = WTF::move(completion)]() mutable {
        AdBlockEngine::CheckResult result;
        if (RefPtr engine = m_engine) {
            m_engineQueryCount.fetch_add(1, std::memory_order_relaxed);
            result = engine->checkRequest(url, hostname, sourceHostname, requestType, isThirdParty);
            result.redirect = result.redirect.isolatedCopy();
        }
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion), result = WTF::move(result)]() mutable {
            completion(WTF::move(result));
        });
    });
}

void AdBlockManager::cspDirectives(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty, CompletionHandler<void(String)>&& completion)
{
    if (isAllowlistedHost(hostname)) {
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion)]() mutable {
            completion(String { });
        });
        return;
    }

    m_queue->dispatch([this, protectedThis = Ref { *this }, url = url.isolatedCopy(), hostname = hostname.isolatedCopy(), sourceHostname = sourceHostname.isolatedCopy(), requestType = requestType.isolatedCopy(), isThirdParty, completion = WTF::move(completion)]() mutable {
        String directives;
        if (RefPtr engine = m_engine) {
            m_engineQueryCount.fetch_add(1, std::memory_order_relaxed);
            directives = engine->cspDirectives(url, hostname, sourceHostname, requestType, isThirdParty).isolatedCopy();
        }
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion), directives = WTF::move(directives)]() mutable {
            completion(WTF::move(directives));
        });
    });
}

void AdBlockManager::cosmeticResourcesJSON(const String& url, const String& hostname, CompletionHandler<void(String)>&& completion)
{
    if (isAllowlistedHost(hostname)) {
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion)]() mutable {
            completion(String { });
        });
        return;
    }

    m_queue->dispatch([this, protectedThis = Ref { *this }, url = url.isolatedCopy(), completion = WTF::move(completion)]() mutable {
        String json;
        if (RefPtr engine = m_engine) {
            m_engineQueryCount.fetch_add(1, std::memory_order_relaxed);
            json = engine->cosmeticResourcesJSON(url).isolatedCopy();
        }
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion), json = WTF::move(json)]() mutable {
            completion(WTF::move(json));
        });
    });
}

void AdBlockManager::hiddenClassIdSelectors(Vector<String>&& classes, Vector<String>&& ids, Vector<String>&& exceptions, const String& hostname, CompletionHandler<void(Vector<String>)>&& completion)
{
    if (isAllowlistedHost(hostname)) {
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion)]() mutable {
            completion(Vector<String> { });
        });
        return;
    }

    m_queue->dispatch([this, protectedThis = Ref { *this }, classes = isolatedCopyStrings(classes), ids = isolatedCopyStrings(ids), exceptions = isolatedCopyStrings(exceptions), completion = WTF::move(completion)]() mutable {
        Vector<String> selectors;
        if (RefPtr engine = m_engine) {
            m_engineQueryCount.fetch_add(1, std::memory_order_relaxed);
            selectors = isolatedCopyStrings(engine->hiddenClassIdSelectors(classes, ids, exceptions));
        }
        RunLoop::mainSingleton().dispatch([completion = WTF::move(completion), selectors = WTF::move(selectors)]() mutable {
            completion(WTF::move(selectors));
        });
    });
}

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
