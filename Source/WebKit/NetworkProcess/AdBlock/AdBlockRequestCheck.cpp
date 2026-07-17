// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockRequestCheck.h.

#include "config.h"
#include "AdBlockRequestCheck.h"

#if ENABLE(ADBLOCK)

#include "AdBlockManager.h"
#include "NetworkProcess.h"
#include <WebCore/RegistrableDomain.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityOriginData.h>

namespace WebKit {

namespace AdBlock {

using namespace WebCore;

ASCIILiteral requestTypeForDestination(FetchOptionsDestination destination)
{
    switch (destination) {
    case FetchOptionsDestination::Audio:
    case FetchOptionsDestination::Video:
        return "media"_s;
    case FetchOptionsDestination::Audioworklet:
    case FetchOptionsDestination::Paintworklet:
    case FetchOptionsDestination::Script:
    case FetchOptionsDestination::Serviceworker:
    case FetchOptionsDestination::Sharedworker:
    case FetchOptionsDestination::Speculationrules:
    case FetchOptionsDestination::Worker:
        return "script"_s;
    case FetchOptionsDestination::Document:
        return "document"_s;
    case FetchOptionsDestination::Embed:
    case FetchOptionsDestination::Object:
        return "object"_s;
    case FetchOptionsDestination::Environmentmap:
    case FetchOptionsDestination::Image:
        return "image"_s;
    case FetchOptionsDestination::Font:
        return "font"_s;
    case FetchOptionsDestination::Iframe:
        return "sub_frame"_s;
    case FetchOptionsDestination::Style:
        return "stylesheet"_s;
    case FetchOptionsDestination::EmptyString:
    case FetchOptionsDestination::Json:
        return "xhr"_s;
    case FetchOptionsDestination::Manifest:
    case FetchOptionsDestination::Model:
    case FetchOptionsDestination::Report:
    case FetchOptionsDestination::Track:
    case FetchOptionsDestination::Xslt:
        return "other"_s;
    }
    ASSERT_NOT_REACHED();
    return "other"_s;
}

// adblock-rust's matches() already resolves exception rules: matched is the final
// block verdict. Guard on the exception flag too so an $@@ match is never treated
// as a block even if a future engine change decouples the fields.
static bool isBlockingResult(const AdBlockEngine::CheckResult& result)
{
    return result.isMatched && !result.hasException;
}

void checkNetworkRequest(NetworkProcess& networkProcess, SecurityOrigin* topOrigin, FetchOptionsDestination destination, bool isMainFrameLoad, ResourceRequest&& request, CompletionHandler<void(ResourceRequest&&, bool)>&& completion)
{
    // Never cancel the top-level navigation itself; only its subresources and
    // subframes are subject to blocking.
    if (isMainFrameLoad) {
        completion(WTF::move(request), false);
        return;
    }

    // Read every query input into locals before the request is moved into the
    // async continuation, so the engine query never touches a moved-from request.
    auto url = request.url();
    String sourceHostname = topOrigin ? topOrigin->host() : String { };
    bool isThirdParty = topOrigin && !RegistrableDomain(url).matches(topOrigin->data());

    networkProcess.adBlockManager().checkRequest(url.string(), url.host().toString(), sourceHostname, requestTypeForDestination(destination), isThirdParty, [request = WTF::move(request), completion = WTF::move(completion)](AdBlockEngine::CheckResult result) mutable {
        completion(WTF::move(request), isBlockingResult(result));
    });
}

void checkWebSocketRequest(NetworkProcess& networkProcess, const SecurityOriginData& topOrigin, const ResourceRequest& request, CompletionHandler<void(bool)>&& completion)
{
    auto url = request.url();
    bool isThirdParty = !RegistrableDomain(url).matches(topOrigin);

    networkProcess.adBlockManager().checkRequest(url.string(), url.host().toString(), topOrigin.host(), "websocket"_s, isThirdParty, [completion = WTF::move(completion)](AdBlockEngine::CheckResult result) mutable {
        completion(isBlockingResult(result));
    });
}

} // namespace AdBlock

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
