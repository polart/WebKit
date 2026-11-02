# AdblockRust

A Rust static library (`libwebkitadblock.a`) that exposes Brave's
[adblock-rust](https://github.com/brave/adblock-rust) engine to WebKit's C++
through a [cxx](https://cxx.rs) bridge. WebKit links it when `ENABLE(ADBLOCK)` is
on; `Source/WebKit/Scripts/build-adblock-rust.sh` builds it.

## Origin

The bridge is a modified copy of Brave's `rs` crate from
[brave-core](https://github.com/brave/brave-core), path
`components/brave_shields/core/common/adblock/rs`, as of brave-core commit
`6a0d205d7f29a745c9a51ad1652f054e23e66411` (September 2026).

| File | Origin |
|---|---|
| `src/lib.rs`, `src/engine.rs`, `src/filter_set.rs`, `src/convert.rs`, `src/result.rs`, `src/resource_storage.rs` | Brave, modified. Brave's copyright notice is kept. |
| `src/support.rs`, `build.rs`, `tests/`, `scripts/` | New |

## License

The crate is licensed under the Mozilla Public License 2.0 (see `LICENSE`).
The crates it depends on are under MIT, Apache 2.0, Unicode 3.0, Zlib,
Unlicense or MPL 2.0. Any binary that contains this library must include their
license texts. Generate them with `mise run notices` (writes
`THIRD_PARTY_NOTICES.txt`) or `scripts/generate-notices.py <output path>`.
