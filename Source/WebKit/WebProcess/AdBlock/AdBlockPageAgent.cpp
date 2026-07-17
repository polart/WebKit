// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockPageAgent.h.

#include "config.h"
#include "AdBlockPageAgent.h"

#if ENABLE(ADBLOCK)

#include "NetworkConnectionToWebProcessMessages.h"
#include "NetworkProcessConnection.h"
#include "WebFrame.h"
#include "WebPage.h"
#include "WebProcess.h"
#include <JavaScriptCore/JSObjectRef.h>
#include <JavaScriptCore/JSStringRef.h>
#include <JavaScriptCore/JSValueRef.h>
#include <JavaScriptCore/OpaqueJSString.h>
#include <JavaScriptCore/SourceTaintedOrigin.h>
#include <WebCore/DOMWrapperWorld.h>
#include <WebCore/Document.h>
#include <WebCore/DocumentInlines.h>
#include <WebCore/ExtensionStyleSheets.h>
#include <WebCore/LocalFrame.h>
#include <WebCore/LocalFrameInlines.h>
#include <WebCore/ScriptController.h>
#include <limits>
#include <wtf/NeverDestroyed.h>
#include <wtf/StdLibExtras.h>
#include <wtf/TZoneMallocInlines.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AdBlockPageAgent);

// Identifier for the dynamic hide selectors' content-extension stylesheet. Kept
// distinct from U6's static "WebKitAdBlockCosmetic" sheet: addDisplayNoneSelector
// de-duplicates by selector id within a sheet, so a shared identifier would make
// the dynamic ids (which restart per document) collide with the static ones.
static constexpr auto dynamicCosmeticIdentifier = "WebKitAdBlockCosmeticDynamic"_s;

// Injected into the adblock isolated world at document start. Observes the DOM for
// class/id tokens (initial scan + MutationObserver), de-duplicates locally, batches
// on an animation frame, and hands each batch to the native `report` callback passed
// in as an argument (never exposed on a global, so page scripts cannot reach it).
static ASCIILiteral dynamicHidingAgentSource()
{
    return "(function(report) {"
        "\"use strict\";"
        "var seenC = Object.create(null), seenI = Object.create(null);"
        "var pendC = [], pendI = [], scheduled = false;"
        "function collect(el) {"
            "if (!el || el.nodeType !== 1) return;"
            "var cl = el.classList, i;"
            "if (cl) for (i = 0; i < cl.length; i++) { var t = cl[i]; if (t && !seenC[t]) { seenC[t] = 1; pendC.push(t); } }"
            "var id = el.id;"
            "if (id && !seenI[id]) { seenI[id] = 1; pendI.push(id); }"
        "}"
        "function scan(root) {"
            "collect(root);"
            "if (root.querySelectorAll) { var els = root.querySelectorAll(\"[class],[id]\"); for (var i = 0; i < els.length; i++) collect(els[i]); }"
        "}"
        "function flush() {"
            "scheduled = false;"
            "if (!pendC.length && !pendI.length) return;"
            "var c = pendC, d = pendI; pendC = []; pendI = [];"
            "try { report(c, d); } catch (e) {}"
        "}"
        "function schedule() {"
            "if (scheduled) return;"
            "scheduled = true;"
            "var raf = window.requestAnimationFrame;"
            "if (raf) raf(flush); else setTimeout(flush, 0);"
        "}"
        "try {"
            "var observer = new MutationObserver(function(records) {"
                "for (var i = 0; i < records.length; i++) {"
                    "var r = records[i];"
                    "if (r.type === \"attributes\") collect(r.target);"
                    "else if (r.addedNodes) for (var j = 0; j < r.addedNodes.length; j++) scan(r.addedNodes[j]);"
                "}"
                "schedule();"
            "});"
            "observer.observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: [\"class\", \"id\"] });"
        "} catch (e) {}"
        "scan(document.documentElement || document);"
        "schedule();"
    "})"_s;
}

static WebCore::DOMWrapperWorld& adBlockWorld()
{
    // A single process-wide isolated world for the dynamic-hiding agent: each frame
    // gets its own global object in it, and page scripts cannot observe it.
    static NeverDestroyed<Ref<WebCore::DOMWrapperWorld>> world = WebCore::ScriptController::createWorld("WebKitAdBlockDynamicHiding"_s, WebCore::ScriptController::WorldType::User);
    return world.get().get();
}

static Vector<String> toStringVector(JSContextRef context, JSValueRef value)
{
    Vector<String> result;
    if (!value || !JSValueIsObject(context, value))
        return result;
    JSObjectRef array = JSValueToObject(context, value, nullptr);
    if (!array)
        return result;

    JSValueRef lengthValue = JSObjectGetProperty(context, array, OpaqueJSString::tryCreate("length"_s).get(), nullptr);
    double length = JSValueToNumber(context, lengthValue, nullptr);
    if (!(length > 0))
        return result;

    unsigned count = static_cast<unsigned>(length);
    result.reserveInitialCapacity(count);
    for (unsigned i = 0; i < count; ++i) {
        JSValueRef element = JSObjectGetPropertyAtIndex(context, array, i, nullptr);
        if (!element || !JSValueIsString(context, element))
            continue;
        JSStringRef copy = JSValueToStringCopy(context, element, nullptr);
        if (!copy)
            continue;
        result.append(adoptRef(copy)->string());
    }
    return result;
}

static JSValueRef reportTokensCallback(JSContextRef context, JSObjectRef, JSObjectRef, size_t argumentCount, const JSValueRef rawArguments[], JSValueRef*)
{
    RefPtr frame = WebFrame::frameForContext(context);
    if (!frame)
        return JSValueMakeUndefined(context);
    RefPtr page = frame->page();
    if (!page)
        return JSValueMakeUndefined(context);
    auto* agent = page->adBlockPageAgentIfExists();
    if (!agent)
        return JSValueMakeUndefined(context);

    auto arguments = unsafeMakeSpan(rawArguments, argumentCount);
    Vector<String> classes = toStringVector(context, argumentCount > 0 ? arguments[0] : nullptr);
    Vector<String> ids = toStringVector(context, argumentCount > 1 ? arguments[1] : nullptr);
    agent->reportDynamicTokens(*frame, WTF::move(classes), WTF::move(ids));
    return JSValueMakeUndefined(context);
}

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

void AdBlockPageAgent::setDynamicHidingEnabled(WebCore::FrameIdentifier frameID, Vector<String>&& exceptions)
{
    FrameDynamicState state;
    state.exceptions = WTF::move(exceptions);
    m_frameDynamicState.set(frameID, WTF::move(state));
}

void AdBlockPageAgent::clearDynamicHiding(WebCore::FrameIdentifier frameID)
{
    m_frameDynamicState.remove(frameID);
}

void AdBlockPageAgent::injectDynamicHidingAgentIfNeeded(WebFrame& webFrame, WebCore::DOMWrapperWorld& world)
{
    // The agent lives in the adblock isolated world, but document start is signalled
    // by the main world's window-object setup, so trigger off the normal world only.
    if (!world.isNormal())
        return;

    auto it = m_frameDynamicState.find(webFrame.frameID());
    if (it == m_frameDynamicState.end() || it->value.agentInjected)
        return;
    it->value.agentInjected = true;

    JSGlobalContextRef context = webFrame.jsContextForWorld(adBlockWorld());
    if (!context)
        return;

    JSObjectRef reportFunction = JSObjectMakeFunctionWithCallback(context, nullptr, reportTokensCallback);
    JSValueRef exception = nullptr;
    JSValueRef agentValue = JSEvaluateScript(context, OpaqueJSString::tryCreate(dynamicHidingAgentSource()).get(), nullptr, nullptr, 0, &exception);
    if (exception || !agentValue)
        return;
    JSObjectRef agentFunction = JSValueToObject(context, agentValue, nullptr);
    if (!agentFunction)
        return;

    JSValueRef arguments[] = { reportFunction };
    JSObjectCallAsFunction(context, agentFunction, nullptr, std::size(arguments), arguments, nullptr);
}

void AdBlockPageAgent::reportDynamicTokens(WebFrame& webFrame, Vector<String>&& classes, Vector<String>&& ids)
{
    auto frameID = webFrame.frameID();
    auto it = m_frameDynamicState.find(frameID);
    if (it == m_frameDynamicState.end())
        return;
    auto& state = it->value;

    // Authoritative de-duplication: only tokens never queried for this frame cross
    // the IPC boundary, so a token is asked about at most once per document.
    Vector<String> newClasses;
    for (auto& token : classes) {
        if (!token.isEmpty() && state.seenClasses.add(token).isNewEntry)
            newClasses.append(token);
    }
    Vector<String> newIds;
    for (auto& token : ids) {
        if (!token.isEmpty() && state.seenIds.add(token).isNewEntry)
            newIds.append(token);
    }
    if (newClasses.isEmpty() && newIds.isEmpty())
        return;

    RefPtr coreFrame = webFrame.coreLocalFrame();
    if (!coreFrame)
        return;
    RefPtr document = coreFrame->document();
    if (!document)
        return;

    auto hostname = document->url().host().toString();
    auto exceptions = state.exceptions;

    Ref protectedFrame { webFrame };
    WeakPtr weakDocument { *document };
    WebProcess::singleton().ensureNetworkProcessConnection().connection().sendWithAsyncReply(Messages::NetworkConnectionToWebProcess::HiddenClassIdSelectors(WTF::move(newClasses), WTF::move(newIds), WTF::move(exceptions), hostname), [weakThis = WeakPtr { *this }, frameID, protectedFrame = WTF::move(protectedFrame), weakDocument = WTF::move(weakDocument)](Vector<String>&& selectors) mutable {
        if (!weakThis || selectors.isEmpty())
            return;
        // Drop the reply if the frame navigated away: the state was cleared, or the
        // document that observed these tokens is no longer the frame's document.
        RefPtr document = weakDocument.get();
        RefPtr coreFrame = protectedFrame->coreLocalFrame();
        if (!document || !coreFrame || coreFrame->document() != document.get())
            return;
        weakThis->applyDynamicSelectors(protectedFrame, frameID, selectors);
    });
}

void AdBlockPageAgent::applyDynamicSelectors(WebFrame& webFrame, WebCore::FrameIdentifier frameID, const Vector<String>& selectors)
{
    auto it = m_frameDynamicState.find(frameID);
    if (it == m_frameDynamicState.end())
        return;

    RefPtr coreFrame = webFrame.coreLocalFrame();
    if (!coreFrame)
        return;
    RefPtr document = coreFrame->document();
    if (!document)
        return;

#if ENABLE(CONTENT_EXTENSIONS)
    auto& state = it->value;
    for (auto& selector : selectors) {
        if (selector.isEmpty() || !state.appliedSelectors.add(selector).isNewEntry)
            continue;
        if (m_nextDynamicSelectorID == std::numeric_limits<uint32_t>::max())
            break;
        // Reuses U6's ExtensionStyleSheets display:none pipeline; addDisplayNoneSelector
        // schedules a style recalc so the element is hidden shortly after insertion.
        document->extensionStyleSheets().addDisplayNoneSelector(dynamicCosmeticIdentifier, selector, m_nextDynamicSelectorID++);
    }
#else
    UNUSED_PARAM(selectors);
#endif
}

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
