// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Tests for the adblock FFI crate's native (Rust-typed) API, which the cxx
// bridge methods delegate to. These cover the U1 test scenarios: network
// matching, exceptions, CSP directives, cosmetic resources, dynamic hide
// selectors, serialize/deserialize round-trips (and garbage rejection),
// malformed-line skipping, and resource storage.

use std::collections::HashSet;

use webkitadblock::{
    new_engine, new_filter_set, read_list_metadata_bytes, Engine, ResourceStorage,
};

fn vec_of(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

// Convenience: a script-type, third-party request for `url` from `ads.example`.
fn check_script(engine: &Engine, url: &str, hostname: &str, source_hostname: &str) -> bool {
    engine
        .check(url, hostname, source_hostname, "script", true, false, false)
        .matched
}

#[test]
fn blocks_matching_request_and_passes_non_matching() {
    let engine = Engine::from_rules_bytes(b"||ads.example.com^$script\n").unwrap();

    assert!(check_script(
        &engine,
        "https://ads.example.com/banner.js",
        "ads.example.com",
        "news.example.com"
    ));
    assert!(!check_script(
        &engine,
        "https://cdn.example.com/app.js",
        "cdn.example.com",
        "news.example.com"
    ));
}

#[test]
fn exception_rule_unblocks_request() {
    let engine =
        Engine::from_rules_bytes(b"||ads.example.com^$script\n@@||ads.example.com^$script\n")
            .unwrap();

    let result = engine.check(
        "https://ads.example.com/banner.js",
        "ads.example.com",
        "news.example.com",
        "script",
        true,
        false,
        false,
    );
    assert!(!result.matched);
    assert!(result.has_exception);
}

#[test]
fn csp_directives_returned_for_csp_rule_only() {
    let engine = Engine::from_rules_bytes(b"||example.com^$csp=script-src 'none'\n").unwrap();

    let csp = engine.csp(
        "https://example.com/",
        "example.com",
        "example.com",
        "document",
        false,
    );
    assert!(csp.contains("script-src 'none'"), "unexpected csp: {csp:?}");

    let none = engine.csp(
        "https://other.com/",
        "other.com",
        "other.com",
        "document",
        false,
    );
    assert!(none.is_empty(), "expected empty csp, got: {none:?}");
}

#[test]
fn cosmetic_resources_contain_hide_selector() {
    let engine = Engine::from_rules_bytes(b"example.com##.ad-banner\n").unwrap();

    let json = engine
        .cosmetic_resources_json("https://example.com/")
        .unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
    let hide_selectors = parsed["hide_selectors"].as_array().unwrap();
    assert!(
        hide_selectors.iter().any(|s| s == ".ad-banner"),
        "expected .ad-banner in {hide_selectors:?}"
    );

    // The same selector must not apply on a different domain.
    let other = engine
        .cosmetic_resources_json("https://other.com/")
        .unwrap();
    let other_parsed: serde_json::Value = serde_json::from_str(&other).unwrap();
    assert!(other_parsed["hide_selectors"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn hidden_class_id_selectors_matches_generic_rule_and_respects_exceptions() {
    let engine = Engine::from_rules_bytes(b"##.generic-ad\n").unwrap();

    let matched = engine.hidden_selectors(&vec_of(&["generic-ad"]), &[], &HashSet::new());
    assert!(
        matched.iter().any(|s| s.contains("generic-ad")),
        "expected a selector for generic-ad, got {matched:?}"
    );

    // A class with no generic rule yields nothing.
    let unmatched = engine.hidden_selectors(&vec_of(&["not-an-ad"]), &[], &HashSet::new());
    assert!(
        unmatched.is_empty(),
        "expected no selectors, got {unmatched:?}"
    );

    // An excepted selector (the full `.class` form, as delivered in the
    // cosmetic resources' `exceptions` set) is not returned.
    let exceptions: HashSet<String> = vec_of(&[".generic-ad"]).into_iter().collect();
    let excepted = engine.hidden_selectors(&vec_of(&["generic-ad"]), &[], &exceptions);
    assert!(
        excepted.is_empty(),
        "expected exception to suppress, got {excepted:?}"
    );
}

#[test]
fn serialize_deserialize_round_trip_preserves_matching() {
    let engine = Engine::from_rules_bytes(b"||ads.example.com^$script\n").unwrap();
    let data = engine.serialize_bytes();
    assert!(!data.is_empty());

    let mut restored = new_engine();
    restored.deserialize_bytes(&data).unwrap();
    assert!(check_script(
        &restored,
        "https://ads.example.com/banner.js",
        "ads.example.com",
        "news.example.com"
    ));
}

#[test]
fn deserialize_rejects_garbage_without_panicking() {
    let mut engine = new_engine();
    let err = engine.deserialize_bytes(b"this is not a real .dat file");
    assert!(err.is_err());
}

#[test]
fn malformed_lines_are_skipped_and_valid_rules_still_compile() {
    // A leading garbage/comment line and a stray control character must not
    // prevent the valid rule from compiling.
    let rules = b"[Adblock Plus 2.0]\n! a comment\n\x07 not a rule\n||ads.example.com^$script\n";
    let engine = Engine::from_rules_bytes(rules).unwrap();

    assert!(check_script(
        &engine,
        "https://ads.example.com/banner.js",
        "ads.example.com",
        "news.example.com"
    ));
}

#[test]
fn filter_set_assembly_and_metadata() {
    let mut filter_set = new_filter_set();
    let metadata = filter_set
        .add_list(b"! Title: Test List\n||ads.example.com^$script\n", 0)
        .unwrap();
    assert!(metadata.title.has_value);
    assert_eq!(metadata.title.value, "Test List");

    let engine = Engine::from_filter_set(*filter_set);
    assert!(check_script(
        &engine,
        "https://ads.example.com/banner.js",
        "ads.example.com",
        "news.example.com"
    ));
}

#[test]
fn read_list_metadata_parses_title_and_homepage() {
    let metadata = read_list_metadata_bytes(
        b"! Title: My List\n! Homepage: https://example.org/\n||ads.example.com^\n",
    );
    assert!(metadata.title.has_value);
    assert_eq!(metadata.title.value, "My List");
    assert!(metadata.homepage.has_value);
    assert_eq!(metadata.homepage.value, "https://example.org/");
}

#[test]
fn resource_storage_from_json_and_empty() {
    let json = r#"[{"name":"noop.js","aliases":["noopjs"],"kind":{"mime":"application/javascript"},"content":"KCk9Pnt9"}]"#;
    let storage = ResourceStorage::from_json(json);
    assert!(storage.has_resource("noop.js"));
    assert!(storage.has_resource("noopjs"));

    let empty = ResourceStorage::empty();
    assert!(!empty.has_resource("noop.js"));

    // Loading a resource library into an engine must not panic.
    let mut engine = new_engine();
    engine.use_resources(&storage);
}

#[test]
fn empty_engine_is_pass_through() {
    let engine = new_engine();
    assert!(!check_script(
        &engine,
        "https://ads.example.com/banner.js",
        "ads.example.com",
        "news.example.com"
    ));
}
