// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockCosmeticResourceParser.h.

#include "config.h"
#include "AdBlockCosmeticResourceParser.h"

#if ENABLE(ADBLOCK)

#include <wtf/JSONValues.h>
#include <wtf/StdLibExtras.h>

namespace WebKit {

namespace AdBlock {

// Appends every non-empty string entry of the named JSON array to out. Absent
// or non-array fields are simply skipped (the engine always emits arrays, but a
// truncated/garbage payload must degrade to "no selectors", never throw).
static void appendStringArray(const JSON::Object& object, ASCIILiteral name, Vector<String>& out)
{
    RefPtr array = object.getArray(name);
    if (!array)
        return;
    out.reserveCapacity(out.size() + array->length());
    for (auto& value : *array) {
        auto string = value->asString();
        if (!string.isEmpty())
            out.append(WTF::move(string));
    }
}

AdBlockCosmeticResources parseCosmeticResources(const String& json)
{
    AdBlockCosmeticResources resources;
    if (json.isEmpty())
        return resources;

    RefPtr value = JSON::Value::parseJSON(json);
    if (!value)
        return resources;
    RefPtr object = value->asObject();
    if (!object)
        return resources;

    appendStringArray(*object, "hide_selectors"_s, resources.hideSelectors);
    appendStringArray(*object, "exceptions"_s, resources.exceptions);
    resources.injectedScript = object->getString("injected_script"_s);
    resources.generichide = object->getBoolean("generichide"_s).value_or(false);

    return resources;
}

} // namespace AdBlock

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
