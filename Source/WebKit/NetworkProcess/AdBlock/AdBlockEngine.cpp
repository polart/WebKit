// Copyright (C) 2026 the WebKit adblock integration authors.
// SPDX-License-Identifier: MPL-2.0
//
// See AdBlockEngine.h. All FFI type usage (rust::Box, adblock:: functions) is
// confined to this translation unit so the header stays FFI-free.

#include "config.h"
#include "AdBlockEngine.h"

#if ENABLE(ADBLOCK)

#include "Logging.h"

// The generated cxx bridge does pointer/size arithmetic in its Slice/Vec helpers
// that -Wunsafe-buffer-usage flags; it is third-party generated code, so silence
// it around the include. This file's own boundary marshaling uses unsafeMakeSpan
// for the pointer/size cases the compiler cannot bound-check.
IGNORE_CLANG_WARNINGS_BEGIN("unsafe-buffer-usage")
#include "webkit-adblock/src/lib.rs.h"
IGNORE_CLANG_WARNINGS_END

#include <wtf/Assertions.h>
#include <wtf/StdLibExtras.h>
#include <wtf/text/CString.h>

namespace WebKit {

// Opaque owner of the rust engine handle, so AdBlockEngine.h need not see the
// generated FFI header.
struct AdBlockEngineHolder {
    explicit AdBlockEngineHolder(rust::Box<adblock::Engine>&& engine)
        : engine(WTF::move(engine)) { }

    rust::Box<adblock::Engine> engine;
};

static std::string ffiString(const String& string)
{
    auto utf8 = string.utf8();
    return std::string(utf8.data(), utf8.length());
}

static std::vector<uint8_t> ffiBytes(std::span<const uint8_t> bytes)
{
    std::vector<uint8_t> result;
    result.reserve(bytes.size());
    for (auto byte : bytes)
        result.push_back(byte);
    return result;
}

static std::vector<std::string> ffiStrings(const Vector<String>& strings)
{
    std::vector<std::string> result;
    result.reserve(strings.size());
    for (auto& string : strings)
        result.push_back(ffiString(string));
    return result;
}

static String stringFromFfi(const rust::String& string)
{
    return String::fromUTF8(unsafeMakeSpan(string.data(), string.size()));
}

static String optionalStringFromFfi(const adblock::OptionalString& optional)
{
    return optional.has_value ? stringFromFfi(optional.value) : String { };
}

Ref<AdBlockEngine> AdBlockEngine::create()
{
    return adoptRef(*new AdBlockEngine(makeUniqueWithoutFastMallocCheck<AdBlockEngineHolder>(adblock::new_engine())));
}

Ref<AdBlockEngine> AdBlockEngine::createFromRules(std::span<const uint8_t> filterListText)
{
    auto result = adblock::engine_with_rules(ffiBytes(filterListText));
    if (result.result_kind != adblock::ResultKind::Success)
        RELEASE_LOG_ERROR(AdBlock, "AdBlockEngine: filter list failed to compile (%s); using an empty engine", std::string(result.error_message).c_str());
    return adoptRef(*new AdBlockEngine(makeUniqueWithoutFastMallocCheck<AdBlockEngineHolder>(WTF::move(result.value))));
}

Ref<AdBlockEngine> AdBlockEngine::createFromLists(const Vector<ListInput>& lists, const String& resourcesJSON)
{
    auto filterSet = adblock::new_filter_set();
    for (auto& list : lists) {
        auto metadata = filterSet->add_filter_list_with_permissions(ffiBytes(list.text.span()), list.permissionMask);
        if (metadata.result_kind != adblock::ResultKind::Success)
            RELEASE_LOG_ERROR(AdBlock, "AdBlockEngine: a filter list failed to parse (%s); skipping it", std::string(metadata.error_message).c_str());
    }

    auto result = adblock::engine_from_filter_set(WTF::move(filterSet));
    if (result.result_kind != adblock::ResultKind::Success)
        RELEASE_LOG_ERROR(AdBlock, "AdBlockEngine: filter set failed to compile (%s); using an empty engine", std::string(result.error_message).c_str());
    auto engine = WTF::move(result.value);

    if (!resourcesJSON.isEmpty()) {
        auto storage = adblock::new_resource_storage(ffiString(resourcesJSON));
        engine->use_resource_storage(*storage);
    }

    return adoptRef(*new AdBlockEngine(makeUniqueWithoutFastMallocCheck<AdBlockEngineHolder>(WTF::move(engine))));
}

auto AdBlockEngine::readListMetadata(std::span<const uint8_t> filterListText) -> ListMetadata
{
    auto metadata = adblock::read_list_metadata(ffiBytes(filterListText));
    return {
        optionalStringFromFfi(metadata.homepage),
        optionalStringFromFfi(metadata.title),
        metadata.expires_hours.has_value ? std::optional<uint16_t> { metadata.expires_hours.value } : std::nullopt,
    };
}

RefPtr<AdBlockEngine> AdBlockEngine::createFromSerializedPayload(std::span<const uint8_t> serialized)
{
    auto engine = adblock::new_engine();
    if (!engine->deserialize(ffiBytes(serialized)))
        return nullptr;
    return adoptRef(*new AdBlockEngine(makeUniqueWithoutFastMallocCheck<AdBlockEngineHolder>(WTF::move(engine))));
}

AdBlockEngine::AdBlockEngine(std::unique_ptr<AdBlockEngineHolder>&& holder)
    : m_holder(WTF::move(holder))
{
}

AdBlockEngine::~AdBlockEngine() = default;

auto AdBlockEngine::checkRequest(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty) const -> CheckResult
{
    auto result = m_holder->engine->matches(ffiString(url), ffiString(hostname), ffiString(sourceHostname), ffiString(requestType), isThirdParty, false, false);
    return {
        result.matched,
        result.important,
        result.has_exception,
        optionalStringFromFfi(result.redirect),
    };
}

String AdBlockEngine::cspDirectives(const String& url, const String& hostname, const String& sourceHostname, const String& requestType, bool isThirdParty) const
{
    return stringFromFfi(m_holder->engine->get_csp_directives(ffiString(url), ffiString(hostname), ffiString(sourceHostname), ffiString(requestType), isThirdParty));
}

String AdBlockEngine::cosmeticResourcesJSON(const String& url) const
{
    return stringFromFfi(m_holder->engine->url_cosmetic_resources(ffiString(url)));
}

Vector<String> AdBlockEngine::hiddenClassIdSelectors(const Vector<String>& classes, const Vector<String>& ids, const Vector<String>& exceptions) const
{
    auto result = m_holder->engine->hidden_class_id_selectors(ffiStrings(classes), ffiStrings(ids), ffiStrings(exceptions));
    Vector<String> selectors;
    selectors.reserveInitialCapacity(result.value.size());
    for (auto& selector : result.value)
        selectors.append(stringFromFfi(selector));
    return selectors;
}

Vector<uint8_t> AdBlockEngine::serialize() const
{
    auto serialized = m_holder->engine->serialize();
    Vector<uint8_t> result;
    result.append(unsafeMakeSpan(serialized.data(), serialized.size()));
    return result;
}

} // namespace WebKit

#endif // ENABLE(ADBLOCK)
