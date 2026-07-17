// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Parses adblock-rust's url_cosmetic_resources JSON (returned as an opaque
// string by AdBlockEngine::cosmeticResourcesJSON, per KTD — C++ owns the parse)
// into the cross-process AdBlockCosmeticResources struct. Runs on the
// NetworkProcess work queue alongside the engine query (U6: the parse must not
// land on the main thread at commit time, where a large rule set would blow the
// pre-first-paint budget R3 depends on).

#pragma once

#if ENABLE(ADBLOCK)

#include "Shared/AdBlock/AdBlockCosmeticResources.h"
#include <wtf/text/WTFString.h>

namespace WebKit {

namespace AdBlock {

// Parses the JSON emitted by adblock-rust's UrlSpecificResources serialization
// (fields hide_selectors, exceptions, injected_script, generichide). Malformed
// or empty JSON yields an empty, do-nothing result rather than an error — a
// parse failure must never block or corrupt the navigation.
AdBlockCosmeticResources parseCosmeticResources(const String& json);

} // namespace AdBlock

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
