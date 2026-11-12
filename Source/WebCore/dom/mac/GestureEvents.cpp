/*
 * Copyright (C) 2015 Apple Inc. All rights reserved.
 * Copyright (C) 2026 Artem Polunin.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY APPLE INC. AND ITS CONTRIBUTORS ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO,
 * THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 * PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL APPLE INC. OR ITS CONTRIBUTORS
 * BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF
 * THE POSSIBILITY OF SUCH DAMAGE.
 */

// The internal SDK build includes Apple's GestureEvent.cpp from WebKitAdditions
// here. This fork implements it in the open; see GestureEvent.h.

#include "config.h"

#if ENABLE(MAC_GESTURE_EVENTS)

#include "GestureEvent.h"

#include "PlatformGestureEventMac.h"
#include <wtf/TZoneMallocInlines.h>

namespace WebCore {

WTF_MAKE_TZONE_ALLOCATED_IMPL(GestureEvent);

inline GestureEvent::GestureEvent()
    : MouseRelatedEvent(EventInterfaceType::GestureEvent)
{
}

inline GestureEvent::GestureEvent(const AtomString& type, const PlatformGestureEvent& event, RefPtr<WindowProxy>&& view, double scale, double rotation)
    : MouseRelatedEvent(
        EventInterfaceType::GestureEvent,
        type,
        CanBubble::Yes,
        IsCancelable::Yes,
        IsComposed::Yes,
        event.timestamp(),
        WTF::move(view),
        0,
        event.globalPosition(),
        event.pos(),
        0,
        0,
        event.modifiers(),
        IsSimulated::No,
        IsTrusted::Yes)
    , m_scale(scale)
    , m_rotation(rotation)
{
}

Ref<GestureEvent> GestureEvent::create(const AtomString& type, const PlatformGestureEvent& event, RefPtr<WindowProxy>&& view, double scale, double rotation)
{
    return adoptRef(*new GestureEvent(type, event, WTF::move(view), scale, rotation));
}

Ref<GestureEvent> GestureEvent::createForBindings()
{
    return adoptRef(*new GestureEvent);
}

void GestureEvent::initGestureEvent(const AtomString& type, bool canBubble, bool cancelable, RefPtr<WindowProxy>&& view, int detail,
    double screenX, double screenY, double clientX, double clientY,
    bool ctrlKey, bool altKey, bool shiftKey, bool metaKey,
    RefPtr<EventTarget>&&, double scale, double rotation)
{
    if (isBeingDispatched())
        return;

    if (!std::isfinite(clientX))
        clientX = 0;
    if (!std::isfinite(clientY))
        clientY = 0;
    if (!std::isfinite(screenX))
        screenX = 0;
    if (!std::isfinite(screenY))
        screenY = 0;

    initUIEvent(type, canBubble, cancelable, WTF::move(view), detail);

    setScreenLocation({ screenX, screenY });
    setModifierKeys(ctrlKey, altKey, shiftKey, metaKey);
    initCoordinates({ clientX, clientY });

    // The target argument is accepted for compatibility with Safari's signature
    // and ignored: dispatchEvent() sets the target.
    m_scale = scale;
    m_rotation = rotation;
}

} // namespace WebCore

#endif // ENABLE(MAC_GESTURE_EVENTS)
