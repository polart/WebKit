/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

use std::collections::HashSet;

use adblock::lists::{FilterSet as InnerFilterSet, ParseOptions};
use adblock::request::Request;
use adblock::Engine as InnerEngine;
use cxx::{CxxString, CxxVector};

use crate::ffi::{BlockerResult, BoxEngineResult, FilterListMetadata, VecStringResult};
use crate::filter_set::FilterSet;
use crate::resource_storage::ResourceStorage;
use crate::result::InternalError;
use crate::support::{cxx_str, cxx_str_vec, guard, guard_result};

/// A wrapper around adblock-rust's `Engine`. Not `Send + Sync` under the
/// `single-thread` feature; the C++ side confines it to a dedicated work queue
/// (KTD3).
pub struct Engine {
    engine: InnerEngine,
}

impl Default for Box<Engine> {
    fn default() -> Self {
        Engine::new_boxed()
    }
}

impl Engine {
    fn new_boxed() -> Box<Engine> {
        Box::new(Engine {
            engine: InnerEngine::default(),
        })
    }

    // --- Native (Rust-typed) API, exercised directly by the crate tests. ---

    /// Builds an engine from a single filter list's UTF-8 text.
    pub fn from_rules_bytes(rules: &[u8]) -> Result<Box<Engine>, InternalError> {
        let mut filter_set = InnerFilterSet::new(false);
        filter_set.add_filter_list(std::str::from_utf8(rules)?, ParseOptions::default());
        Ok(Box::new(Engine {
            engine: InnerEngine::from_filter_set(filter_set, true),
        }))
    }

    /// Builds an engine from an already-assembled filter set.
    pub fn from_filter_set(set: FilterSet) -> Box<Engine> {
        Box::new(Engine {
            engine: InnerEngine::from_filter_set(set.into_inner(), true),
        })
    }

    /// Matches a request against the engine's network rules.
    #[allow(clippy::too_many_arguments)]
    pub fn check(
        &self,
        url: &str,
        hostname: &str,
        source_hostname: &str,
        request_type: &str,
        third_party_request: bool,
        previously_matched_rule: bool,
        force_check_exceptions: bool,
    ) -> BlockerResult {
        let request = Request::preparsed(
            url,
            hostname,
            source_hostname,
            request_type,
            third_party_request,
        );
        self.engine
            .check_network_request_subset(&request, previously_matched_rule, force_check_exceptions)
            .into()
    }

    /// Returns any additional CSP directives that apply to this request, or an
    /// empty string if none.
    pub fn csp(
        &self,
        url: &str,
        hostname: &str,
        source_hostname: &str,
        request_type: &str,
        third_party_request: bool,
    ) -> String {
        let request = Request::preparsed(
            url,
            hostname,
            source_hostname,
            request_type,
            third_party_request,
        );
        self.engine.get_csp_directives(&request).unwrap_or_default()
    }

    /// Serializes the engine to a `.dat` blob. Returns an empty vector on
    /// failure (documented as the error signal).
    pub fn serialize_bytes(&self) -> Vec<u8> {
        self.engine.serialize()
    }

    /// Loads a serialized engine. Corrupt/garbage input returns an error rather
    /// than panicking.
    pub fn deserialize_bytes(&mut self, serialized: &[u8]) -> Result<(), InternalError> {
        // `DeserializationError` does not implement `Display`, so format it via
        // `Debug` for the error message.
        self.engine
            .deserialize(serialized)
            .map_err(|e| InternalError::Deserialize(format!("{e:?}")))
    }

    /// Loads a scriptlet/redirect resource library into the engine.
    pub fn use_resources(&mut self, storage: &ResourceStorage) {
        self.engine.use_resource_storage(storage.clone());
    }

    /// Returns the JSON-serialized cosmetic resources for a URL.
    pub fn cosmetic_resources_json(&self, url: &str) -> Result<String, InternalError> {
        let resources = self.engine.url_cosmetic_resources(url);
        Ok(serde_json::to_string(&resources)?)
    }

    /// Returns generic hide selectors for the given classes/ids, excluding any
    /// class/id in `exceptions`.
    pub fn hidden_selectors(
        &self,
        classes: &[String],
        ids: &[String],
        exceptions: &HashSet<String>,
    ) -> Vec<String> {
        self.engine
            .hidden_class_id_selectors(classes, ids, exceptions)
    }

    // --- cxx bridge methods (thin wrappers with panic guards). ---

    #[allow(clippy::too_many_arguments)]
    pub fn matches(
        &self,
        url: &CxxString,
        hostname: &CxxString,
        source_hostname: &CxxString,
        request_type: &CxxString,
        third_party_request: bool,
        previously_matched_rule: bool,
        force_check_exceptions: bool,
    ) -> BlockerResult {
        guard(|| {
            self.check(
                cxx_str(url),
                cxx_str(hostname),
                cxx_str(source_hostname),
                cxx_str(request_type),
                third_party_request,
                previously_matched_rule,
                force_check_exceptions,
            )
        })
    }

    pub fn get_csp_directives(
        &self,
        url: &CxxString,
        hostname: &CxxString,
        source_hostname: &CxxString,
        request_type: &CxxString,
        third_party_request: bool,
    ) -> String {
        guard(|| {
            self.csp(
                cxx_str(url),
                cxx_str(hostname),
                cxx_str(source_hostname),
                cxx_str(request_type),
                third_party_request,
            )
        })
    }

    pub fn serialize(&self) -> Vec<u8> {
        guard(|| self.serialize_bytes())
    }

    pub fn deserialize(&mut self, serialized: &CxxVector<u8>) -> bool {
        guard(|| self.deserialize_bytes(serialized.as_slice()).is_ok())
    }

    pub fn use_resource_storage(&mut self, storage: &ResourceStorage) {
        guard(|| self.use_resources(storage))
    }

    pub fn url_cosmetic_resources(&self, url: &CxxString) -> String {
        guard(|| {
            self.cosmetic_resources_json(cxx_str(url))
                .unwrap_or_default()
        })
    }

    pub fn hidden_class_id_selectors(
        &self,
        classes: &CxxVector<CxxString>,
        ids: &CxxVector<CxxString>,
        exceptions: &CxxVector<CxxString>,
    ) -> VecStringResult {
        guard_result(|| {
            let classes = cxx_str_vec(classes);
            let ids = cxx_str_vec(ids);
            let exceptions: HashSet<String> = cxx_str_vec(exceptions).into_iter().collect();
            Ok(self.hidden_selectors(&classes, &ids, &exceptions))
        })
    }
}

// --- cxx bridge free functions. ---

pub fn new_engine() -> Box<Engine> {
    Engine::new_boxed()
}

pub fn engine_with_rules(rules: &CxxVector<u8>) -> BoxEngineResult {
    guard_result(|| Engine::from_rules_bytes(rules.as_slice()))
}

pub fn engine_from_filter_set(filter_set: Box<FilterSet>) -> BoxEngineResult {
    guard_result(|| Ok(Engine::from_filter_set(*filter_set)))
}

/// Native metadata parse, exercised by the crate tests.
pub fn read_list_metadata_bytes(list: &[u8]) -> FilterListMetadata {
    std::str::from_utf8(list)
        .map(|list| adblock::lists::read_list_metadata(list).into())
        .unwrap_or_default()
}

pub fn read_list_metadata(list: &CxxVector<u8>) -> FilterListMetadata {
    guard(|| read_list_metadata_bytes(list.as_slice()))
}
