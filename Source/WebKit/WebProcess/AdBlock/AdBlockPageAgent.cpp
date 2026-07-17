// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockPageAgent.h.

#include "config.h"
#include "AdBlockPageAgent.h"

#if ENABLE(ADBLOCK)

#include <JavaScriptCore/SourceTaintedOrigin.h>
#include <WebCore/DOMWrapperWorld.h>
#include <WebCore/LocalFrame.h>
#include <WebCore/ScriptController.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AdBlockPageAgent);

AdBlockPageAgent::AdBlockPageAgent() = default;

AdBlockPageAgent::~AdBlockPageAgent() = default;

void AdBlockPageAgent::setPendingScriptlet(WebCore::FrameIdentifier frameID, String&& script)
{
    if (script.isEmpty()) {
        m_pendingScriptlets.remove(frameID);
        return;
    }
    m_pendingScriptlets.set(frameID, WTF::move(script));
}

void AdBlockPageAgent::clearPendingScriptlet(WebCore::FrameIdentifier frameID)
{
    m_pendingScriptlets.remove(frameID);
}

void AdBlockPageAgent::injectPendingScriptlet(WebCore::LocalFrame& frame, WebCore::DOMWrapperWorld& world)
{
    // Scriptlets only run in the page's main world so that page scripts observe
    // their effects (and anti-adblock code cannot trivially fingerprint a separate
    // world). Isolated worlds are ignored.
    if (!world.isNormal())
        return;

    auto script = m_pendingScriptlets.take(frame.frameID());
    if (script.isEmpty())
        return;

    // Run at document start, before page scripts. Exceptions are swallowed: a broken
    // scriptlet must never abort the page load.
    frame.script().executeScriptInWorldIgnoringException(world, script, JSC::SourceTaintedOrigin::Untainted);
}

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
