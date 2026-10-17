// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// Prints uBlock Origin's scriptlet library as a JSON array of adblock-rust
// resources, for Tools/Scripts/update-adblock-resources.
//
// uBO defines its scriptlets as live functions in an ES module
// (src/js/resources/scriptlets.js), so their source can only be recovered by
// importing the module and calling Function.prototype.toString() on each one.
// That is why this half of the generator is JavaScript. It mirrors the
// `transformedUboBuiltins` step of Brave's generateResources()
// (brave-core-crx-packager/lib/adBlockRustUtils.js), with two refinements the
// pinned engine (adblock 0.12) supports:
//
//   - Helper functions (`*.fn`) get the `fn/javascript` MIME type, so the engine
//     will pull them in as dependencies but never inject or redirect to them
//     on their own.
//   - Scriptlets uBO marks `requiresTrust` get permission bit 0, so only filter
//     lists whose catalog `permission_mask` grants it (Brave's own lists) can
//     use them. A user-added subscription compiles with mask 0 and cannot.
//
// Usage: node update-adblock-resources-scriptlets.mjs <uBlock checkout>

import path from 'node:path';
import { pathToFileURL } from 'node:url';

const TRUSTED_PERMISSION = 1;

const checkout = process.argv[2];
if (!checkout) {
    console.error('usage: update-adblock-resources-scriptlets.mjs <uBlock checkout>');
    process.exit(1);
}

const modulePath = path.resolve(checkout, 'src', 'js', 'resources', 'scriptlets.js');
const { builtinScriptlets } = await import(pathToFileURL(modulePath).href);

if (!Array.isArray(builtinScriptlets) || !builtinScriptlets.length) {
    console.error(`${modulePath} exported no builtinScriptlets`);
    process.exit(1);
}

const resources = builtinScriptlets.map(scriptlet => {
    if (typeof scriptlet.fn !== 'function') {
        console.error(`scriptlet ${scriptlet.name} has no function body`);
        process.exit(1);
    }

    const resource = {
        name: scriptlet.name,
        aliases: scriptlet.aliases ?? [],
        kind: { mime: scriptlet.name.endsWith('.fn') ? 'fn/javascript' : 'application/javascript' },
        content: Buffer.from(scriptlet.fn.toString()).toString('base64'),
    };
    if (scriptlet.dependencies?.length)
        resource.dependencies = scriptlet.dependencies;
    if (scriptlet.requiresTrust)
        resource.permission = TRUSTED_PERMISSION;
    return resource;
});

process.stdout.write(JSON.stringify(resources));
