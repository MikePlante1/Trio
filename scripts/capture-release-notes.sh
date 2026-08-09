#!/bin/sh
#  capture-release-notes.sh
#  Trio
#
#  Bundles the GitHub release notes for the version being built, so the "What's New"
#  panel has something to show when the device is offline or GitHub is unreachable.
#
#  At runtime Trio still prefers a live fetch, because release notes are sometimes
#  edited after publishing. This is only the fallback.
#
#  The release is looked up by the exact tag "v${APP_VERSION}". Development builds
#  carry a four-part APP_DEV_VERSION that matches no published release, so nothing is
#  bundled for them and the panel stays hidden - which is intended.
#
#  This never fails the build. No network, no release, no GitHub - the app simply
#  falls back to a live fetch, and shows nothing if that fails too.

set -u

RESOURCE_DIR="${BUILT_PRODUCTS_DIR:-}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}"
OUTPUT="${RESOURCE_DIR}/BundledReleaseNotes.json"
REPO="nightscout/Trio"

warn() {
  echo "warning: capture-release-notes: ${*}" >&2
}

# Always start from a clean slate so a stale file from a previous version cannot
# survive into this build.
rm -f "${OUTPUT}"

if [ ! -d "${RESOURCE_DIR}" ]; then
  warn "resource directory not found, skipping"
  exit 0
fi

# APP_VERSION comes from Config.xcconfig. Fall back to the built Info.plist value.
version="${APP_VERSION:-}"
if [ -z "${version}" ]; then
  version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "${BUILT_PRODUCTS_DIR:-}/${INFOPLIST_PATH:-}" 2>/dev/null || echo "")
fi

# PlistBuddy reports failures on stdout rather than stderr, so an unreadable plist
# would otherwise be treated as the version string. Insist on a dotted numeric
# version before it is used to build a URL.
if ! echo "${version}" | grep -Eq '^[0-9]+(\.[0-9]+)*$'; then
  warn "could not determine a valid app version, skipping"
  exit 0
fi

tag="v${version}"
echo "capture-release-notes: looking up ${REPO} release ${tag}"

# --fail so a 404 (no release for this tag, e.g. a dev build) is not written out as
# an error payload. Short timeouts so an offline build is not held up.
if ! curl --fail --silent --show-error --location \
  --connect-timeout 5 --max-time 20 \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${REPO}/releases/tags/${tag}" \
  -o "${OUTPUT}.raw" 2>/dev/null
then
  warn "no published release found for ${tag} (or GitHub unreachable); building without bundled notes"
  rm -f "${OUTPUT}.raw"
  exit 0
fi

# Reduce the API payload to just the fields the app reads, so the bundle does not
# carry the entire release object.
if ! /usr/bin/python3 - "${OUTPUT}.raw" "${OUTPUT}" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
try:
    with open(src, encoding="utf-8") as handle:
        release = json.load(handle)
    payload = {
        "tagName": release["tag_name"],
        "name": release.get("name") or release["tag_name"],
        "body": release.get("body") or "",
        "htmlURL": release["html_url"],
        "publishedAt": release.get("published_at") or "",
    }
    with open(dst, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False)
except Exception as error:  # noqa: BLE001 - build step must never hard-fail
    print(f"could not parse release payload: {error}", file=sys.stderr)
    raise SystemExit(1)
PY
then
  warn "could not parse release payload; building without bundled notes"
  rm -f "${OUTPUT}" "${OUTPUT}.raw"
  exit 0
fi

rm -f "${OUTPUT}.raw"
echo "capture-release-notes: bundled release notes for ${tag}"
