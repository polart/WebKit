/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

//! This crate provides a cxx-based FFI for the adblock-rust `adblock` crate,
//! exposing engine construction, network-request matching, CSP directives,
//! cosmetic-filter resources, dynamic hide selectors, and (de)serialization to
//! WebKit's C++ NetworkProcess. It is modeled on Brave's brave_shields adblock
//! `rs` crate, minus the Chromium-specific domain-resolver callback (we use
//! adblock-rust's `embedded-domain-resolver` feature instead).
//!
//! Every fallible entry point returns a result struct rather than throwing, and
//! every FFI boundary function catches panics and degrades to a safe default
//! (KTD7: never crash the NetworkProcess because a filter list was bad).

mod convert;
mod engine;
mod filter_set;
mod resource_storage;
mod result;
mod support;

// Bring the opaque types and free functions referenced by the cxx bridge into
// crate-root scope so the generated shims can resolve `super::` paths.
pub use engine::{
    engine_from_filter_set, engine_with_rules, new_engine, read_list_metadata,
    read_list_metadata_bytes, Engine,
};
pub use filter_set::{new_filter_set, FilterSet};
pub use resource_storage::{new_empty_resource_storage, new_resource_storage, ResourceStorage};
pub use result::InternalError;

#[allow(unsafe_op_in_unsafe_fn)]
// `matches`/`get_csp_directives` mirror adblock-rust's request parameters
// one-to-one, which unavoidably exceeds clippy's argument threshold.
#[allow(clippy::too_many_arguments)]
#[cxx::bridge(namespace = "adblock")]
mod ffi {
    extern "Rust" {
        type FilterSet;
        /// Creates an empty filter set to accumulate rules from multiple lists.
        fn new_filter_set() -> Box<FilterSet>;
        /// Parses `rules` (ABP filter-list text) into the set, returning the
        /// list's metadata.
        fn add_filter_list(&mut self, rules: &CxxVector<u8>) -> FilterListMetadataResult;
        /// Same as `add_filter_list`, but tags the list with a permission mask
        /// (used to gate which scriptlets untrusted lists may inject).
        fn add_filter_list_with_permissions(
            &mut self,
            rules: &CxxVector<u8>,
            permission_mask: u8,
        ) -> FilterListMetadataResult;
    }

    extern "Rust" {
        type ResourceStorage;
        /// Builds a resource storage (scriptlet/redirect library) from a JSON
        /// array of resources. Invalid JSON yields an empty storage.
        fn new_resource_storage(resources_json: &CxxString) -> Box<ResourceStorage>;
        /// Builds an empty resource storage.
        fn new_empty_resource_storage() -> Box<ResourceStorage>;
    }

    extern "Rust" {
        type Engine;
        /// Creates a new engine with no rules (pass-through).
        fn new_engine() -> Box<Engine>;
        /// Creates an engine from a single filter list's text.
        fn engine_with_rules(rules: &CxxVector<u8>) -> BoxEngineResult;
        /// Creates an engine from an already-assembled filter set.
        fn engine_from_filter_set(filter_set: Box<FilterSet>) -> BoxEngineResult;
        /// Extracts homepage/title/expiry metadata from a filter list.
        fn read_list_metadata(list: &CxxVector<u8>) -> FilterListMetadata;

        /// Checks whether a request should be blocked.
        fn matches(
            &self,
            url: &CxxString,
            hostname: &CxxString,
            source_hostname: &CxxString,
            request_type: &CxxString,
            third_party_request: bool,
            previously_matched_rule: bool,
            force_check_exceptions: bool,
        ) -> BlockerResult;
        /// Returns additional CSP directives for a document/subdocument
        /// request, or an empty string if none apply.
        fn get_csp_directives(
            &self,
            url: &CxxString,
            hostname: &CxxString,
            source_hostname: &CxxString,
            request_type: &CxxString,
            third_party_request: bool,
        ) -> String;
        /// Serializes the engine to a binary `.dat` blob. A zero-length result
        /// signals a caught panic at the FFI boundary (the underlying
        /// serialization is otherwise infallible).
        fn serialize(&self) -> Vec<u8>;
        /// Loads a binary-serialized engine. Returns false on failure without
        /// panicking (corrupt/garbage input is rejected).
        fn deserialize(&mut self, serialized: &CxxVector<u8>) -> bool;
        /// Loads a resource storage (scriptlet library) into the engine.
        fn use_resource_storage(&mut self, storage: &ResourceStorage);
        /// Returns JSON-serialized cosmetic-filter resources for a URL
        /// (`hide_selectors`, `exceptions`, `injected_script`, `generichide`).
        fn url_cosmetic_resources(&self, url: &CxxString) -> String;
        /// Returns generic hide selectors for the given classes/ids, excluding
        /// any in `exceptions`.
        fn hidden_class_id_selectors(
            &self,
            classes: &CxxVector<CxxString>,
            ids: &CxxVector<CxxString>,
            exceptions: &CxxVector<CxxString>,
        ) -> VecStringResult;
    }

    #[derive(Default)]
    struct BlockerResult {
        matched: bool,
        important: bool,
        has_exception: bool,
        redirect: OptionalString,
        rewritten_url: OptionalString,
    }

    #[derive(Default)]
    struct FilterListMetadata {
        homepage: OptionalString,
        title: OptionalString,
        expires_hours: OptionalU16,
    }

    enum ResultKind {
        Success,
        JsonError,
        Utf8Error,
        AdblockError,
        PanicError,
    }

    // cxx does not support generics, so each fallible call returns a bespoke
    // result struct carrying the value, an outcome kind, and an error message.
    // (cxx auto-converts `Result<T>` into a thrown exception, which the C++
    // callers must not use.)

    struct VecStringResult {
        value: Vec<String>,
        result_kind: ResultKind,
        error_message: String,
    }

    struct BoxEngineResult {
        value: Box<Engine>,
        result_kind: ResultKind,
        error_message: String,
    }

    struct FilterListMetadataResult {
        value: FilterListMetadata,
        result_kind: ResultKind,
        error_message: String,
    }

    // cxx does not yet auto-convert `Option<T>`, so options are carried as a
    // has-value flag plus a value.
    #[derive(Default)]
    struct OptionalString {
        has_value: bool,
        value: String,
    }

    #[derive(Default)]
    struct OptionalU16 {
        has_value: bool,
        value: u16,
    }
}
