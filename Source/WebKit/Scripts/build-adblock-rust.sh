#!/bin/sh
#
# Copyright (C) 2026 Apple Inc. All rights reserved.
#
# Builds the adblock FFI crate (Source/ThirdParty/AdblockRust) into
# libwebkitadblock.a and copies it, plus the cxx-generated C++ headers, into
# BUILT_PRODUCTS_DIR so the WebKit framework can link and #include them
# (ENABLE(ADBLOCK), U2). The crate emits a self-contained static library: the
# cxx C++ shim and runtime are compiled into the archive by cxx-build, so Xcode
# only has to link the .a and add the header search path (see
# Configurations/BaseTarget.xcconfig).
#
# Gated on the ENABLE_ADBLOCK build setting: when it is not exactly "1" (e.g. an
# `ENABLE_ADBLOCK=0` build) this script is a no-op and invokes no toolchain,
# which keeps the fork's flag-off build free of any adblock/cargo dependency
# (R10).

set -e

if [ "${ENABLE_ADBLOCK}" != "1" ]; then
    echo "note: ENABLE_ADBLOCK is not 1 (\"${ENABLE_ADBLOCK}\"); skipping adblock-rust build."
    exit 0
fi

CRATE_DIR="${SRCROOT}/../ThirdParty/AdblockRust"
if [ ! -f "${CRATE_DIR}/Cargo.toml" ]; then
    echo "error: adblock crate not found at ${CRATE_DIR}" 1>&2
    exit 1
fi

# The Rust toolchain is pinned by the crate's mise.toml (mise is not assumed to
# be on the sparse PATH Xcode gives a script phase, so probe common locations).
MISE="$(command -v mise 2>/dev/null || true)"
if [ -z "${MISE}" ]; then
    for candidate in /opt/homebrew/bin/mise /usr/local/bin/mise "${HOME}/.local/bin/mise"; do
        if [ -x "${candidate}" ]; then
            MISE="${candidate}"
            break
        fi
    done
fi
if [ -z "${MISE}" ]; then
    echo "error: mise not found; install it (https://mise.jdx.dev) so the pinned Rust toolchain can build the adblock crate." 1>&2
    exit 1
fi

cd "${CRATE_DIR}"

# Trust the crate config and ensure the pinned toolchain is installed. Both are
# idempotent no-ops once the machine is set up.
"${MISE}" trust --quiet >/dev/null 2>&1 || true
"${MISE}" install >/dev/null

# Map the Xcode configuration to a cargo profile and its target subdirectory.
case "${CONFIGURATION}" in
    Debug)
        CARGO_PROFILE_FLAG=""
        CARGO_PROFILE_DIR="debug"
        ;;
    *)
        CARGO_PROFILE_FLAG="--release"
        CARGO_PROFILE_DIR="release"
        ;;
esac

HOST_TRIPLE="$("${MISE}" exec -- rustc -vV | awk '/^host:/ { print $2 }')"

# Map the requested Xcode arch(s) to Rust target triples. ARCHS may list more
# than one arch for a universal build; fall back to the host arch otherwise.
BUILD_ARCHS="${ARCHS}"
if [ -z "${BUILD_ARCHS}" ] || [ "${BUILD_ARCHS}" = "undefined_arch" ]; then
    BUILD_ARCHS="$(uname -m)"
fi

SLICES=""
HEADER_SRC=""
for arch in ${BUILD_ARCHS}; do
    case "${arch}" in
        arm64|aarch64) triple="aarch64-apple-darwin" ;;
        x86_64) triple="x86_64-apple-darwin" ;;
        *)
            echo "error: unsupported adblock build arch '${arch}'" 1>&2
            exit 1
            ;;
    esac

    # Ensure the target is installed (no-op if already present; tolerated if the
    # toolchain has no rustup and the triple is the host).
    if [ "${triple}" != "${HOST_TRIPLE}" ]; then
        "${MISE}" exec -- rustup target add "${triple}" >/dev/null 2>&1 || true
    fi

    echo "note: building adblock-rust (${CARGO_PROFILE_DIR}) for ${triple}"
    # Build with JSON output so we can read this build's generated-header
    # directory straight from cargo (--json-render-diagnostics still prints
    # human-readable errors to stderr for the Xcode log). This is deterministic:
    # the build-script-executed message reports the exact OUT_DIR for the current
    # build hash on both fresh and incremental builds, so we never have to guess
    # among stale webkit-adblock-<hash> directories.
    BUILD_JSON="$("${MISE}" exec -- cargo build ${CARGO_PROFILE_FLAG} --target "${triple}" --message-format=json-render-diagnostics)"

    OUT_DIR="$(printf '%s\n' "${BUILD_JSON}" \
        | grep '"build-script-executed"' \
        | grep 'webkit-adblock@' \
        | grep -o '"out_dir":"[^"]*"' \
        | head -1 \
        | sed 's/.*"out_dir":"//; s/"$//')"
    if [ -n "${OUT_DIR}" ] && [ -f "${OUT_DIR}/cxxbridge/include/webkit-adblock/src/lib.rs.h" ]; then
        # The generated headers are arch-independent; any built triple's copy works.
        HEADER_SRC="${OUT_DIR}/cxxbridge/include"
    fi

    SLICES="${SLICES} target/${triple}/${CARGO_PROFILE_DIR}/libwebkitadblock.a"
done

# This build phase runs under Xcode's user-script sandbox
# (ENABLE_USER_SCRIPT_SANDBOXING), which only permits writes to the phase's
# declared output files -- see the outputPaths in project.pbxproj. lipo cannot
# write its temporary file into BUILT_PRODUCTS_DIR, so combine the per-arch
# archives inside the crate's target/ directory (writable, where cargo already
# built them) and then copy the finished artifacts onto the exact declared
# output paths.
FAT_LIB="target/libwebkitadblock.a"
lipo -create ${SLICES} -output "${FAT_LIB}"

OUTPUT_LIB="${BUILT_PRODUCTS_DIR}/libwebkitadblock.a"
mkdir -p "${BUILT_PRODUCTS_DIR}"
# This phase runs on every build (cargo owns incrementality), so only refresh the
# output when the content actually changed -- otherwise the copy would bump the
# archive's mtime and relink the whole WebKit framework needlessly each build.
if ! cmp -s "${FAT_LIB}" "${OUTPUT_LIB}"; then
    cp "${FAT_LIB}" "${OUTPUT_LIB}"
fi

# Publish the cxx-generated header from the OUT_DIR cargo reported above. C++
# consumers include "webkit-adblock/src/lib.rs.h" (self-contained -- the cxx
# runtime is inlined, so no separate rust/cxx.h is required); it is the only
# generated header, hence a single declared output rather than a tree copy.
if [ -z "${HEADER_SRC}" ]; then
    echo "error: could not determine the adblock cxx header directory from cargo output." 1>&2
    exit 1
fi
OUTPUT_HEADER="${BUILT_PRODUCTS_DIR}/AdblockRust/webkit-adblock/src/lib.rs.h"
mkdir -p "$(dirname "${OUTPUT_HEADER}")"
# Same mtime guard as the archive above: this phase runs every build, so only
# refresh the header when its content changed -- an unconditional copy would bump
# the header's mtime and force every C++ translation unit that includes it to
# recompile each build once U4+ adds the first consumer.
if ! cmp -s "${HEADER_SRC}/webkit-adblock/src/lib.rs.h" "${OUTPUT_HEADER}"; then
    cp "${HEADER_SRC}/webkit-adblock/src/lib.rs.h" "${OUTPUT_HEADER}"
fi

echo "note: adblock-rust -> ${OUTPUT_LIB} (+ header ${OUTPUT_HEADER})"
