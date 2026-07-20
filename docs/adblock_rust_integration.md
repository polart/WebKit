# Adblock-Rust Integration

## Architecture Overview

The integration uses **cxx-rs** (the `cxx` crate) for a safe C++/Rust FFI
boundary. The upstream `adblock` crate (v0.12.4) does the heavy lifting
(parsing, matching, serialization), while a thin FFI wrapper crate
(`adblock-cxx`) exposes it to C++ code.

## Key Layers

### 1. Upstream Rust Crate

- **Vendored at**: `third_party/rust/chromium_crates_io/vendor/adblock-v0_12/src/`
- Contains the core engine: filter parsing, request matching, cosmetic
  filtering, regex management, flatbuffer serialization.

### 2. FFI Wrapper Crate (`adblock-cxx`)

- **Location**: `components/brave_shields/core/common/adblock/rs/`
- Defines the `cxx::bridge` in `src/lib.rs` — this is the contract between Rust
  and C++.
- Exposes types to C++: `FilterSet`, `Engine`, `BraveCoreResourceStorage`
- Exposes C++ callbacks to Rust (e.g., `resolve_domain_position()` delegates to
  Chromium's domain registry).
- Key FFI structs:
  `BlockerResult { matched, important, has_exception, redirect, rewritten_url }`

### 3. C++ Wrappers

| Class | File | Role |
|-------|------|------|
| `AdBlockEngine` | `content/browser/ad_block_engine.h/.cc` | Wraps a single Rust `Engine`; does per-request matching |
| `AdBlockEngineWrapper` | `content/browser/ad_block_engine_wrapper.h/.cc` | Combines default + aggressive engines |
| `AdBlockService` | `content/browser/ad_block_service.h/.cc` | Manages lifecycle, filter updates, resource loading |

### 4. Domain Resolver Bridge

- `components/brave_shields/core/common/adblock/resolver/adblock_domain_resolver.cc`
- Maps Rust's domain-extraction callback into Chromium's
  `net::registry_controlled_domains::GetDomainAndRegistry`.

## Runtime Flow

1. **Initialization**: `AdBlockService` creates engines via
   `adblock::new_engine()`.
2. **Filter loading**: Filter lists are parsed into a `FilterSet`, then compiled
   into an `Engine` (or deserialized from a cached binary `.dat` file).
3. **Request matching**: For each network request,
   `engine->matches(url, host, tab_host, resource_type, is_third_party, ...)`
   returns a `BlockerResult`.
4. **Cosmetic filtering**: `engine->url_cosmetic_resources(url)` returns CSS/JS
   injection rules.
5. **CSP directives**: `engine->get_csp_directives(...)` returns
   Content-Security-Policy headers to inject.

## Build Integration

- `BUILD.gn` at `rs/BUILD.gn` declares a `rust_static_library("rust_lib")` with
  `cxx_bindings = ["src/lib.rs"]`.
- The generated C++ header is included as
  `brave/components/brave_shields/core/common/adblock/rs/src/lib.rs.h`.

## Platform Notes

- **Desktop**: Uses `single-thread` feature optimization.
- **iOS**: Uses the `content-blocking` feature to convert rules into WebKit's
  content-blocking JSON format (rule count capped at ~150k).

## Key Files

| Purpose | Path |
|---------|------|
| FFI contract | `components/brave_shields/core/common/adblock/rs/src/lib.rs` |
| C++ engine wrapper | `components/brave_shields/content/browser/ad_block_engine.cc` |
| Service orchestration | `components/brave_shields/content/browser/ad_block_service.cc` |
| Domain resolver | `components/brave_shields/core/common/adblock/resolver/adblock_domain_resolver.cc` |
| Rust crate deps | `components/brave_shields/core/common/adblock/rs/Cargo.toml` |
