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
#include <JavaScriptCore/SourceTaintedness.h>
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
#include <wtf/text/MakeString.h>

namespace WebKit {

WTF_MAKE_TZONE_ALLOCATED_IMPL(AdBlockPageAgent);
WTF_MAKE_TZONE_ALLOCATED_IMPL(AdBlockPageAgent::FrameDynamicState);

// Identifier for the dynamic hide selectors' content-extension stylesheet. Kept
// distinct from U6's static "WebKitAdBlockCosmetic" sheet: addDisplayNoneSelector
// de-duplicates by selector id within a sheet, so a shared identifier would make
// the dynamic ids (which restart per document) collide with the static ones.
static constexpr auto dynamicCosmeticIdentifier = "WebKitAdBlockCosmeticDynamic"_s;

// Upper bound on class + id tokens per HiddenClassIdSelectors message. A batch larger
// than the NetworkProcess's whole per-window budget (AdBlockDynamicHidingLimiter)
// could never be admitted, so a big initial scan or a backlog of throttled tokens is
// split into messages that each fit comfortably within one window.
static constexpr size_t maxTokensPerQuery = 1024;

// Cap on tokens held per frame (per kind) awaiting a retry after throttling, so a
// page that keeps outrunning the budget cannot grow the backlog without bound.
// Tokens past the cap are dropped from the backlog and forgotten as seen.
static constexpr unsigned maxThrottledTokensPerFrame = 8192;

// Floor on the retry delay, so a near-zero retryAfter cannot spin a hot retry loop.
static constexpr Seconds minimumRetryDelay = 100_ms;

// Wraps the engine's `injected_script` in the runtime context uBlock Origin's
// scriptlets are written against: `scriptletGlobals` (a Proxy-wrapped Map that
// safeSelf() and friends read, e.g. `scriptletGlobals.bcSecret`) and
// `deAmpEnabled`. Without it nearly every uBO scriptlet throws a ReferenceError.
// The function scope also keeps both names off the page's global object.
//
// Ported from Brave's kScriptletGlobalsScript
// (brave-core/components/cosmetic_filters/common/scriptlet_constants.cc):
//   Copyright (c) 2026 The Brave Authors. All rights reserved.
//   This Source Code Form is subject to the terms of the Mozilla Public
//   License, v. 2.0. If a copy of the MPL was not distributed with this file,
//   You can obtain one at https://mozilla.org/MPL/2.0/.
// `canDebug` is left unset (Brave sets it only behind a scriptlet-debug flag),
// and de-AMP is off until that feature exists.
static String wrapScriptletWithGlobals(const String& script)
{
    return makeString(
        "(function() {"
            "const scriptletGlobals = (() => {"
                "const forwardedMapMethods = [\"has\", \"get\", \"set\"];"
                "const handler = {"
                    "get(target, prop) {"
                        "if (forwardedMapMethods.includes(prop))"
                            " return Map.prototype[prop].bind(target);"
                        "return target.get(prop);"
                    "},"
                    "set(target, prop, value) {"
                        "if (!forwardedMapMethods.includes(prop))"
                            " target.set(prop, value);"
                        // A Proxy set trap must report success, or strict-mode
                        // assignments throw.
                        "return true;"
                    "}"
                "};"
                "return new Proxy(new Map(), handler);"
            "})();"
            "let deAmpEnabled = false;\n"_s,
        script,
        "\n})();"_s);
}

// Injected into the adblock isolated world at document start. Observes the DOM for
// class/id tokens (initial scan + MutationObserver), de-duplicates locally, batches
// on an animation frame, and hands each batch to the native `report` callback passed
// in as an argument (never exposed on a global, so page scripts cannot reach it).
static ASCIILiteral dynamicHidingAgentSource()
{
    return "(function(report) {"
        "\"use strict\";"
        // Bounded seen-token set (same two-generation scheme as the native
        // RecentTokenSet): a long-lived single-page app can cycle through unbounded
        // distinct tokens over one document. Returns true for a token not recently
        // seen; a token found in the previous generation is promoted.
        "function recent() {"
            "var cur = new Set(), prev = new Set();"
            "return function(t) {"
                "if (cur.has(t)) return false;"
                "var isNew = !prev.delete(t);"
                "if (cur.size >= 4096) { prev = cur; cur = new Set(); }"
                "cur.add(t);"
                "return isNew;"
            "};"
        "}"
        "var seenC = recent(), seenI = recent();"
        "var pendC = [], pendI = [], scheduled = false;"
        "function collect(el) {"
            "if (!el || el.nodeType !== 1) return;"
            "var cl = el.classList, i;"
            "if (cl) for (i = 0; i < cl.length; i++) { var t = cl[i]; if (t && seenC(t)) pendC.push(t); }"
            "var id = el.id;"
            "if (id && seenI(id)) pendI.push(id);"
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
            // requestAnimationFrame coalesces the flush with paint on a visible
            // document, but it does not fire on a non-visible one (a background tab or
            // an offscreen test page), which would strand every collected token. Arm a
            // timer fallback as well: whichever fires first flushes, and the other
            // finds the pending buffers empty and no-ops.
            "var raf = window.requestAnimationFrame;"
            "if (raf) raf(flush);"
            "setTimeout(flush, 16);"
        "}"
        // Follow-up (perf, not correctness): on pathological high-churn pages this
        // observer callback fires on every mutation batch. Brave's content_cosmetic.ts
        // scores mutation volume and, past a threshold, disconnects the observer for
        // periodic full-document querySelectorAll polling (returning to the observer
        // after ~10s). Not ported: the query/IPC cost is already bounded here by the
        // timer-batched flush + seen-token de-dup and by the NetworkProcess
        // token budget, so only add the polling switch if profiling shows this callback
        // hot on real pages.
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

bool AdBlockPageAgent::RecentTokenSet::add(const String& token)
{
    if (m_current.contains(token))
        return false;
    bool isNewToken = !m_previous.remove(token);
    if (m_current.size() >= maxGenerationSize)
        m_previous = std::exchange(m_current, { });
    m_current.add(token);
    return isNewToken;
}

void AdBlockPageAgent::RecentTokenSet::remove(const String& token)
{
    m_current.remove(token);
    m_previous.remove(token);
}

AdBlockPageAgent::AdBlockPageAgent()
    : m_dynamicHidingRetryTimer(RunLoop::mainSingleton(), "AdBlockPageAgent::DynamicHidingRetryTimer"_s, this, &AdBlockPageAgent::retryThrottledTokens)
{
}

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
    frame.script().executeScriptInWorldIgnoringException(world, wrapScriptletWithGlobals(script), JSC::SourceTaintedOrigin::Untainted);
}

void AdBlockPageAgent::setDynamicHidingEnabled(WebCore::FrameIdentifier frameID, Vector<String>&& exceptions)
{
    auto state = makeUniqueRef<FrameDynamicState>();
    state->generation = ++m_nextDynamicStateGeneration;
    state->exceptions = WTF::move(exceptions);
    m_frameDynamicState.set(frameID, WTF::move(state));
}

void AdBlockPageAgent::clearDynamicHiding(WebCore::FrameIdentifier frameID)
{
    m_frameDynamicState.remove(frameID);
}

auto AdBlockPageAgent::dynamicState(WebCore::FrameIdentifier frameID, uint64_t generation) -> FrameDynamicState*
{
    auto it = m_frameDynamicState.find(frameID);
    if (it == m_frameDynamicState.end() || it->value->generation != generation)
        return nullptr;
    return it->value.ptr();
}

void AdBlockPageAgent::injectDynamicHidingAgentIfNeeded(WebFrame& webFrame, WebCore::DOMWrapperWorld& world)
{
    // The agent lives in the adblock isolated world, but document start is signalled
    // by the main world's window-object setup, so trigger off the normal world only.
    if (!world.isNormal())
        return;

    auto it = m_frameDynamicState.find(webFrame.frameID());
    if (it == m_frameDynamicState.end() || it->value->agentInjected)
        return;
    it->value->agentInjected = true;

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
    auto it = m_frameDynamicState.find(webFrame.frameID());
    if (it == m_frameDynamicState.end())
        return;
    auto& state = it->value.get();

    // Authoritative de-duplication: only tokens not recently queried for this frame
    // cross the IPC boundary.
    Vector<String> newClasses;
    for (auto& token : classes) {
        if (!token.isEmpty() && state.seenClasses.add(token))
            newClasses.append(token);
    }
    Vector<String> newIds;
    for (auto& token : ids) {
        if (!token.isEmpty() && state.seenIds.add(token))
            newIds.append(token);
    }
    queryDynamicTokens(webFrame, state, WTF::move(newClasses), WTF::move(newIds));
}

void AdBlockPageAgent::queryDynamicTokens(WebFrame& webFrame, FrameDynamicState& state, Vector<String>&& classes, Vector<String>&& ids)
{
    if (classes.isEmpty() && ids.isEmpty())
        return;

    RefPtr coreFrame = webFrame.coreLocalFrame();
    if (!coreFrame)
        return;
    RefPtr document = coreFrame->document();
    if (!document)
        return;
    RefPtr webPage = webFrame.page();
    if (!webPage)
        return;

    auto frameID = webFrame.frameID();
    // The per-site allowlist keys on the top-level document's host, so a
    // subframe reports its tab's site rather than its own.
    auto siteHostname = document->topOrigin().host();

    // Key the NetworkProcess-side rate limiter per page (see AdBlockDynamicHidingLimiter),
    // so one busy page cannot exhaust the budget for the others sharing this connection.
    auto pageID = webPage->webPageProxyIdentifier();

    Ref connection = WebProcess::singleton().ensureNetworkProcessConnection().connection();
    size_t classIndex = 0;
    size_t idIndex = 0;
    while (classIndex < classes.size() || idIndex < ids.size()) {
        size_t classCount = std::min(classes.size() - classIndex, maxTokensPerQuery);
        size_t idCount = std::min(ids.size() - idIndex, maxTokensPerQuery - classCount);
        auto chunkClasses = classes.subvector(classIndex, classCount);
        auto chunkIds = ids.subvector(idIndex, idCount);
        classIndex += classCount;
        idIndex += idCount;

        // The tokens are copied into the reply handler too: if the query is throttled
        // they are held for a retry rather than lost (the injected agent never
        // reports a token twice, so this is the only chance to query it).
        connection->sendWithAsyncReply(Messages::NetworkConnectionToWebProcess::HiddenClassIdSelectors(pageID, chunkClasses, chunkIds, state.exceptions, siteHostname), [weakThis = WeakPtr { *this }, frameID, generation = state.generation, protectedFrame = Ref { webFrame }, weakDocument = WeakPtr { *document }, chunkClasses, chunkIds](Vector<String>&& selectors, std::optional<Seconds> retryAfter) mutable {
            if (!weakThis)
                return;
            // Drop the reply if the frame navigated away: the state was cleared, or the
            // document that observed these tokens is no longer the frame's document.
            RefPtr document = weakDocument.get();
            RefPtr coreFrame = protectedFrame->coreLocalFrame();
            if (!document || !coreFrame || coreFrame->document() != document.get())
                return;
            if (retryAfter) {
                weakThis->handleThrottledTokens(frameID, generation, WTF::move(chunkClasses), WTF::move(chunkIds), *retryAfter);
                return;
            }
            if (!selectors.isEmpty())
                weakThis->applyDynamicSelectors(protectedFrame, frameID, generation, selectors);
        });
    }
}

void AdBlockPageAgent::handleThrottledTokens(WebCore::FrameIdentifier frameID, uint64_t generation, Vector<String>&& classes, Vector<String>&& ids, Seconds retryAfter)
{
    auto* state = dynamicState(frameID, generation);
    if (!state)
        return;

    auto hold = [](ListHashSet<String>& backlog, RecentTokenSet& seen, Vector<String>&& tokens) {
        for (auto& token : tokens) {
            if (backlog.size() < maxThrottledTokensPerFrame)
                backlog.add(WTF::move(token));
            else
                seen.remove(token);
        }
    };
    hold(state->throttledClasses, state->seenClasses, WTF::move(classes));
    hold(state->throttledIds, state->seenIds, WTF::move(ids));

    // Every frame's backlog is retried by one timer; keep the earliest deadline.
    auto delay = std::max(retryAfter, minimumRetryDelay);
    if (!m_dynamicHidingRetryTimer.isActive() || delay < m_dynamicHidingRetryTimer.secondsUntilFire())
        m_dynamicHidingRetryTimer.startOneShot(delay);
}

void AdBlockPageAgent::retryThrottledTokens()
{
    for (auto& [frameID, entry] : m_frameDynamicState) {
        auto& state = entry.get();
        if (state.throttledClasses.isEmpty() && state.throttledIds.isEmpty())
            continue;
        auto classes = moveToVector(std::exchange(state.throttledClasses, { }));
        auto ids = moveToVector(std::exchange(state.throttledIds, { }));
        // The frame state is cleared on every provisional load, so a surviving entry
        // still belongs to the document that observed these tokens.
        RefPtr webFrame = WebProcess::singleton().webFrame(frameID);
        if (!webFrame)
            continue;
        queryDynamicTokens(*webFrame, state, WTF::move(classes), WTF::move(ids));
    }
}

void AdBlockPageAgent::applyDynamicSelectors(WebFrame& webFrame, WebCore::FrameIdentifier frameID, uint64_t generation, const Vector<String>& selectors)
{
    auto* state = dynamicState(frameID, generation);
    if (!state)
        return;

    RefPtr coreFrame = webFrame.coreLocalFrame();
    if (!coreFrame)
        return;
    RefPtr document = coreFrame->document();
    if (!document)
        return;

#if ENABLE(CONTENT_EXTENSIONS)
    for (auto& selector : selectors) {
        if (selector.isEmpty() || !state->appliedSelectors.add(selector).isNewEntry)
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
