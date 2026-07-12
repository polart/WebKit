// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// FFI boundary helpers: safe CxxString/CxxVector decoding and panic guards so
// that a panic anywhere in the adblock engine degrades to a safe default rather
// than unwinding across the C++ boundary (KTD7).

use std::any::Any;
use std::panic::{catch_unwind, AssertUnwindSafe};

use cxx::{CxxString, CxxVector};

use crate::result::InternalError;

/// Decodes a `CxxString` to `&str`, treating invalid UTF-8 as empty (which the
/// engine harmlessly treats as a non-match) rather than panicking.
pub(crate) fn cxx_str(s: &CxxString) -> &str {
    s.to_str().unwrap_or("")
}

/// Decodes a vector of `CxxString`s to owned `String`s, skipping decode errors
/// by substituting empty strings.
pub(crate) fn cxx_str_vec(values: &CxxVector<CxxString>) -> Vec<String> {
    values.iter().map(|s| cxx_str(s).to_owned()).collect()
}

/// Runs `f`, returning `T::default()` if it panics. For infallible FFI returns
/// (`bool`, `String`, `Vec<u8>`, `BlockerResult`, `Box<_>`), the default is the
/// safe pass-through value.
pub(crate) fn guard<T: Default>(f: impl FnOnce() -> T) -> T {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or_default()
}

/// Runs `f`, converting either its `Result` or a caught panic into the concrete
/// cxx result struct `R`.
pub(crate) fn guard_result<T, R>(f: impl FnOnce() -> Result<T, InternalError>) -> R
where
    R: From<Result<T, InternalError>>,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(result) => result.into(),
        Err(payload) => Err(InternalError::Panic(panic_message(payload))).into(),
    }
}

fn panic_message(payload: Box<dyn Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_owned()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "panic in adblock FFI boundary".to_owned()
    }
}
