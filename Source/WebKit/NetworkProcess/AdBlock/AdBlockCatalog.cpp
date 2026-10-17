// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockCatalog.h.

#include "config.h"
#include "AdBlockCatalog.h"

#if ENABLE(ADBLOCK)

#include "Logging.h"
#include <cmath>
#include <wtf/ASCIICType.h>
#include <wtf/JSONValues.h>

namespace WebKit {

// The platform name this build answers to in a catalog entry's `platforms`
// field. The upstream vocabulary is LINUX/WINDOWS/MAC/ANDROID/IOS.
static ASCIILiteral currentPlatformName()
{
#if PLATFORM(IOS_FAMILY)
    return "IOS"_s;
#elif PLATFORM(MAC)
    return "MAC"_s;
#elif OS(WINDOWS)
    return "WINDOWS"_s;
#else
    return "LINUX"_s;
#endif
}

// adblock-rust parses every list as ABP/uBO syntax (FilterSet::add_filter_list
// hardcodes FilterFormat::Standard). A "Hosts"-format source fed through that
// path would not parse to the rules it describes, so drop it rather than
// silently compile something else. Every source in the catalog is Standard as
// of this writing; this guards against an upstream addition.
static constexpr auto supportedSourceFormat = "Standard"_s;

bool AdBlockCatalogEntry::supportsCurrentPlatform() const
{
    if (platforms.isEmpty())
        return true;
    return platforms.contains(currentPlatformName());
}

String adBlockLanguageCodeFromLocale(const String& locale)
{
    auto separator = locale.find([](char16_t character) {
        return character == '-' || character == '_';
    });
    auto language = separator == notFound ? locale : locale.left(separator);
    return language.convertToASCIILowercase();
}

bool AdBlockCatalogEntry::matchesLocale(const String& locale) const
{
    auto language = adBlockLanguageCodeFromLocale(locale);
    if (language.isEmpty())
        return false;
    for (auto& candidate : languages) {
        if (equalIgnoringASCIICase(candidate, language))
            return true;
    }
    return false;
}

static Vector<String> parseStringArray(const JSON::Object& object, ASCIILiteral name)
{
    Vector<String> result;
    RefPtr array = object.getArray(name);
    if (!array)
        return result;
    result.reserveCapacity(array->length());
    for (auto& value : *array) {
        auto string = value->asString();
        if (!string.isEmpty())
            result.append(WTF::move(string));
    }
    return result;
}

// Fills `entry.sources` and `entry.supportURL` from the entry's `sources`
// array. Returns false when no usable source survived, which drops the entry.
static bool parseSources(const JSON::Object& object, AdBlockCatalogEntry& entry)
{
    RefPtr sources = object.getArray("sources"_s);
    if (!sources)
        return false;

    entry.sources.reserveCapacity(sources->length());
    for (auto& value : *sources) {
        RefPtr source = value->asObject();
        if (!source)
            continue;

        auto format = source->getString("format"_s);
        // An absent format defaults to Standard upstream.
        if (!format.isEmpty() && format != supportedSourceFormat) {
            RELEASE_LOG(AdBlock, "AdBlockCatalog: skipping source in \"%{public}s\" with unsupported format", entry.title.utf8().data());
            continue;
        }

        URL url { source->getString("url"_s) };
        if (!url.isValid())
            continue;
        entry.sources.append(WTF::move(url));

        if (entry.supportURL.isEmpty())
            entry.supportURL = source->getString("support_url"_s);
    }

    return !entry.sources.isEmpty();
}

// A catalog list's text is stored at a path derived from its uuid, so a uuid
// from a tampered catalog could otherwise escape the lists/ directory. Upstream
// uuids are `uuidgen` output (plus the literal "default"); accept only that
// shape and drop anything else before it can reach the filesystem.
static bool isSafeCatalogUUID(const String& uuid)
{
    if (uuid.isEmpty() || uuid.length() > 64)
        return false;
    for (unsigned index = 0; index < uuid.length(); ++index) {
        auto character = uuid[index];
        if (!isASCIIAlphanumeric(character) && character != '-' && character != '_')
            return false;
    }
    return true;
}

// A permission mask wider than a byte, or negative, is a catalog authoring
// error. Clamp to the most-restrictive value rather than truncating into some
// other list's trust domain.
static uint8_t parsePermissionMask(const JSON::Object& object)
{
    auto value = object.getDouble("permission_mask"_s);
    if (!value)
        return 0;
    if (*value < 0 || *value > 255 || *value != std::trunc(*value)) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockCatalog: out-of-range permission_mask; treating the list as untrusted");
        return 0;
    }
    return static_cast<uint8_t>(*value);
}

Vector<AdBlockCatalogEntry> parseAdBlockCatalog(const String& json)
{
    Vector<AdBlockCatalogEntry> catalog;
    if (json.isEmpty())
        return catalog;

    RefPtr value = JSON::Value::parseJSON(json);
    RefPtr array = value ? value->asArray() : nullptr;
    if (!array) {
        RELEASE_LOG_ERROR(AdBlock, "AdBlockCatalog: catalog is not a JSON array; offering no lists");
        return catalog;
    }

    catalog.reserveCapacity(array->length());
    for (auto& element : *array) {
        RefPtr object = element->asObject();
        if (!object)
            continue;

        AdBlockCatalogEntry entry;
        entry.uuid = object->getString("uuid"_s);
        entry.title = object->getString("title"_s);
        if (entry.title.isEmpty() || !isSafeCatalogUUID(entry.uuid)) {
            RELEASE_LOG_ERROR(AdBlock, "AdBlockCatalog: dropping an entry with a missing title or unusable uuid");
            continue;
        }

        entry.description = object->getString("desc"_s);
        entry.languages = parseStringArray(*object, "langs"_s);
        entry.platforms = parseStringArray(*object, "platforms"_s);
        entry.hidden = object->getBoolean("hidden"_s).value_or(false);
        entry.defaultEnabled = object->getBoolean("default_enabled"_s).value_or(false);
        entry.firstPartyProtections = object->getBoolean("first_party_protections"_s).value_or(false);
        entry.permissionMask = parsePermissionMask(*object);

        if (!parseSources(*object, entry))
            continue;

        catalog.append(WTF::move(entry));
    }

    RELEASE_LOG(AdBlock, "AdBlockCatalog: parsed %zu list(s)", catalog.size());
    return catalog;
}

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
