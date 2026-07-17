// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// AdBlockCosmeticResources is the cross-process shape of adblock-rust's
// url_cosmetic_resources output for a document/subframe navigation: the CSS
// hide selectors applied before first paint (U6), the scriptlet source injected
// at document start (U7), and the generic-rule exception set plus generichide
// flag the dynamic hiding agent needs (U8). It is computed and parsed on the
// NetworkProcess work queue (see AdBlockCosmeticResourceParser) during the same
// request check that fetches the CSP directives, carried on NetworkLoadChecker,
// and delivered to the WebProcess with the navigation response
// (WebResourceLoader::SetAdBlockCosmeticResources). The fields cross the process
// boundary as message arguments, so this struct needs no IPC coder of its own;
// both sides reconstruct it from those arguments.

#pragma once

#if ENABLE(ADBLOCK)

#include <wtf/Vector.h>
#include <wtf/text/WTFString.h>

namespace WebKit {

struct AdBlockCosmeticResources {
    // CSS selectors to hide with `display: none !important` before first paint
    // (U6). Site-specific plus generic rules the engine already resolved for the
    // navigation URL.
    Vector<String> hideSelectors;
    // Class/id selectors excepted from generic hiding (`#@#`); the dynamic agent
    // must not re-hide these when it queries newly seen tokens (U8).
    Vector<String> exceptions;
    // Scriptlet JavaScript to run at document start (U7). Empty when no matched
    // filter injects a scriptlet.
    String injectedScript;
    // True when a `$generichide` exception applies: the page should not query for
    // additional generic hide selectors (U8).
    bool generichide { false };
    // True when adblock is active for this navigation (engine loaded, host not
    // allowlisted) and `$generichide` does not apply, so the web process should
    // run the mutation-driven dynamic-hiding agent (U8). Unlike the other fields
    // this is a run signal rather than payload, so it is excluded from isEmpty();
    // the delivery site sends the payload when it is set even if nothing else is.
    bool dynamicHidingEnabled { false };

    bool isEmpty() const
    {
        return hideSelectors.isEmpty() && exceptions.isEmpty() && injectedScript.isEmpty() && !generichide;
    }
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
