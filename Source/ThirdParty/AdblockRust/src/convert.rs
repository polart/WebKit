/* Copyright (c) 2023 The Brave Authors. All rights reserved.
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this file,
 * You can obtain one at https://mozilla.org/MPL/2.0/. */

use adblock::blocker::BlockerResult as InnerBlockerResult;
use adblock::lists::{ExpiresInterval, FilterListMetadata as InnerFilterListMetadata};

use crate::ffi::{BlockerResult, FilterListMetadata, OptionalString, OptionalU16};

impl From<Option<String>> for OptionalString {
    fn from(value: Option<String>) -> Self {
        match value {
            None => Self {
                has_value: false,
                value: String::new(),
            },
            Some(value) => Self {
                has_value: true,
                value,
            },
        }
    }
}

impl From<Option<u16>> for OptionalU16 {
    fn from(value: Option<u16>) -> Self {
        match value {
            None => Self {
                has_value: false,
                value: 0,
            },
            Some(value) => Self {
                has_value: true,
                value,
            },
        }
    }
}

impl From<InnerBlockerResult> for BlockerResult {
    fn from(result: InnerBlockerResult) -> Self {
        Self {
            matched: result.matched,
            important: result.important,
            has_exception: result.exception.is_some(),
            redirect: result.redirect.into(),
            rewritten_url: result.rewritten_url.into(),
        }
    }
}

impl From<InnerFilterListMetadata> for FilterListMetadata {
    fn from(metadata: InnerFilterListMetadata) -> Self {
        let expires_hours = OptionalU16::from(metadata.expires.map(|interval| match interval {
            ExpiresInterval::Hours(hours) => hours,
            ExpiresInterval::Days(days) => days as u16 * 24,
        }));
        Self {
            homepage: metadata.homepage.into(),
            title: metadata.title.into(),
            expires_hours,
        }
    }
}
