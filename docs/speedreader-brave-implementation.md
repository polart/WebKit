# Speedreader (Reader Mode) in brave-core

Created: 2026-07-19

Reference notes on how Brave implements reader mode ("Speedreader") in
brave-core, for use when designing an equivalent in WebKit. Speedreader's
defining trait: it distills the **raw HTML in the network path, before render**,
using a Rust engine — unlike Chromium's DOM-distiller, which runs JS in the page
after render.

Everything lives under `../brave-core/components/speedreader/` (platform-agnostic
core) and `../brave-core/browser/**/speedreader/` (desktop wiring/UI), gated by
the `ENABLE_SPEEDREADER` buildflag. There is a separate iOS implementation under
`../brave-core/ios/` that is out of scope here.

Brave sources referenced (read-only sibling repo):

- `../brave-core/components/speedreader/rust/lib/src/` — the Rust distillation
  engine (`speedreader_readability.rs`, `readability/src/{statistics,extractor,scorer,dom,nlp}.rs`)
- `../brave-core/components/speedreader/rust/ffi/speedreader.{h,cc}` — C++↔Rust FFI
- `../brave-core/components/speedreader/speedreader_{rewriter_service,service,util,body_distiller,distilled_page_producer}.cc`
- `../brave-core/components/speedreader/common/url_readable_hints.cc` — URL pre-filter
- `../brave-core/browser/brave_content_browser_client.cc` — throttle wiring
- `../brave-core/browser/ui/speedreader/speedreader_tab_helper.cc` — orchestration/state machine

---

## 1. Architecture overview

```
Navigation → body_sniffer::BodySnifferThrottle (main frame only)
  ├─ URL regex hint (url_readable_hints) + site setting (SpeedreaderService)
  ├─ SpeedreaderBodyDistiller.Transform()               [body handler]
  │     └─ DistillPage() → Rewriter (FFI) → Rust engine
  │           success: stylesheet(CSP+theme+fonts) + distilled HTML
  │           fail:    original bytes (pass-through)
  └─ SpeedreaderDistilledPageProducer                   [body producer, manual path]
Renderer renders the clean doc; SpeedreaderJSHandler (isolated world)
  ↔ mojom::SpeedreaderHost (browser) for "show original", TTS, etc.
SpeedreaderTabHelper drives the distill-state machine + icon/bubble/toolbar UI.
```

### Layers

- **Rust engine** (`rust/lib`): the actual "make a page readable" logic. Parses
  HTML with html5ever into a kuchikiki DOM, scores it, and emits a clean,
  self-contained article document. Uses `lol_html`'s `OutputSink` for streaming
  output. Fork of the `readability` crate, itself derived from Mozilla's
  Readability.js / arc90.
- **FFI** (`rust/ffi`): `cbindgen`-generated header plus hand-written
  `speedreader.h/.cc` wrapping it in two C++ classes:
  - `SpeedReader` — factory, `MakeRewriter(url)`.
  - `Rewriter` — per-page object: `SetTheme/SetFontFamily/SetFontSize/SetColumnWidth/SetMinOutLength/SetDebugView`,
    then `Write(chunk)` → `End()` → `GetOutput()`.
- **Component services**:
  - `SpeedreaderRewriterService` — browser-process global; owns the single
    `SpeedReader` and the CSP-wrapped stylesheet; `MakeRewriter()` builds a
    configured `Rewriter`. The stylesheet (`WrapStylesheetWithCSP`) injects a
    strict CSP (`script-src 'none'`, no external fonts) plus the Brave theme CSS
    and bundled a11y fonts (Atkinson Hyperlegible, OpenDyslexic) as
    integrity-hashed `<script type="brave-style-data">` blobs. A `--speedreader-stylesheet`
    switch hot-reloads a local stylesheet via `FilePathWatcher`.
  - `SpeedreaderService` — per-profile `KeyedService`; user settings via prefs +
    `HostContentSettingsMap`: global "enable on all readable sites" toggle,
    per-site enable/disable, appearance/TTS settings. The policy layer.
- **URL classifier** (`common/url_readable_hints.cc`): `IsURLLooksReadable()`
  is a cheap RE2 pre-filter — paths like `/blog/`, `/news/`, `/article/`,
  `/YYYY/MM/`, or a `blog.` subdomain — gating whether distillation is attempted.
- **Network wiring** (`brave_content_browser_client.cc`,
  `CreateURLLoaderThrottles`): for each main-frame navigation, creates a
  `BodySnifferThrottle` and, if a `SpeedreaderTabHelper` exists, attaches a
  `SpeedreaderBodyDistiller` (handler) and `SpeedreaderDistilledPageProducer`
  (producer).
- **Orchestration** (`SpeedreaderTabHelper`): a `WebContentsObserver` that drives
  UI and holds the distill-state machine (see §4).
- **Renderer** (`renderer/`): `SpeedreaderRenderFrameObserver` installs
  `SpeedreaderJSHandler` into an **isolated world** on the main frame — the JS
  bridge for the distilled page talking back over the `mojom::SpeedreaderHost`
  Mojo interface.
- **UI**: location-bar icon + bubbles (`browser/ui/views/speedreader/`), and a
  React/TS WebUI toolbar panel (`components/speedreader/resources/panel/` over
  `speedreader_toolbar.mojom`). TTS in `tts_player.cc`.

### Two entry paths

- **Automatic**: site enabled + URL looks readable → the throttle distills inline
  as the page loads (`Distilling::Reason::kAutomatic`).
- **Manual** (`ProcessIconClick` → `OnGetDocumentSource`): pulls the current
  document's HTML from the renderer, stashes it in `single_show_content_`, and
  reloads — the `DistilledPageProducer` feeds that captured HTML back through
  distillation (`Reason::kManual`).

### C++-side distillation entry (`speedreader_util.cc`, `DistillPage`)

Runs the rewrite on a `USER_BLOCKING` thread-pool task: `Write()` → `End()` →
`GetOutput()`, timed with the `Brave.Speedreader.Distill` UMA. Output shorter
than **1024 bytes** is treated as failure → falls back to the original page.

---

## 2. Two independent scoring systems

This is the most important thing to internalize; the two are frequently
conflated:

1. **`moz_score`** (`readability/src/statistics.rs`) — a cheap, whole-document
   *readability gate*: "Is this page an article at all?" Runs on every candidate
   page; if too low, distillation is abandoned and the original is served.
2. **`content_score`** (`readability/src/scorer.rs`) — a per-element
   *candidate-selection* score, used only *after* the gate passes, to find which
   DOM subtree is the actual article body.

Both descend from Readability.js/arc90 but are computed differently and answer
different questions. Flow: `write()` (parse chunks) → `end()` (gate via
`moz_score`) → `extract_dom()` (the `content_score` pipeline).

---

## 3. Phase 1 — the readability gate (`statistics.rs`)

Called from `SpeedReaderReadability::end()`. After html5ever finishes the DOM,
`collect_statistics()` runs; the page is rejected unless **`moz_score > 20.0`**.

`collect_scores()` does one recursive walk of `<body>`, scoring only `<p>` and
`<pre>` nodes (plus a special case: a `<div>` containing `text<br>` is scored,
mimicking arc90's br→p conversion). For each, it computes a saturated text length
(`text_len_saturated`, capped at 1000 chars, whitespace-collapsed) and
accumulates three parallel metrics:

```rust
// paragraph_len_threshold = 140 chars (~2 English sentences)
if len >= threshold {
    moz_score += sqrt(len - threshold);   // the actual gate metric
}
moz_score_all_sqrt   += sqrt(len);        // no threshold subtraction
moz_score_all_linear += len;              // raw sum
```

Key design points:

- **`sqrt` + 140-char threshold = anti-spam.** `sqrt` gives diminishing returns
  so one giant paragraph can't dominate; subtracting 140 first means short
  "paragraphs" (nav, captions, teasers) contribute ~nothing. Real articles have
  several 140+ char paragraphs.
- **Everything saturates at "6 good paragraphs":** `MOZ_SCORE_SATURATION = 6 *
  sqrt(1000-140) ≈ 176`. Once all three metrics saturate, `fully_saturated()`
  returns true and recursion **early-exits** — a latency optimization since this
  runs on *every* HTML navigation.
- **Aggressive pruning**: stops descending at `<li>`; at invisibly-styled nodes
  (`is_visible()` — a hand-rolled zero-alloc inline-CSS parser for
  `display:none`/`visibility:hidden`/`opacity:0`); and skips nodes whose
  `id`/`class` match `UNLIKELY_CANDIDATES` unless they also match `LIKELY_CANDIDATES`.
- `moz_score_all_sqrt`, `moz_score_all_linear`, and `is_open_graph_article`
  (checks `<meta property="og:type" content="article">`) are collected as
  features but **not consulted by the gate** — reserved for a future
  ML/classifier.

Note: `speedreader_readability.rs` defines `const MOZ_SCORE_THRESHOLD = 30.0` but
the gate hardcodes `> 20.0`; the named constant is **dead code**.

---

## 4. Phase 2 — extraction (`extractor.rs` → `scorer.rs`)

`extract_dom()` orchestrates. Pipeline in order:

1. **Metadata** (`extract_metadata`). Precedence **JSON-LD > `<meta>` > `<title>`**.
   Validates JSON-LD `@context` against a `schema.org` regex and `@type` against
   a 19-entry allowlist (`NewsArticle`, `BlogPosting`, `TechArticle`, …).
   `try_parse_author` recursively unwraps authors shipped as *stringified JSON
   inside a JSON field* (Buzzfeed). `clean_title()` strips site-name boilerplate
   around separators (`|`, `»`, ` - `, `:`) with guards (cross-checks `<h1>`/`<h2>`)
   so legit colon-titles aren't mangled.

2. **`preprocess()`** — recursive cleanup *before* scoring:
   - Marks `script/style/link/nav/meta/noscript/title` for removal.
   - Unwraps `<noscript><img></noscript>` → bare `<img>` (Medium/BBC lazy-load),
     deleting duplicate sibling images.
   - Collapses `<br><br>` chains → `<p>`; converts phrasing-only `<div>` → `<p>`.
     (The scorer keys heavily off `<p>`.)
   - Deletes single-`<p>`-wrapping outer divs (mobile.slate.com case).

3. **`replace_tags()`** — `<font>` → `<span>` (phrasing) or `<div>` (block).

4. **Candidate scoring** (`find_candidates`) — the content-score model. A node
   `is_candidate` if it has ≥25 chars text and is `p/div/article/center/section`
   (with block-child constraints). Each candidate gets:
   - `init_content_score` by tag: `<article>` +10, `<div>/<section>` +5,
     headings/`<th>` −5, lists/`<li>/<form>` −3.
   - `get_class_weight`: +25 if `id`/`class` matches `POSITIVE`
     (article|body|content|post|story…), −25 if `NEGATIVE` (sidebar|comment|
     footer|share|ad…).
   - `calc_content_score`: +1 base, +≤3 for punctuation matches (prose signal),
     +≤3 for `floor(chars/100)`.

   Then score **propagates up ancestors with distance decay**:
   ```
   parent:      += score
   grandparent: += score / 2
   level N up:  += score / (level * DECAY_FACTOR)   // DECAY_FACTOR = 3
   ```
   So the tightest container around the content scores highest, not `<body>`.

5. **`get_top_candidate()`**:
   - Final score ×= `(1 - link_density)` — link-heavy blocks (nav, "related")
     penalized. `link_density` = link text len / total text len.
   - Keeps top 5 (`NUM_TOP_CANDIDATES`, matching Mozilla).
   - **Graceful degradation**: if best score < `CANDIDATE_SCORE_THRESHOLD = 5.0`
     (or nothing found), re-runs the whole pass with `strip_unlikely_tags = false`
     (the first pass may have over-pruned `UNLIKELY`-classed nodes). Final
     fallback: use `<body>`.

6. **`search_alternative_candidates()`** — if ≥3 of the top-5 score within 75% of
   the winner, walk up to a **common ancestor** containing them and promote it
   (handles articles split across sibling containers).

7. **`append_related_siblings()`** — pull in siblings scoring above
   `max(0.2*top_score, 10)`, sharing the top candidate's `class`, or dense
   low-link `<p>` nodes (recovers trailing paragraphs, images, captions).

8. **`clean()`** — recursive final scrub of the chosen subtree:
   - Hard-deletes `script/style/iframe/object/header/footer/embed/input/select/
     button/svg/aside/…`.
   - Deletes headings ≥75% token-similar to the title (dedupe); rewrites stray
     `<h1>` → `<h2>`.
   - **Lazy-image recovery** (`img_loaded_mask` + `try_lazy_img`): keeps `<img>`
     only with a real `src`/`srcset`; else promotes `data-srcset`/`*-srcset`
     (validated against srcset grammar). Un-resolvable images dropped.
   - `is_useless()` drops `div/table/ul/form` when: `weight+score < 0`; too many
     `<input>` vs paragraphs; list-dominated (>90% list text) with too many
     `<li>`; **link density too high** (>0.5 if positive-weighted, else >0.2);
     tiny text with wrong image count; high `<svg>`/`<embed>` density with little
     text.
   - Strips `PRESENTATIONAL_ATTRIBUTES` (`class/style/align/bgcolor/…`) from
     survivors so nothing fights the stylesheet.
   - **`debug_view`** (feature param `kSpeedreaderDebugView`): instead of
     deleting, wraps removed nodes in `<details>` tagged with the source
     `line!()` as the deletion reason.

9. **`post_process()`** — builds reader chrome: metadata `<div>` with `<h1>`
   title, first-sentence-truncated description (`nlp::first_sentence_boundary`),
   `By {author}`, and two placeholder divs with **hardcoded UUID ids**
   (`READ_TIME_DIV_ID`, `SHOW_ORIGINAL_DIV_ID`). Those UUIDs are the Rust↔JS/CSS
   contract — injected JS (`speedreader-desktop.js`, isolated-world
   `SpeedreaderJSHandler`) finds them to fill read-time and wire "show original".
   Content wrapped under `id="article"` (the styling hook).

10. **Final assembly**: fresh `<html><head><body>`. `<head>` gets only the title
    and preserved `charset`/CSP `<meta>` nodes (charset preserved deliberately —
    default encoding isn't utf-8). `<html>` gets
    `data-theme`/`data-font-family`/`data-font-size`/`data-column-width` — user
    appearance settings threaded from `SpeedreaderService` through the FFI
    setters; the CSS selects on these data-attributes. Enforces `min_out_length`
    (`text_len(top_candidate) < min` → error), the Rust-side counterpart to the
    C++ 1024-byte check.

---

## 5. Notable design themes (for a WebKit port)

- **Pre-render distillation on raw bytes** — fast, and page JS never runs on the
  article. The WebKit equivalent would hook the network/response path, not a
  post-render DOM pass.
- **Cheap gate → expensive extraction** — the saturating `moz_score` gate keeps
  the common (non-article) case cheap on the hot path; only pages that pass do
  the full candidate walk.
- **Locked-down output** — strict CSP, all styling self-contained, bundled fonts
  inlined as integrity-hashed blobs.
- **Memory-safe Rust behind a thin FFI** — the heuristic-heavy logic is isolated
  in Rust; C++ only orchestrates `Write/End/GetOutput`.
- **Defensive, real-site-driven heuristics** — Buzzfeed nested-JSON authors,
  Medium/BBC noscript images, Kotaku lazy `data-srcset` and SVG players, Slate
  div-wrapped paragraphs. These are the cases a naive reimplementation will miss;
  the Rust test suites in `readability/src/*.rs` (`#[cfg(test)]` modules) encode
  them and are a good conformance target.
- **Rust↔frontend contract via magic ids** — `id="article"` plus the two UUID
  placeholder divs. Any port must keep the stylesheet/JS and the emitted markup
  agreed on these hooks.
