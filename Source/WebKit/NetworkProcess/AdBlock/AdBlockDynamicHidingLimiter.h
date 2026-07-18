// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Per-page rate limiter for the U8 dynamic-hiding IPC (HiddenClassIdSelectors).
// The policy lives in the AdBlock component rather than the core IPC class: the
// owning NetworkConnectionToWebProcess holds one instance and consults it before
// forwarding a query to the shared engine, so the connection file keeps only a
// one-line hook. Keying the budget per page means one page cannot starve dynamic
// hiding for the other pages sharing a web process.
//
// Threading: not thread-safe. It is only ever touched from the main run loop,
// where the HiddenClassIdSelectors handler runs; the shared engine query it gates
// is what hops onto AdBlockManager's WorkQueue, not this bookkeeping.

#pragma once

#if ENABLE(ADBLOCK)

#include "WebPageProxyIdentifier.h"
#include <wtf/HashMap.h>
#include <wtf/MonotonicTime.h>
#include <wtf/Seconds.h>

namespace WebKit {

class AdBlockDynamicHidingLimiter {
public:
    // A single query may carry at most this many exception selectors. The legitimate
    // exception set is a small per-navigation constant (generic `#@#` exceptions for
    // the host), so this ceiling is far above any real page; it exists to reject the
    // one amplification vector the token budget would otherwise miss — a hostile
    // process attaching a huge exceptions vector (which the engine deep-copies and
    // FFI-marshals) to every query while sending a single class token.
    static constexpr unsigned maxExceptionsPerQuery = 8192;

    // Fixed (tumbling) window: the counter resets to zero once the window elapses, so
    // a process straddling a boundary can burst up to ~2x the budget in a sub-window.
    // That ceiling is acceptable here — the budget bounds sustained engine load, not a
    // hard per-interval SLA — and it keeps the limiter branch-cheap on the hot path.
    static constexpr unsigned maxTokensPerWindow = 10000;
    static constexpr Seconds windowDuration = 10_s;

    // Decide whether a dynamic-hiding query from `page` carrying these vector sizes
    // may reach the engine. classes, ids AND exceptions all count against the page's
    // window, so the exceptions vector can no longer bypass the budget. Returns false
    // (the caller replies empty) when a single message exceeds the per-query exception
    // cap, or when the page is over its per-window token budget. `shouldLog` is set
    // true exactly once per window the first time a page trips its budget, so the
    // caller can log without spamming.
    bool allowQuery(WebPageProxyIdentifier page, unsigned classCount, unsigned idCount, unsigned exceptionCount, bool& shouldLog)
    {
        shouldLog = false;

        // Over-cap single message: reject before the engine deep-copies/marshals it,
        // and without disturbing the window counter (so it is not itself a throttle).
        if (exceptionCount > maxExceptionsPerQuery)
            return false;

        auto now = MonotonicTime::now();
        pruneStaleEntries(now);

        auto& budget = m_budgets.ensure(page, [] { return PageBudget { }; }).iterator->value;
        if (now - budget.windowStart > windowDuration) {
            budget.windowStart = now;
            budget.tokensInWindow = 0;
            budget.didLogThisWindow = false;
        }

        budget.tokensInWindow += classCount + idCount + exceptionCount;
        if (budget.tokensInWindow > maxTokensPerWindow) {
            if (!budget.didLogThisWindow) {
                budget.didLogThisWindow = true;
                shouldLog = true;
            }
            return false;
        }
        return true;
    }

private:
    struct PageBudget {
        MonotonicTime windowStart;
        unsigned tokensInWindow { 0 };
        bool didLogThisWindow { false };
    };

    // Drop entries whose window has fully elapsed, so a long-lived web process that
    // cycles through many pages does not accumulate stale per-page budgets. Only runs
    // once the map grows past a small bound, keeping the common path allocation-free.
    void pruneStaleEntries(MonotonicTime now)
    {
        if (m_budgets.size() <= maxTrackedPages)
            return;
        m_budgets.removeIf([&](auto& entry) {
            return now - entry.value.windowStart > windowDuration;
        });
    }

    static constexpr unsigned maxTrackedPages = 128;
    HashMap<WebPageProxyIdentifier, PageBudget> m_budgets;
};

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
