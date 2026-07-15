/* Copyright (c) 2025 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

use std::sync::Arc;

use adblock::resources::{InMemoryResourceStorage, Resource, ResourceImpl, ResourceStorageBackend};
use cxx::CxxString;

use crate::support::cxx_str;

/// A shareable scriptlet/redirect resource library, cloneable by `Arc`.
#[derive(Clone)]
pub struct ResourceStorage {
    shared_storage: Arc<InMemoryResourceStorage>,
}

impl Default for Box<ResourceStorage> {
    fn default() -> Self {
        ResourceStorage::empty_boxed()
    }
}

impl ResourceStorageBackend for ResourceStorage {
    fn get_resource(&self, resource_ident: &str) -> Option<ResourceImpl> {
        self.shared_storage.get_resource(resource_ident)
    }
}

impl ResourceStorage {
    // --- Native API, exercised by the crate tests. ---

    /// Builds storage from a JSON array of resources; invalid JSON yields an
    /// empty storage.
    pub fn from_json(resources_json: &str) -> ResourceStorage {
        let resources = serde_json::from_str::<Vec<Resource>>(resources_json).unwrap_or_default();
        ResourceStorage {
            shared_storage: Arc::new(InMemoryResourceStorage::from_resources(resources)),
        }
    }

    pub fn empty() -> ResourceStorage {
        ResourceStorage {
            shared_storage: Arc::new(InMemoryResourceStorage::from_resources(vec![])),
        }
    }

    fn from_json_boxed(resources_json: &str) -> Box<ResourceStorage> {
        Box::new(Self::from_json(resources_json))
    }

    fn empty_boxed() -> Box<ResourceStorage> {
        Box::new(Self::empty())
    }

    /// Test helper: reports whether a resource is present by name.
    pub fn has_resource(&self, name: &str) -> bool {
        self.get_resource(name).is_some()
    }
}

pub fn new_resource_storage(resources_json: &CxxString) -> Box<ResourceStorage> {
    ResourceStorage::from_json_boxed(cxx_str(resources_json))
}

pub fn new_empty_resource_storage() -> Box<ResourceStorage> {
    ResourceStorage::empty_boxed()
}
