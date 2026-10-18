// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// AdBlockPageAgent is the WebProcess-side, per-WebPage coordinator for cosmetic
// filtering that runs inside page content. In U7 it injects the scriptlet source
// (uBlock resource library) that matched filters require: the engine computes the
// `injected_script` for a navigation in the NetworkProcess (U6 cosmetic payload),
// it rides to the WebProcess with the navigation response
// (WebResourceLoader::setAdBlockCosmeticResources), and the agent stashes it keyed
// by frame. The stashed scriptlet runs exactly once, at the next main-world window
// setup for that frame — document start of the committed document, before page
// scripts — in the page's main JS world so page scripts observe its effects
// (parity with Brave's in-page-world injection). U8 extends this agent with the
// mutation-driven dynamic-hiding flow.

#pragma once

#if ENABLE(ADBLOCK)

#include <WebCore/FrameIdentifier.h>
#include <wtf/CheckedPtr.h>
#include <wtf/HashMap.h>
#include <wtf/HashSet.h>
#include <wtf/ListHashSet.h>
#include <wtf/RunLoop.h>
#include <wtf/Seconds.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/UniqueRef.h>
#include <wtf/Vector.h>
#include <wtf/WeakPtr.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class DOMWrapperWorld;
class LocalFrame;
}

namespace WebKit {

class WebFrame;

class AdBlockPageAgent : public CanMakeWeakPtr<AdBlockPageAgent>, public CanMakeCheckedPtr<AdBlockPageAgent> {
    WTF_MAKE_TZONE_ALLOCATED(AdBlockPageAgent);
    WTF_OVERRIDE_DELETE_FOR_CHECKED_PTR(AdBlockPageAgent);
public:
    AdBlockPageAgent();
    ~AdBlockPageAgent();

    // Stash the scriptlet JS (already permission-masked by the engine) for a frame's
    // in-flight navigation. A newer navigation on the same frame overwrites the
    // pending entry; an empty script clears it.
    void setPendingScriptlet(WebCore::FrameIdentifier, String&&);

    // Drop any scriptlet stashed for a superseded navigation on this frame. Called
    // when a new provisional load starts — before that navigation stashes its own
    // scriptlet — so a scriptlet matched for one document can never run on a later,
    // unrelated one committed on the same frame.
    void clearPendingScriptlet(WebCore::FrameIdentifier);

    // Called when a world's window object is (re)created for a frame. For the main
    // world, runs and consumes that frame's pending scriptlet.
    void injectPendingScriptlet(WebCore::LocalFrame&, WebCore::DOMWrapperWorld&);

    // U8 dynamic cosmetic hiding.
    //
    // Arm mutation-driven dynamic hiding for a frame's committed navigation with the
    // generic-rule exception set. Called at response time (before commit); the agent
    // is injected at the next main-world document start. A newer navigation resets it
    // via clearDynamicHiding.
    void setDynamicHidingEnabled(WebCore::FrameIdentifier, Vector<String>&& exceptions);
    void clearDynamicHiding(WebCore::FrameIdentifier);

    // On main-world document start, inject the mutation-observer agent into the
    // adblock isolated world for a frame armed by setDynamicHidingEnabled. Ignores
    // non-main worlds and unarmed frames, and injects at most once per document.
    void injectDynamicHidingAgentIfNeeded(WebFrame&, WebCore::DOMWrapperWorld&);

    // Native sink for the class/id tokens the injected agent observes. De-duplicates
    // against tokens recently queried for the frame, queries the engine for matching
    // generic hide selectors over IPC, and appends the reply to the document's
    // cosmetic stylesheet. Tokens the NetworkProcess throttles are held and
    // re-queried once its budget window resets.
    void reportDynamicTokens(WebFrame&, Vector<String>&& classes, Vector<String>&& ids);

private:
    // Bounded "already queried" set. A long-lived single-page app can cycle through
    // an unbounded number of distinct class/id tokens over one document, so an
    // unbounded set grows for the document's lifetime. Instead keep two generations:
    // once the current one fills, it becomes the previous one and the oldest
    // generation is dropped. A token seen again while in the previous generation is
    // promoted, so tokens still in use stay de-duplicated. Forgetting a token only
    // costs a repeat query if it reappears (re-applying a selector is a no-op).
    class RecentTokenSet {
    public:
        // Returns true if the token was not recently seen (the caller should query it).
        bool add(const String&);
        // Forgets a token, so it is queried again if reported again.
        void remove(const String&);

    private:
        static constexpr unsigned maxGenerationSize = 4096;
        HashSet<String> m_current;
        HashSet<String> m_previous;
    };

    struct FrameDynamicState {
        WTF_MAKE_STRUCT_TZONE_ALLOCATED(FrameDynamicState);

        // Identifies this arming of the frame. A reply is only applied to the state
        // it was sent for: the next navigation re-arms the frame at response time,
        // before its commit, so the old document can still be current when a reply
        // for it lands on the new state.
        uint64_t generation { 0 };
        Vector<String> exceptions;
        RecentTokenSet seenClasses;
        RecentTokenSet seenIds;
        HashSet<String> appliedSelectors;
        // Tokens whose query the NetworkProcess throttled, awaiting a retry once its
        // budget window resets (see m_dynamicHidingRetryTimer).
        ListHashSet<String> throttledClasses;
        ListHashSet<String> throttledIds;
        bool agentInjected { false };
    };

    void queryDynamicTokens(WebFrame&, FrameDynamicState&, Vector<String>&& classes, Vector<String>&& ids);
    FrameDynamicState* dynamicState(WebCore::FrameIdentifier, uint64_t generation);
    void handleThrottledTokens(WebCore::FrameIdentifier, uint64_t generation, Vector<String>&& classes, Vector<String>&& ids, Seconds retryAfter);
    void retryThrottledTokens();
    void applyDynamicSelectors(WebFrame&, WebCore::FrameIdentifier, uint64_t generation, const Vector<String>& selectors);

    HashMap<WebCore::FrameIdentifier, String> m_pendingScriptlets;
    // Boxed: the state holds several hash sets, too large to move inline on rehash.
    HashMap<WebCore::FrameIdentifier, UniqueRef<FrameDynamicState>> m_frameDynamicState;
    // Monotonic across every document this agent hides in; each document's cosmetic
    // sheet starts empty, so an ever-increasing id is always new to it and never
    // collides with the U6 static selectors (which use a separate identifier).
    uint32_t m_nextDynamicSelectorID { 0 };
    uint64_t m_nextDynamicStateGeneration { 0 };
    // One timer for every frame's throttled tokens: they are all retried together
    // (the NetworkProcess budget is per page, so they share a window).
    RunLoop::Timer m_dynamicHidingRetryTimer;
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
