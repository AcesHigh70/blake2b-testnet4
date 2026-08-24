#!/usr/bin/env bash
#
# Sign and publish a Shrike release from a completed Package workflow run.
#
# The workflow builds the binaries and generates SHA256SUMS. Everything after that happens here: the
# artifacts are downloaded, flattened, verified against the checksums the workflow produced, and only
# then signed. The signature is made locally and the key never leaves this machine, which is the whole
# reason this is a script on a laptop rather than another workflow job.
#
# Publishing is opt-in. Without --publish the script stops after signing and prints the command it
# would have run, so a release is never created by a script that was only meant to check its own work.
#
# Usage: ./sign-release.sh <run-id> <tag> [--publish]
#   e.g. ./sign-release.sh 32782169560 v2.5.4-knots20260508rc2.1

set -euo pipefail

REPO="${SHRIKE_REPO:-AcesHigh70/sparrow}"
SIGNING_KEY="${SHRIKE_SIGNING_KEY:-C9E21BFBDFC040AB9BE85AFB2053BF4810B0A6FB}"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

PUBLISH=0
ARGS=()
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        -h|--help) sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $arg" ;;
        *) ARGS+=("$arg") ;;
    esac
done

[ ${#ARGS[@]} -eq 2 ] || die "usage: $(basename "$0") <run-id> <tag> [--publish]"
RUN_ID="${ARGS[0]}"
TAG="${ARGS[1]}"

[[ "$RUN_ID" =~ ^[0-9]+$ ]] || die "run id must be numeric, got '$RUN_ID'"

# Checked before anything is downloaded or signed, so a mistyped tag costs nothing
step "Checking prerequisites"
for tool in gh gpg sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done
gh auth status >/dev/null 2>&1 || die "gh is not authenticated, run: gh auth login"
gpg --list-secret-keys "$SIGNING_KEY" >/dev/null 2>&1 || die "no secret key for $SIGNING_KEY in this keyring"
printf '  gh, gpg, sha256sum present; secret key %s available\n' "$SIGNING_KEY"

# A tag that already exists means this release was published before. Say so now rather than after the
# operator has entered a passphrase and signed something they cannot use.
step "Checking tag $TAG"
if gh api "repos/$REPO/git/ref/tags/$TAG" >/dev/null 2>&1; then
    die "tag $TAG already exists on $REPO. Pick the next iteration, or delete the tag deliberately."
fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    die "a release for $TAG already exists on $REPO"
fi
printf '  %s is free on %s\n' "$TAG" "$REPO"

# The macOS matrix arms fail on missing codesigning secrets, so the run's overall conclusion is failure
# on a perfectly good build. What matters is that the artifacts exist, which the download proves.
step "Downloading artifacts from run $RUN_ID"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shrike-release-$TAG-XXXXXX")"
printf '  working directory: %s\n' "$WORK_DIR"
DOWNLOAD_DIR="$WORK_DIR/artifacts"
RELEASE_DIR="$WORK_DIR/release"
mkdir -p "$DOWNLOAD_DIR" "$RELEASE_DIR"
gh run download "$RUN_ID" --repo "$REPO" --dir "$DOWNLOAD_DIR"

SUMS_SOURCE="$(find "$DOWNLOAD_DIR" -type f -name SHA256SUMS -print -quit)"
[ -n "$SUMS_SOURCE" ] || die "run $RUN_ID has no SHA256SUMS artifact"
cp "$SUMS_SOURCE" "$RELEASE_DIR/SHA256SUMS"

# Filenames come from SHA256SUMS rather than a list kept here, so adding or dropping a build target
# needs no change to this script.
step "Collecting the binaries SHA256SUMS names"
mapfile -t WANTED < <(sed -n 's/^[0-9a-f]\{64\}  //p' "$RELEASE_DIR/SHA256SUMS")
[ ${#WANTED[@]} -gt 0 ] || die "SHA256SUMS is empty or not in '<hash>  <filename>' form"

for name in "${WANTED[@]}"; do
    mapfile -t found < <(find "$DOWNLOAD_DIR" -type f -name "$name")
    case ${#found[@]} in
        0) printf '  missing: %s\n' "$name" ;;
        1) cp "${found[0]}" "$RELEASE_DIR/$name"; printf '  collected: %s\n' "$name" ;;
        *) die "$name appears in more than one artifact, so a checksum line cannot identify it:
$(printf '    %s\n' "${found[@]}")" ;;
    esac
done

# Plain -c, deliberately not --ignore-missing: a file named in SHA256SUMS that did not arrive is a
# broken release, not something to skip past.
step "Verifying checksums"
( cd "$RELEASE_DIR" && sha256sum -c SHA256SUMS ) || die "checksum verification failed"

step "SHA256SUMS to be signed ($(wc -l < "$RELEASE_DIR/SHA256SUMS") entries)"
cat "$RELEASE_DIR/SHA256SUMS"

[ -e "$RELEASE_DIR/SHA256SUMS.asc" ] && die "SHA256SUMS.asc already exists in $RELEASE_DIR"

printf '\nSign the above with %s? [y/N] ' "$SIGNING_KEY"
read -r reply
case "$reply" in
    y|Y|yes|YES) ;;
    *) printf '\nStopped before signing. Files remain in %s\n' "$WORK_DIR"; exit 0 ;;
esac

# gpg needs to know which terminal to prompt on, or pinentry cannot ask for the passphrase. Without
# this, signing over ssh fails with "Inappropriate ioctl for device" or a bare "signing failed".
step "Signing"
GPG_TTY="$(tty || true)"
export GPG_TTY
gpg --detach-sign --armor --local-user "$SIGNING_KEY" "$RELEASE_DIR/SHA256SUMS"
[ -s "$RELEASE_DIR/SHA256SUMS.asc" ] || die "gpg produced no signature"

# Verifying our own signature is not ceremony: it catches a truncated or wrong-key signature here
# rather than leaving someone to discover it against a published release.
step "Verifying the signature"
gpg --verify "$RELEASE_DIR/SHA256SUMS.asc" "$RELEASE_DIR/SHA256SUMS"

step "Release assets"
ASSETS=("$RELEASE_DIR/SHA256SUMS" "$RELEASE_DIR/SHA256SUMS.asc")
for name in "${WANTED[@]}"; do
    ASSETS+=("$RELEASE_DIR/$name")
done
printf '  %s\n' "${ASSETS[@]}"

# rc builds are published as pre-releases, and this script only ever makes rc builds so far.
RELEASE_CMD=(gh release create "$TAG" --repo "$REPO" --title "$TAG" --prerelease --notes "Shrike $TAG")
RELEASE_CMD+=("${ASSETS[@]}")

step "Publish"
if [ "$PUBLISH" -eq 1 ]; then
    "${RELEASE_CMD[@]}"
    printf '\nPublished %s\n' "$TAG"
else
    printf '  --publish not given, so nothing was created. The command that would run:\n\n'
    printf '%q ' "${RELEASE_CMD[@]}"
    printf '\n'
fi

printf '\nSigned files are in %s\n' "$RELEASE_DIR"
