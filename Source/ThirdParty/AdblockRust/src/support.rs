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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ffi::{ResultKind, VecStringResult};

    // These tests deliberately panic inside the guarded closure; the default
    // panic hook prints "thread panicked ..." to stderr even though the panic
    // is caught and the test passes. That noise is expected, not a failure.

    #[test]
    fn guard_degrades_panic_to_safe_default() {
        // A panic must not unwind across the boundary; the caller gets the
        // pass-through default instead (KTD7). For a block check that is
        // `false` (allow); for a serialize that is an empty blob.
        let blocked: bool = guard(|| panic!("boom"));
        assert!(!blocked, "panic must degrade to the allow (false) default");

        let serialized: Vec<u8> = guard(|| panic!("boom"));
        assert!(serialized.is_empty(), "panic must degrade to an empty blob");
    }

    #[test]
    fn guard_returns_value_when_no_panic() {
        assert!(guard(|| true));
    }

    #[test]
    fn guard_result_reports_panic_as_error_result() {
        let result: VecStringResult =
            guard_result(|| -> Result<Vec<String>, InternalError> { panic!("boom in ffi") });
        assert!(matches!(result.result_kind, ResultKind::PanicError));
        assert!(result.value.is_empty());
        assert!(
            result.error_message.contains("boom in ffi"),
            "panic message should be surfaced, got: {:?}",
            result.error_message
        );
    }

    #[test]
    fn guard_result_passes_through_success() {
        let result: VecStringResult = guard_result(|| Ok(vec!["a".to_owned(), "b".to_owned()]));
        assert!(matches!(result.result_kind, ResultKind::Success));
        assert_eq!(result.value, vec!["a".to_owned(), "b".to_owned()]);
        assert!(result.error_message.is_empty());
    }
}
