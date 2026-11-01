// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Adblock embedder API. Master toggle, filter-list subscription management,
// the filter list catalog, custom rules, and per-site allowlist, reached
// through -[WKWebsiteDataStore _adBlock] (`store.adBlock` in Swift).
//
// Config is persisted per data store in the NetworkProcess; -getStateWithCompletionHandler:
// reads it back as a _WKAdBlockState.
//
// Scope caveat: while each data store persists its own config, the underlying
// filter engine and its enable/allowlist gate are process-global — one engine
// per NetworkProcess, shared by every data store in that process. So
// enabling/disabling or editing the allowlist on one data store affects all
// sessions in the same NetworkProcess, last-writer-wins. Non-persistent
// (ephemeral) data stores keep no config and these calls are no-ops for them.
//
// Testing hooks live in _WKAdBlockForTesting.h, which WebKitPrivate.h does not
// include.

#import <Foundation/Foundation.h>
#import <WebKit/WKFoundation.h>
#import <WebKit/WKWebsiteDataStore.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

// A filter list added by URL with -addSubscriptionWithURL:expectedHash:.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(WKAdBlockSubscription)
WK_CLASS_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA), visionos(WK_XROS_TBA))
@interface _WKAdBlockSubscription : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSURL *URL;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
// The list's `! Title:` header, or empty if it has none or was never fetched.
@property (nonatomic, readonly, copy) NSString *title;
// nil if the list has never been fetched.
@property (nonatomic, readonly, nullable, copy) NSDate *lastFetched;

@end

// A list from the filter list catalog installed with -setCatalog:.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(WKAdBlockCatalogList)
WK_CLASS_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA), visionos(WK_XROS_TBA))
@interface _WKAdBlockCatalogList : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *uuid;
@property (nonatomic, readonly, copy) NSString *title;
// The catalog's `desc` field.
@property (nonatomic, readonly, copy) NSString *listDescription;
@property (nonatomic, readonly, nullable, copy) NSURL *supportURL;
// Language codes the list targets; empty for language-neutral lists.
@property (nonatomic, readonly, copy) NSArray<NSString *> *languages;
@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, getter=isDefaultEnabled) BOOL defaultEnabled;
// Hidden lists are always on and ignore -setCatalogListEnabled:forUUID:.
@property (nonatomic, readonly, getter=isHidden) BOOL hidden;
// nil if the list has never been fetched.
@property (nonatomic, readonly, nullable, copy) NSDate *lastFetched;

@end

// A snapshot of a data store's adblock config.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(WKAdBlockState)
WK_CLASS_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA), visionos(WK_XROS_TBA))
@interface _WKAdBlockState : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly, copy) NSString *customRules;
// Hosts ad blocking is turned off for (see -addAllowlistHost:).
@property (nonatomic, readonly, copy) NSArray<NSString *> *allowlist;
@property (nonatomic, readonly, copy) NSArray<_WKAdBlockSubscription *> *subscriptions;
@property (nonatomic, readonly, copy) NSArray<_WKAdBlockCatalogList *> *catalogLists;

@end

// Main-thread only, like the WKWebsiteDataStore it drives.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(WKAdBlockController)
WK_CLASS_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA), visionos(WK_XROS_TBA))
@interface _WKAdBlockController : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

// nil once the data store has been deallocated, after which every call is a
// no-op and -getStateWithCompletionHandler: reports nil.
@property (nonatomic, readonly, nullable, weak) WKWebsiteDataStore *dataStore;

// Master toggle. Defaults to off, so nothing is blocked until an embedder turns it on.
- (void)setEnabled:(BOOL)enabled;

- (void)addSubscriptionWithURL:(NSURL *)url expectedHash:(nullable NSString *)expectedHash NS_SWIFT_NAME(addSubscription(url:expectedHash:));
- (void)removeSubscriptionWithURL:(NSURL *)url NS_SWIFT_NAME(removeSubscription(url:));
- (void)setSubscriptionEnabled:(BOOL)enabled forURL:(NSURL *)url NS_SWIFT_NAME(setSubscriptionEnabled(_:url:));
// Re-downloads every enabled subscription.
- (void)refreshSubscriptions;

- (void)setCustomRules:(NSString *)rules;
// The scriptlet and redirect resource library (brave/adblock-resources resources.json).
- (void)setResources:(NSString *)resourcesJSON;

// The filter list catalog (brave/adblock-resources filter_lists/list_catalog.json).
// Installing it enables the catalog's default lists, preselects lists matching
// the system locale once per profile, and downloads each enabled list by
// concatenating its declared sources. The catalog itself is not persisted —
// supply it on every launch — but each list's enabled state and downloaded text
// are. The resulting lists are reported in _WKAdBlockState.catalogLists.
- (void)setCatalog:(NSString *)catalogJSON;
- (void)setCatalogListEnabled:(BOOL)enabled forUUID:(NSString *)uuid NS_SWIFT_NAME(setCatalogListEnabled(_:uuid:));
// Re-downloads every enabled catalog list.
- (void)refreshCatalogLists;

// Turns ad blocking off for pages whose top-level host is exactly `host`.
- (void)addAllowlistHost:(NSString *)host;
- (void)removeAllowlistHost:(NSString *)host;

// Reads the config back from the NetworkProcess. The reply travels the same
// connection as the setters above, so it also confirms that earlier changes
// have been applied. `state` is nil if the NetworkProcess could not be
// reached or its reply could not be read.
- (void)getStateWithCompletionHandler:(NS_SWIFT_UI_ACTOR void (^)(_WKAdBlockState * _Nullable state))completionHandler NS_SWIFT_ASYNC_NAME(state());

@end

@interface WKWebsiteDataStore (_WKAdBlock)

// The controller for this data store. It is created on first use and the same
// one is returned on every later call.
@property (nonatomic, readonly) _WKAdBlockController *_adBlock NS_SWIFT_NAME(adBlock) WK_API_AVAILABLE(macos(WK_MAC_TBA), ios(WK_IOS_TBA), visionos(WK_XROS_TBA));

@end

NS_HEADER_AUDIT_END(nullability, sendability)
