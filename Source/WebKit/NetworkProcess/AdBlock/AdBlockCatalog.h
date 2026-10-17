// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Parses the filter-list catalog published by brave/adblock-resources
// (`filter_lists/list_catalog.json`) into AdBlockCatalogEntry records. The
// catalog is the manifest of every filter list the browser offers: which are on
// by default, which are hidden from the UI, which apply to a locale or a
// platform, and — per entry — the ordered set of source URLs whose texts are
// concatenated to form that list.
//
// Brave delivers both the catalog and each list's text as signed CRX components
// (`component_id`/`base64_public_key` per entry). This fork has no component
// updater, so those two fields are parsed but unused: AdBlockListStore fetches
// each entry's `sources` directly over HTTPS instead. See
// docs/adblock_default_lists.md for the upstream behaviour this mirrors.
//
// A malformed catalog yields an empty vector, and a malformed entry is skipped,
// rather than failing: a bad catalog must degrade to "no lists offered", never
// break the session.

#pragma once

#if ENABLE(ADBLOCK)

#include <wtf/URL.h>
#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

// One catalog entry — a single user-facing filter list. Corresponds to an
// element of list_catalog.json; see the "Filter list description format"
// section of the adblock-resources README.
struct AdBlockCatalogEntry {
    // Stable identity, generated with `uuidgen` upstream (plus the literal
    // "default" for the always-on core list). This, not a URL, keys a catalog
    // list's persisted state, so the entry's sources can change upstream
    // without orphaning the user's choice.
    String uuid;
    String title;
    String description;
    // Locale codes (despite the upstream field being named `langs`) that should
    // preselect this list. Matched against the language part of the system
    // locale, as Brave's FindAdBlockFilterListsByLocale does.
    Vector<String> languages;
    // Not shown in the settings UI. A hidden entry that is also defaultEnabled
    // is force-on: the user has no way to express a preference about it.
    bool hidden { false };
    bool defaultEnabled { false };
    // Upstream routes these lists into a separate engine that applies
    // first-party heuristics. This fork compiles exactly one engine (KTD4), so
    // the flag is parsed and reported but does not yet change behaviour.
    bool firstPartyProtections { false };
    // Gates which scriptlets rules from this list may inject. Bit 0 marks
    // "trusted" uBlock Origin resources, bit 1 Brave-authored ones; 0 is the
    // most restrictive. Passed through to adblock-rust's ParseOptions.
    uint8_t permissionMask { 0 };
    // Upstream platform names (LINUX/WINDOWS/MAC/ANDROID/IOS). Empty == all.
    Vector<String> platforms;
    // Concatenated in this order to form the list text. All HTTPS upstream.
    Vector<URL> sources;
    // Where a user can report a problem with the list; taken from the first
    // source that declares one.
    String supportURL;

    // False when `platforms` is non-empty and excludes the platform this build
    // targets (the catalog's one IOS-only entry must not load on macOS).
    bool supportsCurrentPlatform() const;
    // True when `languages` contains the language part of `locale` ("en" for
    // "en-US"), matching Brave's locale preselection.
    bool matchesLocale(const String& locale) const;
};

// Parses the whole catalog document. Entries missing a uuid, a title, or any
// usable source are dropped.
Vector<AdBlockCatalogEntry> parseAdBlockCatalog(const String& json);

// The language part of a locale identifier, lowercased: "en-US" -> "en",
// "pt_BR" -> "pt". Exposed for the store's regional-preselection pass.
String adBlockLanguageCodeFromLocale(const String& locale);

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
