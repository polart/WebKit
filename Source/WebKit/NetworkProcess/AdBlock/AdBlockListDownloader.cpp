// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockListDownloader.h.

#include "config.h"
#include "AdBlockListDownloader.h"

#if ENABLE(ADBLOCK)

#include "AuthenticationChallengeDisposition.h"
#include "AuthenticationManager.h"
#include "Logging.h"
#include "NetworkLoadParameters.h"
#include "NetworkProcess.h"
#include "NetworkSession.h"
#include <WebCore/AuthenticationChallenge.h>
#include <WebCore/FrameLoaderTypes.h>
#include <WebCore/ProtectionSpace.h>
#include <WebCore/ResourceError.h>
#include <WebCore/ResourceRequest.h>
#include <WebCore/ResourceResponse.h>
#include <WebCore/SecurityOrigin.h>
#include <WebCore/SharedBuffer.h>
#include <wtf/RunLoop.h>

namespace WebKit {

using namespace WebCore;

// A hostile or misconfigured server must not be able to exhaust NetworkProcess
// memory with an unbounded list body. Real filter lists are a few MB; 64 MB is
// generous headroom.
static constexpr size_t maxListDownloadSize = 64 * MB;

Ref<AdBlockListDownloader> AdBlockListDownloader::create(NetworkProcess& networkProcess, PAL::SessionID sessionID, const URL& url, CompletionHandler&& completion)
{
    Ref downloader = adoptRef(*new AdBlockListDownloader(networkProcess, sessionID, url, WTF::move(completion)));
    downloader->start(networkProcess);
    return downloader;
}

AdBlockListDownloader::AdBlockListDownloader(NetworkProcess& networkProcess, PAL::SessionID sessionID, const URL& url, CompletionHandler&& completion)
    : m_networkProcess(networkProcess)
    , m_sessionID(sessionID)
    , m_url(url)
    , m_completion(WTF::move(completion))
{
}

AdBlockListDownloader::~AdBlockListDownloader()
{
    if (RefPtr task = m_task) {
        task->clearClient();
        task->cancel();
    }
}

void AdBlockListDownloader::start(NetworkProcess& networkProcess)
{
    m_selfRef = this;

    // Filter lists can inject rules that run on every page, so only HTTPS with
    // TLS validation is trusted for delivery (security-lens follow-up).
    if (!m_url.protocolIs("https"_s)) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListDownloader: refusing non-HTTPS subscription URL");
        finish(std::nullopt);
        return;
    }

    CheckedPtr networkSession = networkProcess.networkSession(m_sessionID);
    if (!networkSession) {
        finish(std::nullopt);
        return;
    }

    NetworkLoadParameters loadParameters;
    loadParameters.topOrigin = SecurityOrigin::create(m_url);
    loadParameters.sourceOrigin = SecurityOrigin::create(m_url);
    loadParameters.request = ResourceRequest { URL { m_url } };
    loadParameters.request.setHTTPMethod("GET"_s);
    loadParameters.storedCredentialsPolicy = StoredCredentialsPolicy::DoNotUse;
    loadParameters.clientCredentialPolicy = ClientCredentialPolicy::CannotAskClientForCredentials;

    Ref task = NetworkDataTask::create(*networkSession, *this, loadParameters);
    m_task = task.ptr();
    task->resume();
}

void AdBlockListDownloader::finish(std::optional<Vector<uint8_t>>&& result)
{
    if (RefPtr task = std::exchange(m_task, nullptr)) {
        task->clearClient();
        task->cancel();
    }

    if (m_completion)
        m_completion(WTF::move(result));

    // Drop the self-reference last: it may be the final Ref keeping us alive.
    m_selfRef = nullptr;
}

void AdBlockListDownloader::willPerformHTTPRedirection(ResourceResponse&&, ResourceRequest&& request, RedirectCompletionHandler&& completionHandler)
{
    if (!request.url().protocolIs("https"_s)) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListDownloader: refusing non-HTTPS redirect target");
        completionHandler({ });
        finish(std::nullopt);
        return;
    }
    completionHandler(WTF::move(request));
}

void AdBlockListDownloader::didReceiveChallenge(AuthenticationChallenge&& challenge, NegotiatedLegacyTLS negotiatedLegacyTLS, ChallengeCompletionHandler&& completionHandler)
{
    // A TLS server-trust evaluation arrives here as a challenge on every HTTPS
    // connection; it must go through the platform's certificate validation
    // (default handling), not be cancelled — cancelling it aborts the handshake
    // and every download fails. Route it to the AuthenticationManager exactly as
    // PingLoad/BackgroundFetchLoad do (no page context: empty proxy id, no origin).
    if (challenge.protectionSpace().authenticationScheme() == ProtectionSpace::AuthenticationScheme::ServerTrustEvaluationRequested) {
        Ref networkProcess { m_networkProcess.get() };
        Ref { networkProcess->authenticationManager() }->didReceiveAuthenticationChallenge(m_sessionID, { }, nullptr, challenge, negotiatedLegacyTLS, WTF::move(completionHandler));
        return;
    }

    // No credentials are ever supplied for a public list download; reject any
    // credential-based challenge.
    completionHandler(AuthenticationChallengeDisposition::Cancel, { });
}

void AdBlockListDownloader::didReceiveResponse(ResourceResponse&& response, NegotiatedLegacyTLS, PrivateRelayed, ResponseCompletionHandler&& completionHandler)
{
    auto statusCode = response.httpStatusCode();
    if (response.url().protocolIsInHTTPFamily() && (statusCode < 200 || statusCode >= 300)) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListDownloader: subscription fetch returned HTTP %d", statusCode);
        completionHandler(PolicyAction::Ignore);
        finish(std::nullopt);
        return;
    }
    completionHandler(PolicyAction::Use);
}

void AdBlockListDownloader::didReceiveData(const SharedBuffer& data)
{
    if (m_data.size() + data.size() > maxListDownloadSize) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListDownloader: subscription body exceeds the size cap; aborting");
        finish(std::nullopt);
        return;
    }
    data.forEachSegment([&](std::span<const uint8_t> segment) {
        m_data.append(segment);
    });
}

void AdBlockListDownloader::didCompleteWithError(const ResourceError& error, const NetworkLoadMetrics&)
{
    if (!error.isNull()) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockListDownloader: subscription fetch failed (code=%d)", error.errorCode());
        finish(std::nullopt);
        return;
    }
    finish(WTF::move(m_data));
}

void AdBlockListDownloader::wasBlocked()
{
    finish(std::nullopt);
}

void AdBlockListDownloader::cannotShowURL()
{
    finish(std::nullopt);
}

void AdBlockListDownloader::wasBlockedByRestrictions()
{
    finish(std::nullopt);
}

void AdBlockListDownloader::wasBlockedByDisabledFTP()
{
    finish(std::nullopt);
}

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
