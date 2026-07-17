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
#include <wtf/TZoneMalloc.h>
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
    // against tokens already queried for the frame, queries the engine for matching
    // generic hide selectors over IPC, and appends the reply to the document's
    // cosmetic stylesheet.
    void reportDynamicTokens(WebFrame&, Vector<String>&& classes, Vector<String>&& ids);

private:
    struct FrameDynamicState {
        Vector<String> exceptions;
        HashSet<String> seenClasses;
        HashSet<String> seenIds;
        HashSet<String> appliedSelectors;
        bool agentInjected { false };
    };

    void applyDynamicSelectors(WebFrame&, WebCore::FrameIdentifier, const Vector<String>& selectors);

    HashMap<WebCore::FrameIdentifier, String> m_pendingScriptlets;
    HashMap<WebCore::FrameIdentifier, FrameDynamicState> m_frameDynamicState;
    // Monotonic across every document this agent hides in; each document's cosmetic
    // sheet starts empty, so an ever-increasing id is always new to it and never
    // collides with the U6 static selectors (which use a separate identifier).
    uint32_t m_nextDynamicSelectorID { 0 };
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
