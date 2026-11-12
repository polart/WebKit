// Copyright (C) 2026 Artem Polunin.
// SPDX-License-Identifier: MPL-2.0
//
// The DOM event Safari fires for a trackpad pinch or rotate on macOS
// (gesturestart, gesturechange, gestureend). Apple ships its implementation
// only in its internal SDK (WebKitAdditions); this is an open reimplementation
// of the same web-facing API.

#pragma once

#if ENABLE(MAC_GESTURE_EVENTS)

#include "MouseRelatedEvent.h"

namespace WebCore {

class PlatformGestureEvent;

class GestureEvent final : public MouseRelatedEvent {
    WTF_MAKE_TZONE_ALLOCATED(GestureEvent);
public:
    // `scale` and `rotation` are the cumulative values since the gesture began:
    // scale starts at 1, rotation at 0 degrees (clockwise positive).
    static Ref<GestureEvent> create(const AtomString& type, const PlatformGestureEvent&, RefPtr<WindowProxy>&&, double scale, double rotation);
    static Ref<GestureEvent> createForBindings();

    void initGestureEvent(const AtomString& type, bool canBubble, bool cancelable, RefPtr<WindowProxy>&&, int detail,
        double screenX, double screenY, double clientX, double clientY,
        bool ctrlKey, bool altKey, bool shiftKey, bool metaKey,
        RefPtr<EventTarget>&&, double scale, double rotation);

    double scale() const { return m_scale; }
    double rotation() const { return m_rotation; }

private:
    GestureEvent();
    GestureEvent(const AtomString& type, const PlatformGestureEvent&, RefPtr<WindowProxy>&&, double scale, double rotation);

    double m_scale { 1 };
    double m_rotation { 0 };
};

} // namespace WebCore

SPECIALIZE_TYPE_TRAITS_EVENT(GestureEvent)

#endif // ENABLE(MAC_GESTURE_EVENTS)
