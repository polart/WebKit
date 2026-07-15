// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// FFI boundary helpers: safe CxxString/CxxVector decoding. The crate is built
// with panic=abort (see Cargo.toml), so there is no panic guard here — malformed
// UTF-8 is decoded to an empty string (which the engine harmlessly treats as a
// non-match) rather than panicking.

use cxx::{CxxString, CxxVector};

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
