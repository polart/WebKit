// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See _WKAdBlock.h.

#if !__has_feature(objc_arc)
#error This file requires ARC. Add the "-fobjc-arc" compiler flag for this file.
#endif

#import "config.h"
#import "_WKAdBlock.h"

#import "WKWebsiteDataStoreInternal.h"
#import "_WKAdBlockForTesting.h"
#import <objc/runtime.h>
#import <wtf/BlockPtr.h>
#import <wtf/RetainPtr.h>
#import <wtf/URL.h>
#import <wtf/WeakObjCPtr.h>
#import <wtf/cocoa/VectorCocoa.h>
#import <wtf/text/WTFString.h>

#if ENABLE(ADBLOCK)
#import "Shared/AdBlock/AdBlockState.h"

// `lastFetched` is seconds since the epoch, with 0 meaning "never fetched".
static NSDate *lastFetchedDate(double seconds)
{
    return seconds > 0 ? [NSDate dateWithTimeIntervalSince1970:seconds] : nil;
}
#endif

@implementation _WKAdBlockSubscription

#if ENABLE(ADBLOCK)
- (instancetype)_initWithState:(const WebKit::AdBlockSubscriptionState&)state
{
    // A URL the NetworkProcess stored but that is no longer valid cannot be
    // shown or removed, so leave it out.
    if (!state.url.isValid())
        return nil;

    if (!(self = [super init]))
        return nil;

    _URL = state.url.createNSURL().get();
    _enabled = state.enabled;
    _title = state.title.createNSString().get();
    _lastFetched = lastFetchedDate(state.lastFetched);

    return self;
}
#endif

@end

@implementation _WKAdBlockCatalogList

#if ENABLE(ADBLOCK)
- (instancetype)_initWithState:(const WebKit::AdBlockCatalogListState&)state
{
    if (state.uuid.isEmpty())
        return nil;

    if (!(self = [super init]))
        return nil;

    _uuid = state.uuid.createNSString().get();
    _title = state.title.createNSString().get();
    _listDescription = state.description.createNSString().get();
    _supportURL = state.supportURL.isEmpty() ? nil : [NSURL URLWithString:state.supportURL.createNSString().get()];
    _languages = createNSArray(state.languages).get();
    _enabled = state.enabled;
    _defaultEnabled = state.defaultEnabled;
    _hidden = state.hidden;
    _lastFetched = lastFetchedDate(state.lastFetched);

    return self;
}
#endif

@end

@implementation _WKAdBlockState

#if ENABLE(ADBLOCK)
- (instancetype)_initWithState:(const WebKit::AdBlockState&)state
{
    if (!(self = [super init]))
        return nil;

    _enabled = state.enabled;
    _customRules = state.customRules.createNSString().get();
    _allowlist = createNSArray(state.allowlist).get();
    _subscriptions = createNSArray(state.subscriptions, [](auto& subscription) {
        return [[_WKAdBlockSubscription alloc] _initWithState:subscription];
    }).get();
    _catalogLists = createNSArray(state.catalogLists, [](auto& list) {
        return [[_WKAdBlockCatalogList alloc] _initWithState:list];
    }).get();

    return self;
}
#endif

@end

@implementation _WKAdBlockController {
    // Weak because the data store caches this controller (see -_adBlock).
    WeakObjCPtr<WKWebsiteDataStore> _dataStore;
}

- (instancetype)_initWithDataStore:(WKWebsiteDataStore *)dataStore
{
    if (!(self = [super init]))
        return nil;

    _dataStore = dataStore;

    return self;
}

- (WKWebsiteDataStore *)dataStore
{
    return _dataStore.get().get();
}

#if ENABLE(ADBLOCK)
- (RefPtr<WebKit::WebsiteDataStore>)_websiteDataStore
{
    RetainPtr dataStore = _dataStore.get();
    if (!dataStore)
        return nullptr;
    return protect(*dataStore->_websiteDataStore);
}
#endif

- (void)setEnabled:(BOOL)enabled
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->setAdBlockEnabled(enabled);
#endif
}

- (void)addSubscriptionWithURL:(NSURL *)url expectedHash:(NSString *)expectedHash
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->addAdBlockSubscription(URL { url }, expectedHash ?: @"");
#endif
}

- (void)removeSubscriptionWithURL:(NSURL *)url
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->removeAdBlockSubscription(URL { url });
#endif
}

- (void)setSubscriptionEnabled:(BOOL)enabled forURL:(NSURL *)url
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->setAdBlockSubscriptionEnabled(URL { url }, enabled);
#endif
}

- (void)refreshSubscriptions
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->refreshAdBlockSubscriptions();
#endif
}

- (void)setCustomRules:(NSString *)rules
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->setAdBlockCustomRules(rules);
#endif
}

- (void)setResources:(NSString *)resourcesJSON
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->setAdBlockResources(resourcesJSON);
#endif
}

- (void)setCatalog:(NSString *)catalogJSON
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->setAdBlockCatalog(catalogJSON);
#endif
}

- (void)setCatalogListEnabled:(BOOL)enabled forUUID:(NSString *)uuid
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->setAdBlockCatalogListEnabled(uuid, enabled);
#endif
}

- (void)refreshCatalogLists
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->refreshAdBlockCatalogLists();
#endif
}

- (void)addAllowlistHost:(NSString *)host
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->addAdBlockAllowlistHost(host);
#endif
}

- (void)removeAllowlistHost:(NSString *)host
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->removeAdBlockAllowlistHost(host);
#endif
}

- (void)getStateWithCompletionHandler:(void (^)(_WKAdBlockState *))completionHandler
{
#if ENABLE(ADBLOCK)
    RefPtr dataStore = [self _websiteDataStore];
    if (!dataStore) {
        completionHandler(nil);
        return;
    }
    // The reply is std::nullopt when the NetworkProcess has no store for this
    // session or the connection failed before it replied.
    dataStore->adBlockState([completionHandler = makeBlockPtr(completionHandler)](std::optional<WebKit::AdBlockState>&& state) {
        completionHandler(state ? [[_WKAdBlockState alloc] _initWithState:*state] : nil);
    });
#else
    completionHandler(nil);
#endif
}

- (void)_setListTextForTesting:(NSString *)text forURL:(NSURL *)url
{
#if ENABLE(ADBLOCK)
    if (RefPtr dataStore = [self _websiteDataStore])
        dataStore->setAdBlockListText(URL { url }, text);
#endif
}

- (void)_getEngineQueryCountForTestingWithCompletionHandler:(void (^)(uint64_t))completionHandler
{
#if ENABLE(ADBLOCK)
    RefPtr dataStore = [self _websiteDataStore];
    if (!dataStore) {
        completionHandler(0);
        return;
    }
    dataStore->adBlockEngineQueryCount([completionHandler = makeBlockPtr(completionHandler)](uint64_t count) {
        completionHandler(count);
    });
#else
    completionHandler(0);
#endif
}

@end

static void *adBlockControllerKey = &adBlockControllerKey;

@implementation WKWebsiteDataStore (_WKAdBlock)

- (_WKAdBlockController *)_adBlock
{
    // Created on first use and kept for the data store's lifetime. Stored as an
    // associated object so the WKWebsiteDataStore ivars stay untouched.
    if (_WKAdBlockController *controller = objc_getAssociatedObject(self, adBlockControllerKey))
        return controller;

    _WKAdBlockController *controller = [[_WKAdBlockController alloc] _initWithDataStore:self];
    objc_setAssociatedObject(self, adBlockControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return controller;
}

@end
