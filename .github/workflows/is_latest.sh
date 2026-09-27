#!/usr/bin/env bash

set -euo pipefail

versions=$(curl --fail --silent --show-error https://nwjs.io/versions.json)

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
    : "${NW_VERSION:?NW_VERSION must be set when the workflow is dispatched manually}"
else
    NW_VERSION=$(jq -er '.latest | ltrimstr("v")' <<<"$versions")

    # A 404 means this NW.js version has not been released yet.  Make the
    # scheduled workflow fail when the release already exists so it does not
    # trigger an unnecessary build.
    curl --silent --output /dev/null --write-out '%{http_code}' \
        "https://github.com/nwjs-ffmpeg-prebuilt/nwjs-ffmpeg-prebuilt/releases/download/${NW_VERSION}/${NW_VERSION}-linux-x64.zip" \
        | grep --quiet '^404$'
fi

write_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "$1=$2" >> "$GITHUB_OUTPUT"
    else
        echo "$1=$2"
    fi
}

# Gitiles returns base64-encoded file contents for ?format=TEXT.  Do not let a
# failed lookup become an empty commit SHA and later show up as a misleading
# "base64: invalid input" error while reading a version header.
gitiles_file() {
    local url=$1 encoded

    encoded=$(curl --fail --silent --show-error "${url}?format=TEXT")
    printf '%s' "$encoded" | base64 --decode
}

write_output nw "$NW_VERSION"

CHROMIUM=$(jq -er --arg version "v${NW_VERSION}" \
    '.versions[] | select(.version == $version) | .components.chromium' <<<"$versions")
write_output chromium "$CHROMIUM"

COMMIT=$(gitiles_file "https://chromium.googlesource.com/chromium/src.git/+/refs/tags/${CHROMIUM}/DEPS" \
    | sed -nE "s/.*['\"]ffmpeg_revision['\"][[:space:]]*:[[:space:]]*['\"]([0-9a-f]{40})['\"].*/\1/p" \
    | head -n 1)

if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Unable to find the FFmpeg revision in Chromium ${CHROMIUM}'s DEPS file." >&2
    exit 1
fi
write_output commit "$COMMIT"

FFMPEG_URL=https://chromium.googlesource.com/chromium/third_party/ffmpeg

version_major() {
    local file=$1 macro=$2

    gitiles_file "${FFMPEG_URL}/+/${COMMIT}/${file}" \
        | sed -nE "s/^#[[:space:]]*define[[:space:]]+${macro}[[:space:]]+([0-9]+).*/\1/p" \
        | head -n 1
}

AVCODEC=$(version_major libavcodec/version_major.h LIBAVCODEC_VERSION_MAJOR)
AVFORMAT=$(version_major libavformat/version_major.h LIBAVFORMAT_VERSION_MAJOR)
AVUTIL=$(version_major libavutil/version.h LIBAVUTIL_VERSION_MAJOR)

for variable in AVCODEC AVFORMAT AVUTIL; do
    if [[ ! ${!variable} =~ ^[0-9]+$ ]]; then
        echo "Unable to determine ${variable,,} major version from FFmpeg ${COMMIT}." >&2
        exit 1
    fi
done

write_output avcodec "$AVCODEC"
write_output avformat "$AVFORMAT"
write_output avutil "$AVUTIL"
