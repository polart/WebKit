// Copyright (C) 2026 Artem Polunin.
// SPDX-License-Identifier: MPL-2.0
//
// A trackpad pinch or rotate, as WebCore sees it. Apple ships this class only
// in its internal SDK (WebKitAdditions); this is an open reimplementation of
// the interface the open-source code expects (see WebEventConversion.cpp and
// PlatformWheelEvent::createFromGesture()).

#pragma once

#if ENABLE(MAC_GESTURE_EVENTS)

#include <WebCore/IntPoint.h>
#include <WebCore/MouseEventTypes.h>
#include <WebCore/PlatformEvent.h>

namespace WebCore {

class PlatformGestureEvent : public PlatformEvent {
public:
    PlatformGestureEvent()
        : PlatformEvent(Type::GestureStart)
    {
    }

    // In root view coordinates.
    const IntPoint& pos() const { return m_position; }
    const IntPoint& globalPosition() const { return m_globalPosition; }

    // Change in magnification since the previous event of the gesture
    // (-[NSEvent magnification]), not the cumulative scale.
    float gestureScale() const { return m_gestureScale; }

    // Change in rotation since the previous event of the gesture, in degrees,
    // counterclockwise positive (-[NSEvent rotation]).
    float gestureRotation() const { return m_gestureRotation; }

    MouseEventInputSource inputSource() const { return m_inputSource; }

protected:
    IntPoint m_position;
    IntPoint m_globalPosition;
    float m_gestureScale { 0 };
    float m_gestureRotation { 0 };
    MouseEventInputSource m_inputSource { MouseEventInputSource::UserDriven };
};

} // namespace WebCore

#endif // ENABLE(MAC_GESTURE_EVENTS)
