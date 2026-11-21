#!/bin/bash
set -euo pipefail

# Xcode launched from Finder does not inherit shell PATH additions.
export PATH="${HOME}/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
if ! command -v cargo >/dev/null 2>&1; then
    echo "error: Install Rust with rustup and add the iOS targets listed in README.md."
    exit 1
fi

export IPHONEOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET
cargo_dir="${DERIVED_FILE_DIR}/strings-f1-cargo"
archives=()
for architecture in ${ARCHS}; do
    case "${PLATFORM_NAME}:${architecture}" in
        macosx:arm64) target=aarch64-apple-darwin ;;
        macosx:x86_64) target=x86_64-apple-darwin ;;
        iphoneos:arm64) target=aarch64-apple-ios ;;
        iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
        iphonesimulator:x86_64) target=x86_64-apple-ios ;;
        *) echo "error: Unsupported Strings Rust target ${PLATFORM_NAME}:${architecture}"; exit 1 ;;
    esac
    cargo build --offline --locked --release --target "${target}" \
        --target-dir "${cargo_dir}" --manifest-path "${SRCROOT}/NativeEngine/Cargo.toml"
    archives+=("${cargo_dir}/${target}/release/libstrings_native.a")
done

output="${DERIVED_FILE_DIR}/libstrings_native.a"
if [[ "${#archives[@]}" == 1 ]]; then
    cp "${archives[0]}" "${output}"
else
    xcrun lipo -create "${archives[@]}" -output "${output}"
fi
