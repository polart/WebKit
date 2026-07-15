/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

use adblock::{lists::ParseOptions, resources::PermissionMask, FilterSet as InnerFilterSet};
use cxx::CxxVector;

use crate::ffi::{FilterListMetadata, FilterListMetadataResult};
use crate::result::InternalError;

/// Accumulates parsed filters from one or more lists before an engine is built.
pub struct FilterSet(InnerFilterSet);

impl Default for Box<FilterSet> {
    fn default() -> Self {
        FilterSet::new_boxed()
    }
}

impl FilterSet {
    fn new_boxed() -> Box<FilterSet> {
        // `false` == not debug mode; content-blocking conversion is not needed
        // on macOS.
        Box::new(FilterSet(InnerFilterSet::new(false)))
    }

    pub(crate) fn into_inner(self) -> InnerFilterSet {
        self.0
    }

    // --- Native API, exercised by the crate tests. ---

    /// Parses a list's UTF-8 text into the set with an optional permission mask.
    pub fn add_list(
        &mut self,
        rules: &[u8],
        permission_mask: u8,
    ) -> Result<FilterListMetadata, InternalError> {
        Ok(self
            .0
            .add_filter_list(
                std::str::from_utf8(rules)?,
                ParseOptions {
                    permissions: PermissionMask::from_bits(permission_mask),
                    ..Default::default()
                },
            )
            .into())
    }

    // --- cxx bridge methods. ---

    pub fn add_filter_list(&mut self, rules: &CxxVector<u8>) -> FilterListMetadataResult {
        self.add_filter_list_with_permissions(rules, 0)
    }

    pub fn add_filter_list_with_permissions(
        &mut self,
        rules: &CxxVector<u8>,
        permission_mask: u8,
    ) -> FilterListMetadataResult {
        self.add_list(rules.as_slice(), permission_mask).into()
    }
}

pub fn new_filter_set() -> Box<FilterSet> {
    FilterSet::new_boxed()
}
