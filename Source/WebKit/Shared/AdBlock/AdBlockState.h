// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// AdBlockState is a snapshot of one data store's adblock config, built by
// AdBlockListStore::state() in the NetworkProcess and sent to the UIProcess in
// reply to NetworkProcess::GetAdBlockState, where _WKAdBlockState wraps it for
// the embedder API.

#pragma once

#if ENABLE(ADBLOCK)

#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

// A filter list the embedder added by URL.
struct AdBlockSubscriptionState {
    URL url;
    bool enabled { true };
    // The list's `! Title:` header; empty if it has none or was never fetched.
    String title;
    double lastFetched { 0 }; // WallTime seconds since epoch; 0 == never fetched.
};

// A list from the filter list catalog.
struct AdBlockCatalogListState {
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

struct AdBlockState {
    bool enabled { false };
    String customRules;
    Vector<String> allowlist;
    Vector<AdBlockSubscriptionState> subscriptions;
    Vector<AdBlockCatalogListState> catalogLists;
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
