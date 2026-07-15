/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

use std::str::Utf8Error;

use thiserror::Error;

use crate::engine::Engine;
use crate::ffi::*;

#[derive(Debug, Error)]
pub enum InternalError {
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("utf-8 encoding error: {0}")]
    Utf8(#[from] Utf8Error),
    #[error("deserialization error: {0}")]
    Deserialize(String),
}

impl From<&InternalError> for ResultKind {
    fn from(error: &InternalError) -> Self {
        match error {
            InternalError::Json(_) => Self::JsonError,
            InternalError::Utf8(_) => Self::Utf8Error,
            InternalError::Deserialize(_) => Self::AdblockError,
        }
    }
}

/// An intermediate, generic "result" that streamlines conversion of a Rust
/// `Result` into the concrete, non-generic cxx result structs (cxx does not
/// support generics).
///
/// The conversion chain is: `Result<T, InternalError>` -> `PreResult<T>` ->
/// `TResult` (e.g. `VecStringResult`).
struct PreResult<T: Default> {
    value: T,
    result_kind: ResultKind,
    error_message: String,
}

macro_rules! impl_result_from_trait {
    ($result_type:ty, $value_type:ty) => {
        impl From<Result<$value_type, InternalError>> for $result_type {
            fn from(result: Result<$value_type, InternalError>) -> Self {
                let PreResult {
                    value,
                    result_kind,
                    error_message,
                } = PreResult::from(result);
                Self {
                    value,
                    result_kind,
                    error_message,
                }
            }
        }
    };
}

impl<T> From<Result<T, InternalError>> for PreResult<T>
where
    T: Default,
{
    fn from(result: Result<T, InternalError>) -> Self {
        match result {
            Ok(value) => Self {
                value,
                result_kind: ResultKind::Success,
                error_message: String::new(),
            },
            Err(e) => Self {
                value: Default::default(),
                result_kind: (&e).into(),
                error_message: e.to_string(),
            },
        }
    }
}

impl_result_from_trait!(VecStringResult, Vec<String>);
impl_result_from_trait!(BoxEngineResult, Box<Engine>);
impl_result_from_trait!(FilterListMetadataResult, FilterListMetadata);
