# Licensing

This repository is a fork of [WebKit](https://webkit.org) with ad blocking and
privacy features added. It has no single license. Each file states its own in its
header, and the parts fall into these groups:

| Part | License | Where |
|---|---|---|
| Most of WebKit (WTF, WebKit, much of WebCore and JavaScriptCore, Apple's tools) | BSD 2-clause | file headers |
| WebCore and JavaScriptCore code derived from KDE's KHTML and KJS | LGPL 2.1 | file headers; `Source/JavaScriptCore/COPYING.LIB` |
| Ad blocking integration, including code ported from Brave | MPL 2.0 | `SPDX-License-Identifier: MPL-2.0` headers, e.g. `Source/WebKit/NetworkProcess/AdBlock/`, `Source/ThirdParty/AdblockRust/` |
| Third-party code under `Source/ThirdParty/` and elsewhere | as stated in each component | that component's own license file |

New code written for this fork is licensed under MPL 2.0 unless its header says
otherwise.
