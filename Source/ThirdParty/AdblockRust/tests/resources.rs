// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Checks how the engine consumes a resource library in the format the embedder
// hands to -[_WKAdBlockController setResources:]: every resource loads,
// scriptlets resolve through aliases with their helper dependencies, trusted
// scriptlets honor the list permission mask, and redirect resources populate
// redirect bodies. tests/fixtures/resources.json is a small synthetic library
// shaped like uBlock Origin's (`*.fn` helpers with MIME `fn/javascript`,
// `requiresTrust` scriptlets with permission bit 0).

use webkitadblock::{new_filter_set, Engine, ResourceStorage};

const FIXTURE: &str = include_str!("fixtures/resources.json");

const TRUSTED_LIST_MASK: u8 = 1;

fn engine_with(rules: &str, permission_mask: u8) -> Box<Engine> {
    let mut set = new_filter_set();
    set.add_list(rules.as_bytes(), permission_mask).unwrap();
    let mut engine = Engine::from_filter_set(*set);
    engine.use_resources(&ResourceStorage::from_json(FIXTURE));
    engine
}

fn injected_script(engine: &Engine) -> String {
    let resources: serde_json::Value = serde_json::from_str(
        &engine
            .cosmetic_resources_json("https://example.com/")
            .unwrap(),
    )
    .unwrap();
    resources["injected_script"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

#[test]
fn every_resource_loads() {
    let entries: Vec<serde_json::Value> = serde_json::from_str(FIXTURE).unwrap();
    let storage = ResourceStorage::from_json(FIXTURE);

    // InMemoryResourceStorage skips invalid entries rather than failing, so a
    // bad resource would otherwise vanish silently.
    let missing: Vec<&str> = entries
        .iter()
        .map(|entry| entry["name"].as_str().unwrap())
        .filter(|name| !storage.has_resource(name))
        .collect();
    assert!(
        missing.is_empty(),
        "resources that failed to load: {missing:?}"
    );
}

#[test]
fn scriptlet_alias_resolves_with_dependencies() {
    let script = injected_script(&engine_with("example.com##+js(set, adsEnabled, true)\n", 0));

    assert!(
        script.contains("setConstant("),
        "scriptlet was not injected: {script}"
    );
    // set-constant.js depends on set-constant.fn, which depends on safe-self.fn.
    assert!(
        script.contains("function setConstantFn("),
        "missing dependency: {script}"
    );
    assert!(
        script.contains("function safeSelf("),
        "missing transitive dependency: {script}"
    );
}

#[test]
fn trusted_scriptlet_requires_trusted_list() {
    let rule = "example.com##+js(trusted-set-cookie, consent, accepted)\n";

    let untrusted = injected_script(&engine_with(rule, 0));
    assert!(
        !untrusted.contains("trustedSetCookie("),
        "untrusted list injected a trusted scriptlet"
    );

    let trusted = injected_script(&engine_with(rule, TRUSTED_LIST_MASK));
    assert!(
        trusted.contains("trustedSetCookie("),
        "trusted list could not inject: {trusted}"
    );
}

#[test]
fn helper_functions_are_not_injectable_on_their_own() {
    let script = injected_script(&engine_with("example.com##+js(safe-self.fn)\n", 0));
    assert!(!script.contains("function safeSelf("));
}

#[test]
fn redirect_resources_populate_redirect_body() {
    let engine = engine_with(
        "||ads.example.com/ima3.js$script,redirect=google-ima.js\n||ads.example.com/pixel$image,redirect=1x1.gif\n",
        0,
    );

    for (url, request_type) in [
        ("https://ads.example.com/ima3.js", "script"),
        ("https://ads.example.com/pixel", "image"),
    ] {
        let result = engine.check(
            url,
            "ads.example.com",
            "news.example.com",
            request_type,
            true,
            false,
            false,
        );
        assert!(result.matched, "{url} was not blocked");
        assert!(result.redirect.has_value, "{url} got no redirect body");
    }
}
