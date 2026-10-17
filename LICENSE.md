# Licensing

This repository is a fork of [WebKit](https://webkit.org) with ad blocking and
privacy features added. It has no single license. Each file states its own in its
header, and the parts fall into these groups:

| Part | License | Where |
|---|---|---|
| Most of WebKit (WTF, WebKit, much of WebCore and JavaScriptCore, Apple's tools) | BSD 2-clause | file headers |
| WebCore and JavaScriptCore code derived from KDE's KHTML and KJS | LGPL 2.1 | file headers; `Source/JavaScriptCore/COPYING.LIB` |
| Ad blocking integration, including code ported from Brave | MPL 2.0 | `SPDX-License-Identifier: MPL-2.0` headers, e.g. `Source/WebKit/NetworkProcess/AdBlock/`, `Source/ThirdParty/AdblockRust/` |
| NewBrowser app (`Tools/NewBrowser/`) | BSD 2-clause (from Apple's SwiftBrowser), with MPL 2.0 files added by this fork | file headers |
| Bundled ad blocking resource library (`Tools/NewBrowser/Resources/AdBlock/resources.json`) | GPL 3.0 (uBlock Origin) and MPL 2.0 (Brave) | `Tools/NewBrowser/Resources/AdBlock/THIRD_PARTY_NOTICES.txt` |
| Third-party code under `Source/ThirdParty/` and elsewhere | as stated in each component | that component's own license file |

New code written for this fork is licensed under MPL 2.0 unless its header says
otherwise.

## The NewBrowser app

The NewBrowser app bundles uBlock Origin's scriptlets and redirect resources,
which are GPL 3.0. Every other license above allows combination with GPL 3.0
code: BSD 2-clause is permissive, LGPL 2.1 permits use under the GPL, and the MPL
2.0 files here are not marked "Incompatible With Secondary Licenses". The
NewBrowser app as distributed is therefore offered under the terms of the GPL 3.0
as a whole, while each source file stays available under its own license.

In practice this means:

- Binaries come with the complete corresponding source: this repository at the
  matching commit.
- The app bundle includes `THIRD_PARTY_NOTICES.txt` and `uBlock-LICENSE.txt`
  alongside `resources.json`.
- Anyone redistributing a NewBrowser binary must do the same.

The filter lists the browser downloads at runtime (EasyList, uBlock Origin's
lists, and others from the catalog) are not bundled and carry their own licenses.
