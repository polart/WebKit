# Adblocker Defaults: Enablement, Default Lists, and Updates

This document describes how Brave's ad blocker behaves out of the box: whether
it is enabled by default, which filter lists ship enabled, and how/when lists
are fetched and updated. For the Rust engine and FFI internals, see
[Adblock-Rust Integration](adblock_rust_integration.md).

## Is the ad blocker enabled by default?

Yes. Ad/tracker blocking is governed by a Shields content setting, and the
default is BLOCK:

- `GetAdControlType()`
  (`components/brave_shields/core/browser/brave_shields_utils.cc`) returns
  `ControlType::BLOCK` unless the `BRAVE_ADS` content setting is explicitly set
  to `ALLOW`. Out of the box, ads/trackers are blocked with no user action.
- The core `AdBlockService` is constructed with two engines (a "default" engine
  and an "additional"/aggressive engine), both always live
  (`components/brave_shields/content/browser/ad_block_service.cc`).

## Does Brave ship with default filter lists?

There is a built-in, always-enabled list identified by
`kDefaultAdblockFiltersListUuid = "default"`
(`components/brave_shields/core/common/brave_shield_constants.h`). Two
supporting components are **always registered** regardless of settings:

- **Brave Ad Block Resources Library** — component id
  `mfddibmblmbccpadfndgakiopmmhebop` (scriptlets / redirect resources).
- **Brave Ad Block List Catalog** — component id
  `gkboaolpopklhgplhaaiboijnklogmbc` (the manifest of all available lists).

> [!IMPORTANT]
>
> The actual filter **rules are not baked into the binary**. They arrive as
> Component Updater components. The engine is populated from downloaded
> component data. An optional on-disk DAT cache (`kAdblockDATCache`, currently
> `FEATURE_DISABLED_BY_DEFAULT`) can load a cached serialized engine at startup
> for immediate protection before the network fetch lands (see
> `AdBlockService::OnReadCachedDATFiles`).

### The filter list catalog

The list of available filter lists is **not** checked into `brave-core`. It is
delivered at runtime by the List Catalog component
(`gkboaolpopklhgplhaaiboijnklogmbc`), sourced from
[`brave/adblock-resources`](https://github.com/brave/adblock-resources)
(`filter_lists/list_catalog.json`). The catalog therefore changes independently
of `brave-core` releases; the specifics below are a snapshot of `master`.

### Lists that are `default_enabled` in the catalog

As of this writing the catalog has 62 entries, of which 6 carry
`default_enabled: true`:

| Title                         | UUID                                   | Hidden | Notes                                             |
| ----------------------------- | -------------------------------------- | ------ | ------------------------------------------------- |
| Brave Default Adblock Filters | `default`                              | yes    | Core always-on list (`kDefaultAdblockFiltersListUuid`) |
| Brave Default Privacy Filters | `4D715457-307C-4383-8873-73A2FD263F71` | yes    | Anti-tracking                                     |
| Brave iOS-Specific Filters    | `9F38E77A-64AA-4C5F-AF37-727CAE1266FF` | yes    | `platforms: [IOS]` — only active on iOS           |
| Brave First Party Adblock Filters | `E99CBD02-FFD1-4651-9BDD-6A9ED7B87819` | yes | `kFirstPartyAdblockFiltersListUuid`               |
| Cookie notice blocker (EasyList-Cookie) | `AC023D22-AE88-4060-A978-4FEEEC4221693` | no | `kCookieListUuid`                          |
| Mobile app promo blocker      | `2F3DCE16-A19A-493C-A88F-2E110FBD37D6` | no     | `kMobileNotificationsListUuid`                    |

Enablement nuances, from `IsFilterListEnabled()`
(`components/brave_shields/core/browser/ad_block_component_service_manager.cc`):

- The first four are `hidden: true` — they do not appear in the Shields settings
  UI and are effectively force-on. A hidden + `default_enabled` list ignores any
  user preference unless the `kBraveAdblockShowHiddenComponents` dev feature is
  set:

  ```cpp
  if (catalog_entry->default_enabled &&
      (!list_touched || (!show_hidden && catalog_entry->hidden)))
    return true;
  ```

- The last two are user-visible toggles that ship pre-enabled. A user can turn
  them off and that choice sticks (the `!list_touched` gate). They additionally
  have belt-and-suspenders Griffin feature defaults
  (`kBraveAdblockCookieListDefault`, `kBraveAdblockMobileNotificationsListDefault`,
  both `FEATURE_ENABLED_BY_DEFAULT`), so they default on even if the catalog flag
  were dropped.

- The iOS list is gated by `SupportsCurrentPlatform()`, so it only counts on iOS
  despite living in the shared catalog.

### Other lists enabled on top of the catalog defaults

Beyond the `default_enabled` entries, additional lists are auto-enabled through
separate paths:

- **Regional/locale lists** matching the browser locale — auto-enabled exactly
  once, gated by the `kAdBlockCheckedAllDefaultRegions` pref so later user
  choices stick (`StartRegionalServices()`).
- **Embed lists** — Facebook and Twitter embed-blocking default on
  (`kFBEmbedControlType` / `kTwitterEmbedControlType` register `true`); LinkedIn
  embeds default off. See `RegisterPrefsForAdBlockService()`.

Feature-based and catalog defaults only apply when the user has not explicitly
touched that list (`!list_touched`).

## Does it fetch lists, and when?

Yes — via Chromium's Component Updater. Each enabled list is its own updatable
component (`AdBlockComponentFiltersProvider`).

1. **At startup**, `AdBlockService` registers the resource + catalog components
   and starts filter-list components for every enabled list.
2. **After the catalog loads**, `OnFilterListCatalogLoaded()` starts a repeating
   timer that calls `UpdateFilterLists()` every
   `kComponentUpdateCheckIntervalMins` — **default 100 minutes**
   (`components/brave_shields/core/common/features.cc`). It force-updates the
   resource component, the catalog component, and every enabled list component
   via `BraveOnDemandUpdater`.
3. On top of that, Chromium's own Component Updater background cadence (~hours)
   also refreshes these components.

## Key source references

| Concern                        | File                                                                          |
| ------------------------------ | ----------------------------------------------------------------------------- |
| Service lifecycle / engines    | `components/brave_shields/content/browser/ad_block_service.cc`                |
| Enablement logic / update timer | `components/brave_shields/core/browser/ad_block_component_service_manager.cc` |
| Shields ad control default     | `components/brave_shields/core/browser/brave_shields_utils.cc`                |
| UUIDs / component ids          | `components/brave_shields/core/common/brave_shield_constants.h`               |
| Feature defaults               | `components/brave_shields/core/common/features.cc`                            |
| Catalog entry schema           | `components/brave_shields/core/browser/filter_list_catalog_entry.cc`          |
