// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// AdBlockListDownloader fetches a filter-list subscription over the
// NetworkProcess's own loading stack (a NetworkDataTask on the session's
// context), returning the raw list bytes to the AdBlockListStore. Filter lists
// drive script/CSS/CSP injection on every page, so a MITM on the download can
// inject arbitrary rules: the downloader requires HTTPS (with the platform's
// TLS validation) and rejects any non-HTTPS URL or redirect target, logging the
// refusal. The response body is capped so a hostile server cannot exhaust
// NetworkProcess memory. Integrity verification of the delivered bytes (against
// a pinned hash) is the store's concern — see AdBlockListStore.

#pragma once

#if ENABLE(ADBLOCK)

#include "NetworkDataTask.h"
#include <optional>
#include <wtf/CompletionHandler.h>
#include <wtf/URL.h>
#include <wtf/Ref.h>
#include <wtf/RefCounted.h>
#include <wtf/RefPtr.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>

namespace WebKit {

class NetworkProcess;

class AdBlockListDownloader final : public RefCounted<AdBlockListDownloader>, public NetworkDataTaskClient {
public:
    // std::nullopt on any failure (non-HTTPS, network error, non-2xx status,
    // oversized body). The handler fires exactly once, on the main run loop.
    using CompletionHandler = WTF::CompletionHandler<void(std::optional<Vector<uint8_t>>&&)>;

    static Ref<AdBlockListDownloader> create(NetworkProcess&, PAL::SessionID, const URL&, CompletionHandler&&);
    ~AdBlockListDownloader();

    void ref() const final { RefCounted::ref(); }
    void deref() const final { RefCounted::deref(); }

private:
    AdBlockListDownloader(NetworkProcess&, PAL::SessionID, const URL&, CompletionHandler&&);

    void start(NetworkProcess&);
    void finish(std::optional<Vector<uint8_t>>&&);

    // NetworkDataTaskClient
    void willPerformHTTPRedirection(WebCore::ResourceResponse&&, WebCore::ResourceRequest&&, RedirectCompletionHandler&&) final;
    void didReceiveChallenge(WebCore::AuthenticationChallenge&&, NegotiatedLegacyTLS, ChallengeCompletionHandler&&) final;
    void didReceiveResponse(WebCore::ResourceResponse&&, NegotiatedLegacyTLS, PrivateRelayed, ResponseCompletionHandler&&) final;
    void didReceiveData(const WebCore::SharedBuffer&) final;
    void didCompleteWithError(const WebCore::ResourceError&, const WebCore::NetworkLoadMetrics&) final;
    void didSendData(uint64_t, uint64_t) final { }
    void wasBlocked() final;
    void cannotShowURL() final;
    void wasBlockedByRestrictions() final;
    void wasBlockedByDisabledFTP() final;

    PAL::SessionID m_sessionID;
    URL m_url;
    CompletionHandler m_completion;
    RefPtr<NetworkDataTask> m_task;
    Vector<uint8_t> m_data;
    // Keeps the downloader alive for the duration of the load; the NetworkDataTask
    // only holds its client weakly. Cleared in finish().
    RefPtr<AdBlockListDownloader> m_selfRef;
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
