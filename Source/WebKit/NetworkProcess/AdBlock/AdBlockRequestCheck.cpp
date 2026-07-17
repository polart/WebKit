// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockRequestCheck.h.

#include "config.h"
#include "AdBlockRequestCheck.h"

#if ENABLE(ADBLOCK)

#include "AdBlockManager.h"
#include "NetworkProcess.h"
#include <WebCore/HTTPHeaderNames.h>
#include <WebCore/RegistrableDomain.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SecurityOriginData.h>
#include <wtf/ASCIICType.h>
#include <wtf/text/MakeString.h>
#include <wtf/text/StringView.h>

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

// A $csp rule only applies to a document or subdocument (frame) load, mirroring
// where a Content-Security-Policy header would land. Other destinations skip the
// CSP query entirely.
static bool isDocumentDestination(FetchOptionsDestination destination)
{
    return destination == FetchOptionsDestination::Document || destination == FetchOptionsDestination::Iframe;
}

static bool containsControlCharacters(const String& value)
{
    for (unsigned i = 0; i < value.length(); ++i) {
        if (value[i] < 0x20 || value[i] == 0x7F)
            return true;
    }
    return false;
}

// True if any CSP directive in the (possibly multi-policy) string is one an
// untrusted filter list must not be allowed to inject. adblock-rust comma-joins
// the matched $csp values and never validates their directive names, so this is
// the only enforcement point — it mirrors uBlock Origin's $csp restriction.
// report-uri/report-to are the exfiltration directives: they POST violation
// reports (the document URL, referrer, and every blocked-resource URL) to an
// endpoint the list controls, on every page the rule matches. frame-ancestors
// and sandbox are intentionally permitted — filter lists use them legitimately
// for anti-adblock, matching uBO.
static bool containsForbiddenCSPDirective(const String& cspDirectives)
{
    StringView view { cspDirectives };
    unsigned length = view.length();
    unsigned i = 0;
    while (i < length) {
        // A directive name sits at the start of the string or right after a ','
        // (policy separator) or ';' (directive separator); skip leading spaces.
        while (i < length && isASCIIWhitespace(view[i]))
            ++i;
        unsigned nameStart = i;
        while (i < length && view[i] != ';' && view[i] != ',' && !isASCIIWhitespace(view[i]))
            ++i;
        auto name = view.substring(nameStart, i - nameStart);
        if (equalLettersIgnoringASCIICase(name, "report-uri"_s) || equalLettersIgnoringASCIICase(name, "report-to"_s))
            return true;
        // Skip this directive's value to the next ';'/',' boundary.
        while (i < length && view[i] != ';' && view[i] != ',')
            ++i;
        if (i < length)
            ++i;
    }
    return false;
}

void checkNetworkRequest(NetworkProcess& networkProcess, SecurityOrigin* topOrigin, FetchOptionsDestination destination, bool isMainFrameLoad, ResourceRequest&& request, CompletionHandler<void(ResourceRequest&&, bool, String, AdBlockCosmeticResources)>&& completion)
{
    // Read every query input into locals before the request is moved into an
    // async continuation, so the engine queries never touch a moved-from request.
    auto url = request.url();
    auto urlString = url.string();
    auto hostname = url.host().toString();
    auto requestType = requestTypeForDestination(destination);
    // For a main-frame document the tab origin is the document itself: source
    // host is self and the load is first-party.
    String sourceHostname = topOrigin ? topOrigin->host() : (isMainFrameLoad ? hostname : String { });
    bool isThirdParty = topOrigin && !RegistrableDomain(url).matches(topOrigin->data());
    // CSP ($csp rules) and cosmetic resources (element hiding, scriptlets) both
    // only apply to a document/subdocument navigation.
    bool isDocumentNavigation = isDocumentDestination(destination);

    Ref manager { networkProcess.adBlockManager() };

    // For an allowed document/subdocument load, fetch the CSP directives (U5) and
    // then the cosmetic resources (U6) — chained so a single move carries the
    // request through both queries to the caller's continuation. Never runs for a
    // blocked request or a non-document load.
    auto finish = [manager, urlString, hostname, sourceHostname, requestType, isThirdParty, isDocumentNavigation](ResourceRequest&& request, bool blocked, CompletionHandler<void(ResourceRequest&&, bool, String, AdBlockCosmeticResources)>&& completion) mutable {
        if (blocked || !isDocumentNavigation) {
            completion(WTF::move(request), blocked, String { }, AdBlockCosmeticResources { });
            return;
        }
        manager->cspDirectives(urlString, hostname, sourceHostname, requestType, isThirdParty, [manager, urlString, hostname, request = WTF::move(request), completion = WTF::move(completion)](String csp) mutable {
            manager->cosmeticResources(urlString, hostname, [csp = WTF::move(csp), request = WTF::move(request), completion = WTF::move(completion)](AdBlockCosmeticResources cosmetic) mutable {
                completion(WTF::move(request), false, WTF::move(csp), WTF::move(cosmetic));
            });
        });
    };

    // Never cancel the top-level navigation itself; only its subresources and
    // subframes are subject to blocking. A main-frame load still queries CSP and
    // cosmetics.
    if (isMainFrameLoad) {
        finish(WTF::move(request), false, WTF::move(completion));
        return;
    }

    manager->checkRequest(urlString, hostname, sourceHostname, requestType, isThirdParty, [finish = WTF::move(finish), request = WTF::move(request), completion = WTF::move(completion)](AdBlockEngine::CheckResult result) mutable {
        finish(WTF::move(request), isBlockingResult(result), WTF::move(completion));
    });
}

void mergeCSPDirectives(ResourceResponse& response, const String& cspDirectives)
{
    // Reject empty or control-character-bearing directives before injection: a
    // newline or null from a hostile filter list could otherwise forge or split
    // response headers (U5 security requirement).
    if (cspDirectives.isEmpty() || containsControlCharacters(cspDirectives))
        return;

    // Reject the whole injection if any policy carries an abuse-only directive
    // (report-uri/report-to). We can't attribute a merged policy to the list that
    // supplied it, so — consistent with the control-character posture above —
    // drop all engine CSP for this response rather than inject a channel a
    // hostile list could exfiltrate through.
    if (containsForbiddenCSPDirective(cspDirectives))
        return;

    auto existing = response.httpHeaderField(HTTPHeaderName::ContentSecurityPolicy);
    if (existing.isEmpty()) {
        response.setHTTPHeaderField(HTTPHeaderName::ContentSecurityPolicy, cspDirectives);
        return;
    }
    // Distinct policies are enforced independently; comma-join them per CSP2
    // (https://www.w3.org/TR/CSP2/#implementation-considerations), matching
    // Brave's MergeCspDirectiveInto.
    response.setHTTPHeaderField(HTTPHeaderName::ContentSecurityPolicy, makeString(cspDirectives, ", "_s, existing));
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
