#!/bin/bash
# --------------------------------------------------------------------------
# fork-release.sh
# Builds, signs and publishes a release of the DotRacel fork to the fork's own Sparkle update feed.
#
#   ./fork-release.sh build [notes.md]   Release build -> zip -> EdDSA signature -> staged appcast item. Local only.
#   ./fork-release.sh publish            Uploads the staged zip as a GitHub release on DotRacel/mac-mouse-fix,
#                                        adds the item to appcast.xml on the `update-feed` branch, pushes, and
#                                        commits the build number bump on the current branch.
#
# [Nov 2026] Notes:
# - Feed: https://raw.githubusercontent.com/DotRacel/mac-mouse-fix/update-feed/appcast.xml
#   (`SUFeedURL` in App/SupportFiles/Info.plist and `kMFUpdateFeedRepoAddressRaw` in Shared/Constants.h)
# - The private key lives in the login keychain in Sparkle's own format
#   (service "https://sparkle-project.org", account "ed25519", password = base64 32-byte seed),
#   so Sparkle's `sign_update` / `generate_keys -p` work with it, too. Its public key is `SUPublicEDKey`.
# - Sparkle only offers an update whose build number (CFBundleVersion) is higher than the installed one,
#   and our SparkleUpdaterController only compares build numbers when the short version is equal.
#   So the build number bump from the Release build must be kept (committed) – `publish` does that.
# - Signing uses xcconfig/Local.xcconfig (personal team). Needs Homebrew openssl (Ed25519).
# --------------------------------------------------------------------------

set -euo pipefail

REPO_SLUG="DotRacel/mac-mouse-fix"
FEED_BRANCH="update-feed"
ROOT="$(cd "$(dirname "$0")" && pwd)"
STAGE="$ROOT/build-fork-release"          # in .gitignore? -> added to .git/info/exclude below
DD="/tmp/mmf-dd-release-signed"
FEED_WT="/tmp/mmf-update-feed"
OPENSSL="${OPENSSL:-/opt/homebrew/bin/openssl}"
APP_PLIST="$ROOT/App/SupportFiles/Info.plist"
HELPER_PLIST="$ROOT/Helper/SupportFiles/Info.plist"

die() { echo "error: $*" >&2; exit 1; }
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }

grep -qx "/build-fork-release/" "$ROOT/.git/info/exclude" 2>/dev/null || echo "/build-fork-release/" >> "$ROOT/.git/info/exclude"

feed_worktree() {
    git -C "$ROOT" fetch -q origin "$FEED_BRANCH" 2>/dev/null || true
    if [ ! -d "$FEED_WT" ]; then
        git -C "$ROOT" worktree prune
        if git -C "$ROOT" show-ref -q "refs/remotes/origin/$FEED_BRANCH"; then
            git -C "$ROOT" worktree add -q -B "$FEED_BRANCH" "$FEED_WT" "origin/$FEED_BRANCH"
        else
            git -C "$ROOT" worktree add -q "$FEED_WT" "$FEED_BRANCH"
        fi
    fi
    git -C "$FEED_WT" pull -q --ff-only origin "$FEED_BRANCH" 2>/dev/null || true
}

latest_feed_build() { # Highest sparkle:version in the feed (0 if none)
    grep -o 'sparkle:version="[0-9]*"' "$FEED_WT/appcast.xml" 2>/dev/null | grep -o '[0-9]*' | sort -n | tail -1 || true
}

private_key_pem() { # Sparkle keychain seed -> PKCS#8 PEM (on stdout)
    local seed
    seed=$(security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w) || die "Sparkle private key not found in keychain"
    { printf '302e020100300506032b657004220420' | xxd -r -p; echo "$seed" | base64 -d; } \
        | "$OPENSSL" pkey -inform DER -outform PEM
}

cmd_build() {
    local notes="${1:-}"
    [ -z "$notes" ] || [ -f "$notes" ] || die "notes file not found: $notes"
    [ -f "$ROOT/xcconfig/Local.xcconfig" ] || die "xcconfig/Local.xcconfig missing"
    "$OPENSSL" version | grep -q '^OpenSSL [3-9]' || die "need OpenSSL 3+ at $OPENSSL"
    [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || echo "warning: working tree has uncommitted changes – they will be part of this build"

    feed_worktree

    # Make sure the new build number is higher than everything already published or installed.
    local cur feed inst floor
    cur=$(pb CFBundleVersion "$APP_PLIST")
    feed=$(latest_feed_build); feed=${feed:-0}
    inst=$(defaults read "/Applications/Mac Mouse Fix.app/Contents/Info" CFBundleVersion 2>/dev/null || echo 0)
    floor=$(( feed > inst ? feed : inst ))
    if [ "$cur" -lt "$floor" ]; then
        echo "Raising CFBundleVersion $cur -> $floor (so the build becomes $((floor+1)))"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $floor" "$APP_PLIST"
    fi

    echo "Building (Release, signed with Local.xcconfig) ..."
    local log="$STAGE/xcodebuild.log"; mkdir -p "$STAGE"
    (cd "$ROOT" && XCODE_XCCONFIG_FILE="$ROOT/xcconfig/Local.xcconfig" xcodebuild -project "Mouse Fix.xcodeproj" \
        -scheme App -configuration Release -derivedDataPath "$DD" build) > "$log" 2>&1 \
        || { grep ' error:' "$log" | head -20; die "build failed (log: $log)"; }

    local app="$DD/Build/Products/Release/Mac Mouse Fix.app"
    local short build feedurl pub
    short=$(pb CFBundleShortVersionString "$app/Contents/Info.plist")
    build=$(pb CFBundleVersion "$app/Contents/Info.plist")
    feedurl=$(pb SUFeedURL "$app/Contents/Info.plist")
    pub=$(pb SUPublicEDKey "$app/Contents/Info.plist")
    [[ "$feedurl" == *"$REPO_SLUG"* ]] || die "built app's SUFeedURL is not the fork's: $feedurl"
    [ "$build" -gt "$floor" ] || die "build number $build is not higher than published/installed $floor"
    codesign --verify --deep --strict "$app" || die "codesign verification failed"

    local tag="$short-$build" zip="MacMouseFix-$short-$build.zip"
    rm -f "$STAGE"/*.zip
    ditto -c -k --sequesterRsrc --keepParent "$app" "$STAGE/$zip"

    # EdDSA signature (Sparkle format: base64 of the raw 64-byte Ed25519 signature over the archive).
    local pem sig len
    pem=$(mktemp); trap 'rm -f "$pem"' RETURN
    private_key_pem > "$pem"
    sig=$("$OPENSSL" pkeyutl -sign -rawin -inkey "$pem" -in "$STAGE/$zip" | base64)
    len=$(stat -f %z "$STAGE/$zip")

    # Verify against the public key that is actually inside the built app.
    local pubpem; pubpem=$(mktemp)
    { printf '302a300506032b6570032100' | xxd -r -p; echo "$pub" | base64 -d; } | "$OPENSSL" pkey -pubin -inform DER -outform PEM > "$pubpem"
    echo "$sig" | base64 -d > "$STAGE/.sig"
    "$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$pubpem" -in "$STAGE/$zip" -sigfile "$STAGE/.sig" >/dev/null \
        || die "signature does not verify against SUPublicEDKey of the built app"
    rm -f "$pubpem" "$STAGE/.sig"

    local notes_html=""
    [ -n "$notes" ] && notes_html=$(python3 -I - "$notes" <<'PY'
import sys, html
out, in_list = [], False
for line in open(sys.argv[1], encoding="utf-8").read().splitlines():
    s = line.strip()
    if s.startswith(("- ", "* ")):
        if not in_list: out.append("<ul>"); in_list = True
        out.append("<li>%s</li>" % html.escape(s[2:]))
        continue
    if in_list: out.append("</ul>"); in_list = False
    if s.startswith("#"): out.append("<h3>%s</h3>" % html.escape(s.lstrip("# ")))
    elif s: out.append("<p>%s</p>" % html.escape(s))
if in_list: out.append("</ul>")
print("\n".join(out))
PY
)
    local minos; minos=$(pb LSMinimumSystemVersion "$app/Contents/Info.plist" 2>/dev/null || echo 10.15)
    cat > "$STAGE/item.xml" <<EOF
    <item>
    <title>$short ($build)</title>
    <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
    <sparkle:minimumSystemVersion>$minos</sparkle:minimumSystemVersion>
    <description><![CDATA[
$notes_html
    ]]></description>
    <enclosure url="https://github.com/$REPO_SLUG/releases/download/$tag/$zip" sparkle:version="$build" sparkle:shortVersionString="$short" sparkle:edSignature="$sig" length="$len" type="application/octet-stream"/>
    </item>
EOF
    printf '%s\n%s\n%s\n' "$tag" "$zip" "${notes:-}" > "$STAGE/meta"
    echo
    echo "Staged $short ($build): $STAGE/$zip ($len bytes), signature verified."
    echo "Next: ./fork-release.sh publish"
}

cmd_publish() {
    [ -f "$STAGE/meta" ] || die "nothing staged – run ./fork-release.sh build first"
    local tag zip notes build
    { read -r tag; read -r zip; read -r notes || true; } < "$STAGE/meta"
    build=${tag##*-}
    feed_worktree
    local lf; lf=$(latest_feed_build); lf=${lf:-0}
    [ "$lf" -lt "$build" ] || die "feed already has build $lf >= $build"

    echo "Creating GitHub release $tag on $REPO_SLUG ..."
    local body="基于 Mac Mouse Fix 的个人 fork 构建，不是官方版本。"
    [ -n "$notes" ] && [ -f "$notes" ] && body="$body"$'\n\n'"$(cat "$notes")"
    gh release create "$tag" "$STAGE/$zip" -R "$REPO_SLUG" --title "$tag" --notes "$body" --target "$(git -C "$ROOT" rev-parse HEAD)"

    echo "Adding item to appcast.xml on $FEED_BRANCH ..."
    python3 -I - "$FEED_WT/appcast.xml" "$STAGE/item.xml" <<'PY'
import sys
path, item = sys.argv[1], open(sys.argv[2], encoding="utf-8").read()
xml = open(path, encoding="utf-8").read()
marker = "<language>en</language>\n"
assert marker in xml, "appcast.xml has no <language> line to insert after"
open(path, "w", encoding="utf-8").write(xml.replace(marker, marker + item, 1))
PY
    git -C "$FEED_WT" add appcast.xml
    git -C "$FEED_WT" commit -q -m "Add $tag to the update feed."
    git -C "$FEED_WT" push -q -u origin "$FEED_BRANCH"

    echo "Committing build number bump ..."
    git -C "$ROOT" add "$APP_PLIST" "$HELPER_PLIST"
    git -C "$ROOT" diff --cached --quiet || git -C "$ROOT" commit -q -m "Bump build number to $build (release $tag)." -- "$APP_PLIST" "$HELPER_PLIST"

    rm -f "$STAGE/meta"
    echo "Published $tag. Feed: https://raw.githubusercontent.com/$REPO_SLUG/$FEED_BRANCH/appcast.xml"
}

case "${1:-}" in
    build)   shift; cmd_build "$@" ;;
    publish) cmd_publish ;;
    *) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
