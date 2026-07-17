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
#include <wtf/HashMap.h>
#include <wtf/TZoneMalloc.h>
#include <wtf/text/WTFString.h>

namespace WebCore {
class DOMWrapperWorld;
class LocalFrame;
}

namespace WebKit {

class AdBlockPageAgent {
    WTF_MAKE_TZONE_ALLOCATED(AdBlockPageAgent);
public:
    AdBlockPageAgent();
    ~AdBlockPageAgent();

    // Stash the scriptlet JS (already permission-masked by the engine) for a frame's
    // in-flight navigation. A newer navigation on the same frame overwrites the
    // pending entry; an empty script clears it.
    void setPendingScriptlet(WebCore::FrameIdentifier, String&&);

    // Called when a world's window object is (re)created for a frame. For the main
    // world, runs and consumes that frame's pending scriptlet.
    void injectPendingScriptlet(WebCore::LocalFrame&, WebCore::DOMWrapperWorld&);

private:
    HashMap<WebCore::FrameIdentifier, String> m_pendingScriptlets;
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
