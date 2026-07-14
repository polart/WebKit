/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

//! Build script for the WebKit adblock FFI crate.
//!
//! `cxx_build::bridge` runs the cxx codegen over `src/lib.rs`, compiles the
//! generated C++ shim (plus the cxx runtime) with the `cc` crate, and links the
//! result into `libwebkitadblock.a`. Because this crate is built as a
//! `staticlib`, those C++ objects are bundled into the archive, so the WebKit
//! framework only has to link the `.a` and include the generated header.
//!
//! The generated headers are written under `target/cxxbridge/`; the U2 build
//! script (`Source/WebKit/Scripts/build-adblock-rust.sh`) copies that tree into
//! `BUILT_PRODUCTS_DIR` for the Xcode `HEADER_SEARCH_PATHS`.

fn main() {
    cxx_build::bridge("src/lib.rs").compile("webkitadblock_cxxbridge");
    println!("cargo:rerun-if-changed=src/lib.rs");
}
