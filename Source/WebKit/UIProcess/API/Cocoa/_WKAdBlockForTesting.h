// Copyright (C) 2026 Artem Polunin.
// SPDX-License-Identifier: MPL-2.0
//
// Adblock testing hooks. Kept out of _WKAdBlock.h and WebKitPrivate.h so that
// embedders only see them with an explicit import:
//   #import <WebKit/_WKAdBlockForTesting.h>
//   import WebKit_Private._WKAdBlockForTesting

#import <WebKit/_WKAdBlock.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@interface _WKAdBlockController (ForTesting)

// Install `text` as the stored body for the list at `url` (adding the
// subscription if new) exactly as a successful download would, but without a
// network fetch — so the API tests can exercise multi-list assembly, warm/cold
// `.dat`, and persistence over the self-signed test proxy, which NetworkProcess
// list downloads cannot validate. Mirrors Brave's UpdateAdBlockInstanceWithRules.
- (void)_setListTextForTesting:(NSString *)text forURL:(NSURL *)url NS_SWIFT_NAME(_setListTextForTesting(_:url:)) WK_API_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA), visionos(WK_XROS_TBA));

// The running total of filter queries that actually reached the engine (an
// allowlisted host, a disabled master toggle, or a query issued before any list
// loaded never increments it). Process-global, not per data store. Used by the
// Dynamic-hiding tests to prove per-document token de-duplication.
- (void)_getEngineQueryCountForTestingWithCompletionHandler:(NS_SWIFT_UI_ACTOR void (^)(uint64_t))completionHandler NS_SWIFT_ASYNC_NAME(_engineQueryCountForTesting()) WK_API_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA), visionos(WK_XROS_TBA));

@end

NS_HEADER_AUDIT_END(nullability, sendability)
