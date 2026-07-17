// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Request-side glue for the U4 network-blocking and U5 CSP-injection hooks. It
// keeps all adblock logic — mapping a fetch destination to adblock-rust's
// request-type string, computing the tab (source) host and third-party flag,
// translating an engine CheckResult into a block/allow verdict, and fetching a
// navigation's CSP directives — out of the core NetworkProcess load path, so the
// hook sites (NetworkLoadChecker, NetworkResourceLoader, NetworkSocketChannel)
// stay surgical (R9). The async checks route through NetworkProcess's
// AdBlockManager (KTD3), which short-circuits allowlisted hosts and pass-through
// defaults before any list has loaded.

#pragma once

#if ENABLE(ADBLOCK)

#include "Shared/AdBlock/AdBlockCosmeticResources.h"
#include <WebCore/FetchOptionsDestination.h>
#include <wtf/CompletionHandler.h>
#include <wtf/text/ASCIILiteral.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class ResourceRequest;
class ResourceResponse;
class SecurityOrigin;
class SecurityOriginData;
}

namespace WebKit {

class NetworkProcess;

namespace AdBlock {

// The adblock-rust filter-option string for a fetch destination (KTD, mirrors
// Brave's ResourceTypeToString). Unknown/rare destinations fall back to "other",
// which the engine already treats as the catch-all type.
ASCIILiteral requestTypeForDestination(WebCore::FetchOptionsDestination);

// Async subresource/subframe block check plus navigation CSP and cosmetic fetch
// (U4 + U5 + U6). The request is moved in and handed back to the completion, so a
// single move covers the engine queries and the caller's continuation
// (blocked == true => cancel the load). Never blocks a top-level (main-frame)
// navigation. Pass-through — blocked == false — when no list has loaded or the
// host is allowlisted (AdBlockManager decides). For document/subdocument requests
// the completion also carries the engine's CSP directives (R2), applied to the
// response via mergeCSPDirectives, and the cosmetic resources (R3), delivered to
// the web process with the response; both are empty for other destinations.
void checkNetworkRequest(NetworkProcess&, WebCore::SecurityOrigin* topOrigin, WebCore::FetchOptionsDestination, bool isMainFrameLoad, WebCore::ResourceRequest&&, CompletionHandler<void(WebCore::ResourceRequest&&, bool blocked, String cspDirectives, AdBlockCosmeticResources)>&&);

// Merges engine-supplied CSP directives into a document/subdocument response,
// comma-joining with any existing Content-Security-Policy header per CSP2. The
// whole injection is dropped (no-op) when the directives are empty, contain
// control characters (newlines, nulls — header-injection defense), or carry an
// abuse-only directive an untrusted list must not inject (report-uri/report-to,
// the exfiltration channel — mirrors uBlock Origin's $csp restriction). All
// rejected before injection (U5 security requirement).
void mergeCSPDirectives(WebCore::ResourceResponse&, const String& cspDirectives);

// Async WebSocket-open block check (request type "websocket"). completion(true)
// => refuse the connection.
void checkWebSocketRequest(NetworkProcess&, const WebCore::SecurityOriginData& topOrigin, const WebCore::ResourceRequest&, CompletionHandler<void(bool blocked)>&&);

} // namespace AdBlock

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
