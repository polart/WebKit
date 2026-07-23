# NewBrowser: Web Inspector Window

How the "Show Web Inspector" menu item (⌥⌘I) in NewBrowser opens the Web
Inspector, and the two non-obvious problems that had to be solved to make it
work. Relevant code lives in `Tools/NewBrowser/Source/ViewModel/BrowserViewModel.swift`.

NewBrowser hosts its page through the new SwiftUI `WebPage` / `WebView` API
rather than a plain AppKit `WKWebView`. That single difference is the root of
both problems below — MiniBrowser hits neither because its `WKWebView` sits
directly in an AppKit window.

## Problem 1: the inspector never opened

Calling `page.backingWebView._inspector.show()` did nothing — no window, no
error, no crash.

`WebPage.isInspectable = true` (which NewBrowser already set) only flips the
**remote** inspection flag: it is what lets Safari's Develop menu or a remote
inspector attach. It does *not* enable the **local** inspector frontend.

Opening the local frontend is gated by a separate preference,
`developerExtrasEnabled`. In `WebInspectorUIProxy::openLocalInspectorFrontend()`
(`Source/WebKit/UIProcess/Inspector/WebInspectorUIProxy.cpp`):

```cpp
if (!protect(inspectedPage->preferences())->developerExtrasEnabled())
    return;   // silently bails — no window, no error
```

Because the preference was never set, `show()` returned early. MiniBrowser works
because it sets **both** flags — `_webView.inspectable = YES` *and*
`configuration.preferences._developerExtrasEnabled = YES`.

**Fix** — enable developer extras alongside `isInspectable` in `init()`:

```swift
self.page.isInspectable = true
self.page.backingWebView.configuration.preferences._developerExtrasEnabled = true
```

## Problem 2: the inspector opened but rendered as an empty grey box

With developer extras enabled, `show()` opened the inspector, but it appeared as
an empty grey strip docked at the bottom of the page.

`show()` opens the inspector **docked (attached)** by default —
`inspectorStartsAttached` defaults to `true`. On macOS, docking inserts the
inspector's `NSView` as a sibling of the inspected view inside that view's
**superview**, then manually resizes both to share the space
(`WebInspectorUIProxy::platformAttach()`):

```cpp
// inspectorAttachmentView() defaults to the WKWebView itself (backingWebView)
[inspectedView.superview addSubview:inspectorView positioned:NSWindowBelow relativeTo:inspectedView];
```

For NewBrowser, `backingWebView`'s superview is owned and laid out by SwiftUI's
`WebView`. SwiftUI does not know about the manually-inserted, manually-framed
inspector view, so it never gets a usable drawing area — hence the empty grey
box.

**Fix** — force the inspector into its own detached top-level window, which
renders independently of the SwiftUI hierarchy. Use the supported
`_WKInspectorDelegate.inspectorFrontendLoaded:` hook to call `detach()` once the
frontend is up:

```swift
private final class InspectorDelegate: NSObject, _WKInspectorDelegate {
    func inspectorFrontendLoaded(_ inspector: _WKInspector!) {
        inspector.detach()
    }
}
```

`detach()` also persists `inspectorStartsAttached = false`, so subsequent opens
go straight to a detached window.

### Why the delegate, and not `detach()` right after `show()`

`show()` is asynchronous. It calls `connect()`, which sends a `Show()` IPC
message to the web process; the actual attach/open work (`m_isVisible = true`,
`platformAttach()`) happens later in that message's async reply and then again
when the loaded frontend asks to be brought to the front. Calling `detach()`
synchronously after `show()` runs too early — `m_isVisible` is still `false`, so
`detach()` neither opens a window nor persists the preference, and the async path
then re-docks.

`inspectorFrontendLoaded:` fires after the frontend has loaded, which is the
correct moment. Whichever order the frontend's `bringToFront` and
`FrontendLoaded` messages arrive in, the end state is a detached window:

- `bringToFront` first → `open()` docks, then `detach()` pops it to a window and
  persists the preference (subsequent opens skip docking entirely).
- `FrontendLoaded` first → `detach()` clears the attached flag, then `open()`
  sees it and creates the detached window directly.

On the very first open you may briefly see the docked grey box flash before it
pops out to a window; it is self-correcting after that.

### Note: `_WKInspector.delegate` is weak

The delegate must be owned elsewhere, so `BrowserViewModel` holds a strong
reference (`private let inspectorDelegate = InspectorDelegate()`).

## Takeaways

- `isInspectable` (remote) and `developerExtrasEnabled` (local frontend) are
  independent — a local inspector needs both.
- Docked inspector attachment reparents an `NSView` into the inspected view's
  superview. That is incompatible with a SwiftUI-hosted `WebPage`; open the
  inspector **detached**.
- `show()` is async; drive attach/detach changes from
  `_WKInspectorDelegate.inspectorFrontendLoaded:`, not inline after `show()`.
