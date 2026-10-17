// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0

//! Prints uBlock Origin's redirect resources as a JSON array of adblock-rust
//! `Resource`s, for Tools/Scripts/update-adblock-resources.
//!
//! This is the half of Brave's `generateResources()` (brave-core-crx-packager)
//! that goes through adblock-rust's `resource-assembler`: it reads the index in
//! uBO's `src/js/redirect-resources.js` and base64-encodes each matching file
//! from `src/web_accessible_resources/`. Running it as an example of this crate
//! reuses the engine version WebKit links, so the output always matches what
//! the engine can load.
//!
//! Usage: cargo run --example assemble_web_accessible_resources -- <uBlock checkout>

use adblock::resources::resource_assembler::assemble_web_accessible_resources;
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let Some(checkout) = std::env::args_os().nth(1).map(PathBuf::from) else {
        eprintln!("usage: assemble_web_accessible_resources <uBlock checkout>");
        return ExitCode::FAILURE;
    };

    let resources_dir = checkout.join("src").join("web_accessible_resources");
    let index_path = checkout
        .join("src")
        .join("js")
        .join("redirect-resources.js");
    for path in [&resources_dir, &index_path] {
        if !path.exists() {
            eprintln!("missing {}", path.display());
            return ExitCode::FAILURE;
        }
    }

    let resources = assemble_web_accessible_resources(&resources_dir, &index_path);
    match serde_json::to_string(&resources) {
        Ok(json) => {
            println!("{json}");
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("failed to serialize resources: {error}");
            ExitCode::FAILURE
        }
    }
}
