// Copyright (C) 2026 Artem Polunin.
// SPDX-License-Identifier: MPL-2.0
//
// Dispatches trackpad pinch and rotate gestures to the page, like Safari does
// on macOS. Apple ships this part of EventHandler only in its internal SDK
// (WebKitAdditions); this is an open reimplementation. EventHandlerMac.mm
// includes this file.
//
// For each gesture event from the UI process:
// 1. On gesturestart, hit-test once and keep that target for the rest of the
//    gesture.
// 2. Fire gesturestart / gesturechange / gestureend at it.
// 3. If the page didn't cancel that, fire a synthetic wheel event with
//    ctrlKey set, the way Chrome and Firefox report a pinch, so sites written
//    for those browsers can zoom too.
// 4. Report the event as handled if the page canceled either one. Otherwise
//    the UI process falls back to zooming the whole page.

#if ENABLE(MAC_GESTURE_EVENTS)

#import "GestureEvent.h"
#import "HTMLFrameOwnerElement.h"
#import "HitTestResult.h"
#import "PlatformGestureEventMac.h"

namespace WebCore {

// Matches Safari: a magnification of 0.01 becomes a DOM wheel deltaY of -1.
// PlatformWheelEvent deltas have the opposite sign to the DOM's deltaY, so
// pinching out (zoom in) gives a positive platform delta here.
static constexpr double gestureMagnificationToWheelDelta = 100;

static RefPtr<RemoteFrame> remoteFrameForGestureTarget(EventTarget* target)
{
    RefPtr node = dynamicDowncast<Node>(target);
    RefPtr owner = node ? dynamicDowncast<HTMLFrameOwnerElement>(*node) : nullptr;
    return owner ? dynamicDowncast<RemoteFrame>(owner->contentFrame()) : nullptr;
}

bool EventHandler::dispatchGestureEvent(const PlatformGestureEvent& platformEvent, const AtomString& eventType, const EventTargetSet& targets, float scale, float rotation)
{
    bool defaultPrevented = false;
    for (auto& target : targets) {
        RefPtr node = dynamicDowncast<Node>(target.get());
        if (!node)
            continue;
        Ref event = GestureEvent::create(eventType, platformEvent, protect(node->document())->windowProxy(), scale, rotation);
        node->dispatchEvent(event);
        defaultPrevented |= event->defaultPrevented();
    }
    return defaultPrevented;
}

HandleUserInputEventResult EventHandler::handleGestureEvent(const PlatformGestureEvent& event)
{
    Ref frame = m_frame.get();
    RefPtr view = frame->view();
    if (!view || !frame->document())
        return false;

    AtomString eventType;
    switch (event.type()) {
    case PlatformEvent::Type::GestureStart:
        eventType = eventNames().gesturestartEvent;
        break;
    case PlatformEvent::Type::GestureChange:
        eventType = eventNames().gesturechangeEvent;
        break;
    case PlatformEvent::Type::GestureEnd:
        eventType = eventNames().gestureendEvent;
        break;
    default:
        ASSERT_NOT_REACHED();
        return false;
    }

    IntPoint pointInContents = view->windowToContents(event.pos());

    if (event.type() == PlatformEvent::Type::GestureStart) {
        m_gestureTargets.clear();
        // Shared with iOS, where these hold finger geometry. Here they hold the
        // cumulative scale and rotation that GestureEvent exposes.
        m_gestureLastDiameter = 1;
        m_gestureLastRotation = 0;

        HitTestResult result = hitTestResultAtPoint(pointInContents, { HitTestRequest::Type::ReadOnly, HitTestRequest::Type::DisallowUserAgentShadowContent, HitTestRequest::Type::AllowChildFrameContent });
        RefPtr<EventTarget> target = result.targetElement();
        if (!target)
            target = protect(frame->document())->documentElement();
        if (!target)
            return false;

        m_gestureTargets.add(WTF::move(target));
        m_hasActiveGesture = true;
    } else if (!m_hasActiveGesture) {
        // The gesture began before this frame saw it, or ended early because the
        // UI process took it over for page zoom (see didEndMagnificationGesture()).
        return false;
    }

    if (event.type() == PlatformEvent::Type::GestureEnd)
        m_hasActiveGesture = false;

    EventTargetSet targets = m_gestureTargets;
    if (!m_hasActiveGesture)
        m_gestureTargets.clear();

    // A cross-origin iframe in another process: send the gesture there. It
    // re-runs this from its own root frame, at the transformed point.
    for (auto& target : targets) {
        if (RefPtr remoteFrame = remoteFrameForGestureTarget(target.get())) {
            if (auto remoteData = userInputEventDataForRemoteFrame(remoteFrame.get(), pointInContents))
                return *remoteData;
            return false;
        }
    }

    // Magnification compounds, as in AppKit: each event scales the previous result.
    m_gestureLastDiameter *= 1 + event.gestureScale();
    // NSEvent rotation is counterclockwise positive; GestureEvent's is clockwise.
    m_gestureLastRotation -= event.gestureRotation();

    if (dispatchGestureEvent(event, eventType, targets, m_gestureLastDiameter, m_gestureLastRotation))
        return true;

    // Rotation-only events carry no magnification, so they have nothing to say
    // as a wheel event.
    if (!event.gestureScale())
        return false;

    auto wheelEvent = PlatformWheelEvent::createFromGesture(event, event.gestureScale() * gestureMagnificationToWheelDelta);
    bool wheelDefaultPrevented = false;
    for (auto& target : targets) {
        RefPtr node = dynamicDowncast<Node>(target.get());
        RefPtr element = node ? dynamicDowncast<Element>(*node) : nullptr;
        if (!element || !element->isConnected())
            continue;
        OptionSet<EventHandling> handling;
        element->dispatchWheelEvent(wheelEvent, handling, Event::IsCancelable::Yes);
        wheelDefaultPrevented |= handling.contains(EventHandling::DefaultPrevented);
    }
    return wheelDefaultPrevented;
}

void EventHandler::didEndMagnificationGesture()
{
    m_hasActiveGesture = false;
    m_gestureTargets.clear();
    m_gestureLastDiameter = GestureUnknown;
    m_gestureLastRotation = GestureUnknown;
}

} // namespace WebCore

#endif // ENABLE(MAC_GESTURE_EVENTS)
