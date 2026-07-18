// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// AdBlockEngine wraps the cxx-bridged adblock-rust Engine (Source/ThirdParty/
// AdblockRust) behind a ThreadSafeRefCounted C++ type. The rust Engine is not
// Send+Sync under the single-thread feature (KTD3), so instances must be used
// from a single work queue; AdBlockManager owns that confinement. This header
// stays free of the generated FFI header — the rust::Box lives in an opaque
// holder defined in the .cpp — so it can be included cheaply (and by tests).

#pragma once

#if ENABLE(ADBLOCK)

#include <memory>
#include <optional>
#include <span>
#include <wtf/Ref.h>
#include <wtf/RefPtr.h>
#include <wtf/ThreadSafeRefCounted.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

struct AdBlockEngineHolder;

class AdBlockEngine : public ThreadSafeRefCounted<AdBlockEngine> {
public:
    struct CheckResult {
        bool isMatched { false };
        bool isImportant { false };
        bool hasException { false };
        // Null unless the matched rule redirects to a bundled resource.
        String redirect;
    };

    // One filter list's text plus the permission mask that gates which scriptlets
    // it may inject (0 == most-restrictive; untrusted subscriptions stay at 0).
    struct ListInput {
        Vector<uint8_t> text;
        uint8_t permissionMask { 0 };
    };

    // Homepage/title/expiry parsed from a list's `! ...` metadata header.
    struct ListMetadata {
        String homepage;
        String title;
        std::optional<uint16_t> expiresHours;
    };

    // An empty, pass-through engine (matches nothing) — the safe default before
    // any filter list has loaded.
    static Ref<AdBlockEngine> create();
    // Compiles a single ABP filter list; a malformed list degrades to an empty
    // engine rather than failing (KTD7).
    static Ref<AdBlockEngine> createFromRules(std::span<const uint8_t> filterListText);
    // Assembles one engine from all enabled lists (KTD4) via a filter set, then
    // loads the scriptlet/redirect resource library (uBO resources JSON; empty ⇒
    // none). Malformed lists or a failed assembly degrade to an empty engine
    // rather than failing (KTD7).
    static Ref<AdBlockEngine> createFromLists(const Vector<ListInput>&, const String& resourcesJSON);
    // Parses a list's metadata header without compiling it — used to title a
    // freshly downloaded subscription.
    static ListMetadata readListMetadata(std::span<const uint8_t> filterListText);
    // Restores an engine from an adblock-rust `.dat` payload. Returns nullptr if
    // the payload is recoverably corrupt or from an incompatible engine version,
    // so the caller can fall back to re-parsing source lists. Note: under
    // panic=abort (KTD7) a payload that trips a panic inside adblock-rust aborts
    // the process rather than returning nullptr.
    static RefPtr<AdBlockEngine> createFromSerializedPayload(std::span<const uint8_t> serialized);

    ~AdBlockEngine();

    CheckResult checkRequest(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty) const;
    String cspDirectives(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty) const;
    String cosmeticResourcesJSON(const String& url) const;
    Vector<String> hiddenClassIdSelectors(const Vector<String>& classes, const Vector<String>& ids, const Vector<String>& exceptions) const;
    Vector<uint8_t> serialize() const;

private:
    explicit AdBlockEngine(std::unique_ptr<AdBlockEngineHolder>&&);

    std::unique_ptr<AdBlockEngineHolder> m_holder;
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
