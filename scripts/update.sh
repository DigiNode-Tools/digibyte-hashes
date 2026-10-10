#!/usr/bin/env bash
#
# Name:    update.sh
# Purpose: Find every DigiByte Core release on GitHub, verify the SHA256 hash of its Linux
#          binaries against every source available, pin it in hashes.json, and build the
#          hash files that DigiNode Setup checks its downloads against.
#
# Usage:   scripts/update.sh [--recheck] [--dry-run] [--seed FILE]
#
#   --recheck    Re-download and re-verify every binary, even if nothing has changed on GitHub.
#   --dry-run    Do all the checks but don't write any files.
#   --seed FILE  Hashes recorded previously (e.g. the old sha256sum.json from diginode.tools).
#                Any binary whose hash differs from this file raises an alarm.
#
# Exit codes: 0 = OK, 2 = one or more alarms (also written to $ALARM_FILE if set),
#             anything else = the script itself failed.
#
# Runs on Linux (GitHub Actions) and macOS. Needs bash 3.2+, curl and jq.

set -euo pipefail

# ------------------------------------------------------------------------------------------
# Settings

REPO="DigiByte-Core/digibyte"
OLDEST_TAG="v7.17.2"                                  # Releases older than this are ignored
ARCHS="x86_64 aarch64"
ROLLOUT_DAYS="3 7 11 15"                              # Days after release that each update group gets it. Groups are given these slots in a random order.
TRUSTED_UPLOADERS="JaredTate gto90 DigiSwarm"        # Binaries uploaded by anyone else are put on hold
FORMER_UPLOADERS="ChillingSilence:8"                 # name:N = trusted only for releases older than vN
KEEPALIVE_DAYS=30                                     # Touch hashes.json this often so GitHub doesn't disable the daily schedule

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STATE_FILE="$ROOT/hashes.json"
ALARM_FILE="${ALARM_FILE:-}"

# ------------------------------------------------------------------------------------------
# Options

RECHECK=false
DRY_RUN=false
SEED_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --recheck ) RECHECK=true;;
        --dry-run ) DRY_RUN=true;;
        --seed    ) SEED_FILE="${2:?--seed needs a file}"; shift;;
        *         ) echo "Unknown option: $1" >&2; exit 1;;
    esac
    shift
done

# ------------------------------------------------------------------------------------------
# Helpers

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
touch "$WORK/alarms"

log() {
    printf '%s\n' "$*"
}

alarm() {
    printf 'ALARM: %s\n' "$*" | tee -a "$WORK/alarms" >&2
}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# Use a token if there is one, to avoid the 60 requests/hour limit for anonymous API calls
if [ -z "${GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
    GITHUB_TOKEN=$(gh auth token 2>/dev/null || true)
fi

github_api() {
    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $GITHUB_TOKEN" "$1"
    else
        curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" "$1"
    fi
}

download() {
    curl -fsSL --retry 3 -o "$2" "$1"
}

# Pick a random order for update groups 1-4 and give each one its rollout date
make_rollout() {
    local published="$1" groups=(1 2 3 4) days=($ROLLOUT_DAYS) json="{}" i j t
    for ((i = 3; i > 0; i--)); do
        j=$((RANDOM % (i + 1)))
        t=${groups[i]}; groups[i]=${groups[j]}; groups[j]=$t
    done
    for i in 0 1 2 3; do
        json=$(jq -c --arg g "${groups[i]}" --argjson d "${days[i]}" --arg p "$published" \
            '. + {($g): (($p | fromdate) + $d * 86400 | todate)}' <<<"$json")
    done
    echo "$json"
}

# Apply a jq filter to the working copy of hashes.json
update_state() {
    jq "$@" "$WORK/state.json" > "$WORK/state.tmp"
    mv "$WORK/state.tmp" "$WORK/state.json"
}

# ------------------------------------------------------------------------------------------
# Load what we already know

NOW=$(jq -nr 'now | floor | todate')

if [ -f "$STATE_FILE" ]; then
    jq . "$STATE_FILE" > "$WORK/state.json"
else
    echo '{"releases": {}}' > "$WORK/state.json"
fi

if [ -n "$SEED_FILE" ]; then
    jq . "$SEED_FILE" > "$WORK/seed.json"
else
    echo '{}' > "$WORK/seed.json"
fi

# ------------------------------------------------------------------------------------------
# Get the list of releases (one API call unless there are more than 100)

echo '[]' > "$WORK/releases.json"
page=1
while :; do
    github_api "https://api.github.com/repos/$REPO/releases?per_page=100&page=$page" > "$WORK/page.json"
    [ "$(jq 'length' "$WORK/page.json")" -eq 0 ] && break
    jq -s 'add' "$WORK/releases.json" "$WORK/page.json" > "$WORK/merged.json"
    mv "$WORK/merged.json" "$WORK/releases.json"
    page=$((page + 1))
done

jq -c --arg oldest "$OLDEST_TAG" '
    (map(select(.tag_name == $oldest)) | if length == 0 then error("Release \($oldest) not found on GitHub") else .[0].published_at end) as $cutoff
    | map(select((.draft | not) and .published_at >= $cutoff))
    | sort_by(.published_at) | reverse | .[]' "$WORK/releases.json" > "$WORK/wanted.jsonl"

log "Found $(wc -l < "$WORK/wanted.jsonl" | tr -d ' ') DigiByte Core releases since $OLDEST_TAG"

# ------------------------------------------------------------------------------------------
# Check each release

added=0
unchanged=0

while IFS= read -r release; do
    tag=$(jq -r '.tag_name' <<<"$release")
    key="digibyte-${tag#v}"
    published=$(jq -r '.published_at' <<<"$release")
    prerelease=$(jq -r '.prerelease' <<<"$release")
    stored=$(jq -c --arg k "$key" '.releases[$k] // {}' "$WORK/state.json")
    sums_loaded=false
    hold=false

    for arch in $ARCHS; do
        matches=$(jq -c --arg arch "$arch" '[.assets[] | select(.name | ascii_downcase | test("-" + $arch + "-linux-gnu\\.tar\\.gz$") and (test("debug") | not))]' <<<"$release")
        count=$(jq 'length' <<<"$matches")

        if [ "$count" -eq 0 ]; then
            log "  $key $arch: no binary in this release"
            continue
        fi
        if [ "$count" -gt 1 ]; then
            alarm "$key $arch: expected 1 binary but found $count: $(jq -r 'map(.name) | join(", ")' <<<"$matches")"
            continue
        fi

        asset=$(jq -c '.[0]' <<<"$matches")
        name=$(jq -r '.name' <<<"$asset")
        url=$(jq -r '.browser_download_url' <<<"$asset")
        asset_id=$(jq -r '.id' <<<"$asset")
        size=$(jq -r '.size' <<<"$asset")
        updated=$(jq -r '.updated_at' <<<"$asset")
        uploader=$(jq -r '.uploader.login // ""' <<<"$asset")
        digest=$(jq -r '.digest // "" | sub("^sha256:"; "")' <<<"$asset")

        pinned=$(jq -r --arg a "$arch" '.assets[$a].sha256 // ""' <<<"$stored")
        pinned_folder=$(jq -r --arg a "$arch" '.assets[$a].folder // ""' <<<"$stored")
        pinned_fingerprint=$(jq -r --arg a "$arch" '.assets[$a] // {} | "\(.asset_id):\(.size):\(.updated_at)"' <<<"$stored")

        # Nothing has changed on GitHub since we pinned it, so there's nothing to download
        # (unless it was pinned before we recorded the folder inside the tarball)
        if [ -n "$pinned" ] && [ -n "$pinned_folder" ] && [ "$RECHECK" = false ] \
            && [ "$asset_id:$size:$updated" = "$pinned_fingerprint" ] \
            && { [ -z "$digest" ] || [ "$digest" = "$pinned" ]; }; then
            unchanged=$((unchanged + 1))
            continue
        fi

        if [ -n "$pinned" ] && [ -z "$pinned_folder" ] && [ "$RECHECK" = false ]; then
            log "  $key $arch: checking the tarball layout, which wasn't recorded when it was pinned"
        elif [ -n "$pinned" ] && [ "$RECHECK" = false ]; then
            log "  $key $arch: binary has changed on GitHub since it was pinned - re-verifying"
        fi

        log "  $key $arch: downloading $name"
        download "$url" "$WORK/binary"
        hash=$(sha256 "$WORK/binary")

        verified_by="download"
        ok=true

        # 0. The tarball must contain a single folder with the DigiByte binaries in it. DigiNode Setup
        #    unpacks it into a folder of its own, so the name of this folder doesn't matter.
        tar -tzf "$WORK/binary" | sed 's|^\./||' > "$WORK/listing" || : > "$WORK/listing"
        rm -f "$WORK/binary"
        folder=$(cut -d/ -f1 "$WORK/listing" | sort -u | grep -v '^$' || true)
        if [ "$(printf '%s\n' "$folder" | grep -c .)" -ne 1 ]; then
            alarm "$key $arch: expected the tarball to contain one folder, but found: $(printf '%s ' $folder)"
            ok=false
        elif ! grep -qx "$folder/bin/digibyted" "$WORK/listing" || ! grep -qx "$folder/bin/digibyte-cli" "$WORK/listing"; then
            alarm "$key $arch: the tarball doesn't contain $folder/bin/digibyted and $folder/bin/digibyte-cli"
            ok=false
        fi

        # 1. The hash GitHub calculated when the file was uploaded (only on releases from mid-2025)
        if [ -n "$digest" ]; then
            if [ "$digest" = "$hash" ]; then
                verified_by="$verified_by github-digest"
            else
                alarm "$key $arch: GitHub says the hash is $digest but the download hashes to $hash"
                ok=false
            fi
        fi

        # 2. The SHA256SUMS file published with the release (from v9.26.6rc2 onwards)
        if [ "$sums_loaded" = false ]; then
            : > "$WORK/sums"
            sums_url=$(jq -r '[.assets[] | select(.name == "SHA256SUMS")][0].browser_download_url // ""' <<<"$release")
            [ -n "$sums_url" ] && download "$sums_url" "$WORK/sums"
            sums_loaded=true
        fi
        sums_hash=$(awk -v f="$name" '$2 == f || $2 == "*" f { print $1; exit }' "$WORK/sums")
        if [ -n "$sums_hash" ]; then
            if [ "$sums_hash" = "$hash" ]; then
                verified_by="$verified_by SHA256SUMS"
            else
                alarm "$key $arch: SHA256SUMS says the hash is $sums_hash but the download hashes to $hash"
                ok=false
            fi
        fi

        # 3. A hash recorded previously by hand
        seed_hash=$(jq -r --arg k "$key" --arg a "$arch" '.[$k][$a]? // ""' "$WORK/seed.json")
        if [ -n "$seed_hash" ]; then
            if [ "$seed_hash" = "$hash" ]; then
                verified_by="$verified_by seed"
            else
                alarm "$key $arch: the seed file says the hash is $seed_hash but the download hashes to $hash"
                ok=false
            fi
        fi

        # 4. A hash we pinned on an earlier run must never change
        if [ -n "$pinned" ] && [ "$pinned" != "$hash" ]; then
            alarm "$key $arch: the binary on GitHub has CHANGED since it was pinned. Pinned $pinned, now $hash. The pinned hash has been kept."
            ok=false
        fi

        if [ "$ok" = false ]; then
            continue
        fi

        trusted=false
        case " $TRUSTED_UPLOADERS " in
            *" $uploader "* ) trusted=true;;
        esac
        major=${tag#v}; major=${major%%.*}
        for former in $FORMER_UPLOADERS; do
            if [ "${former%%:*}" = "$uploader" ] && [ "$major" -lt "${former##*:}" ]; then
                trusted=true
            fi
        done
        if [ "$trusted" = false ]; then
            alarm "$key $arch: uploaded by '$uploader', who is not trusted for this release. The release has been put on hold."
            hold=true
        fi

        update_state --arg k "$key" --arg a "$arch" --arg file "$name" --arg url "$url" --arg hash "$hash" \
            --argjson id "$asset_id" --argjson size "$size" --arg updated "$updated" --arg folder "$folder" \
            --arg uploader "$uploader" --arg by "$verified_by" --arg now "$NOW" '
            .releases[$k].assets[$a] = {
                file: $file, url: $url, sha256: $hash, size: $size, folder: $folder,
                asset_id: $id, updated_at: $updated,
                uploader: $uploader, verified_by: ($by | split(" ")), verified_at: $now
            }'

        if [ -z "$pinned" ]; then
            added=$((added + 1))
            log "  $key $arch: pinned $hash (verified by: $verified_by)"
        fi
    done

    # Fill in the release details, keeping any status or rollout already set
    if [ "$(jq --arg k "$key" '.releases[$k].assets != null' "$WORK/state.json")" = true ]; then
        rollout=$(jq -c '.rollout // empty' <<<"$stored")
        [ -n "$rollout" ] || rollout=$(make_rollout "$published")
        update_state --arg k "$key" --arg tag "$tag" --arg published "$published" \
            --argjson prerelease "$prerelease" --argjson rollout "$rollout" --argjson hold "$hold" '
            .releases[$k] |= {
                tag: $tag,
                published_at: $published,
                prerelease: $prerelease,
                status: (if $hold and (.status // "active") == "active" then "hold" else (.status // "active") end),
                rollout: $rollout,
                assets: .assets
            }'
    fi
done < "$WORK/wanted.jsonl"

# Newest first, and touch the keepalive date if it's due
update_state --arg now "$NOW" --argjson days "$KEEPALIVE_DAYS" '
    .releases |= (to_entries | sort_by(.value.published_at) | reverse | from_entries)
    | if ((.keepalive // "1970-01-01T00:00:00Z") | fromdate) + $days * 86400 <= ($now | fromdate)
      then .keepalive = $now else . end
    | {keepalive, releases}'

# ------------------------------------------------------------------------------------------
# Build the hash files for DigiNode Setup
#
#   hash0.json     - staging (used with --updatetest): every verified release that isn't revoked
#   hash1-4.json   - update groups: active releases whose rollout date for that group has passed

for group in 0 1 2 3 4; do
    jq --arg g "$group" --arg now "$NOW" '
        .releases | to_entries
        | map(select(.value.status != "revoked"))
        | map(select($g == "0" or (.value.status == "active" and (.value.rollout[$g] // "9999") <= $now)))
        | map({key, value: (.value.assets | map_values(.sha256))})
        | from_entries' "$WORK/state.json" > "$WORK/hash$group.json"
done

# ------------------------------------------------------------------------------------------
# Build the release files for DigiNode Setup v0.12.0 onwards
#
#   releases0.json   - staging, as hash0.json
#   releases1-4.json - update groups, as hash1-4.json
#
# Each lists the releases available to that group, newest first, with everything needed to download,
# verify and unpack them, so DigiNode Setup never has to work out a file name. "latest" and
# "latest_release" are the newest versions on GitHub, which may still be waiting to reach the group.

latest=$(jq -rs 'first.tag_name // "" | sub("^v"; "")' "$WORK/wanted.jsonl")
latest_release=$(jq -rs 'map(select(.prerelease | not)) | first.tag_name // "" | sub("^v"; "")' "$WORK/wanted.jsonl")

for group in 0 1 2 3 4; do
    jq --arg g "$group" --arg now "$NOW" --arg latest "$latest" --arg latest_release "$latest_release" '
        {
            latest: $latest,
            latest_release: $latest_release,
            releases: [
                .releases | to_entries[]
                | select(.value.status != "revoked")
                | select($g == "0" or (.value.status == "active" and (.value.rollout[$g] // "9999") <= $now))
                | {
                    version: (.key | sub("^digibyte-"; "")),
                    tag: .value.tag,
                    published_at: .value.published_at,
                    prerelease: .value.prerelease,
                    assets: (.value.assets | map_values({file, url, sha256, size, folder}))
                  }
            ]
        }' "$WORK/state.json" > "$WORK/releases$group.json"
done

# ------------------------------------------------------------------------------------------
# Save and report

if [ "$DRY_RUN" = false ]; then
    cp "$WORK/state.json" "$STATE_FILE"
    for group in 0 1 2 3 4; do
        cp "$WORK/hash$group.json" "$ROOT/hash$group.json"
        cp "$WORK/releases$group.json" "$ROOT/releases$group.json"
    done
fi

log ""
log "New hashes pinned: $added    Unchanged: $unchanged"
for group in 0 1 2 3 4; do
    log "  hash$group.json / releases$group.json: $(jq 'length' "$WORK/hash$group.json") releases"
done
[ "$DRY_RUN" = true ] && log "Dry run - no files written"

if [ -s "$WORK/alarms" ]; then
    [ -n "$ALARM_FILE" ] && cp "$WORK/alarms" "$ALARM_FILE"
    log ""
    log "$(wc -l < "$WORK/alarms" | tr -d ' ') alarm(s) raised - see above"
    exit 2
fi
