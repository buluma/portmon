#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# SwiftPM links Sparkle as a framework but `swift run` does not create the app
# bundle that normally embeds it. Put a development copy beside the executable
# and give that executable a local rpath so dyld can resolve the framework.
BUILD_ARGS=()
PROGRAM_ARGS=()
PASSTHROUGH=false
for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
        PASSTHROUGH=true
    elif $PASSTHROUGH; then
        PROGRAM_ARGS+=("$arg")
    else
        BUILD_ARGS+=("$arg")
    fi
done

swift build "${BUILD_ARGS[@]}"
BUILD_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
if ((${#PROGRAM_ARGS[@]})); then
    EXECUTABLE="$BUILD_DIR/portmon"
else
    EXECUTABLE="$BUILD_DIR/portmon-app"
fi

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/portmon-run.XXXXXX")"
trap 'rm -rf "$RUN_DIR"' EXIT
cp "$EXECUTABLE" "$RUN_DIR/portmon"
if [[ "$EXECUTABLE" == "$BUILD_DIR/portmon-app" ]]; then
    FRAMEWORK="$(find "$ROOT/.build/artifacts" -name Sparkle.framework -type d -path '*macos*' -print -quit)"
    if [[ -z "$FRAMEWORK" ]]; then
        echo "error: Sparkle.framework not found in SwiftPM artifacts" >&2
        exit 1
    fi
    cp -R "$FRAMEWORK" "$RUN_DIR/"
    if ! otool -l "$RUN_DIR/portmon" | grep -Fq 'path @executable_path ('; then
        install_name_tool -add_rpath "@executable_path" "$RUN_DIR/portmon"
    fi
fi
set +e
"$RUN_DIR/portmon" "${PROGRAM_ARGS[@]}"
STATUS=$?
exit "$STATUS"
