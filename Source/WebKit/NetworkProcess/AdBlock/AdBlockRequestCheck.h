// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Request-side glue for the U4 network-blocking hook. It keeps all adblock
// logic — mapping a fetch destination to adblock-rust's request-type string,
// computing the tab (source) host and third-party flag, and translating an
// engine CheckResult into a block/allow verdict — out of the core
// NetworkProcess load path, so the hook sites (NetworkLoadChecker,
// NetworkSocketChannel) stay surgical (R9). The async checks route through
// NetworkProcess's AdBlockManager (KTD3), which short-circuits allowlisted
// hosts and pass-through defaults before any list has loaded.

#pragma once

#if ENABLE(ADBLOCK)

#include <WebCore/FetchOptionsDestination.h>
#include <wtf/CompletionHandler.h>
#include <wtf/text/ASCIILiteral.h>

namespace WebCore {
class ResourceRequest;
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

// Async subresource/subframe block check. The request is moved in and handed
// back to the completion, so a single move covers both the engine query and the
// caller's continuation (blocked == true => cancel the load). Never blocks a
// top-level (main-frame) navigation. Pass-through — blocked == false — when no
// list has loaded or the host is allowlisted (AdBlockManager decides).
void checkNetworkRequest(NetworkProcess&, WebCore::SecurityOrigin* topOrigin, WebCore::FetchOptionsDestination, bool isMainFrameLoad, WebCore::ResourceRequest&&, CompletionHandler<void(WebCore::ResourceRequest&&, bool blocked)>&&);

// Async WebSocket-open block check (request type "websocket"). completion(true)
// => refuse the connection.
void checkWebSocketRequest(NetworkProcess&, const WebCore::SecurityOriginData& topOrigin, const WebCore::ResourceRequest&, CompletionHandler<void(bool blocked)>&&);

} // namespace AdBlock

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
