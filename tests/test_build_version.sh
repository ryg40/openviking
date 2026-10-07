#!/bin/sh
# Check the version step of scripts/build.sh on a branch without upstream
# history, such as portable. See docs/image.md, "Version".
#
# Usage: sh tests/test_build_version.sh
#
# The test copies the tracked files of this tree into a new repository with
# one parentless commit and runs scripts/build.sh there with a stub `docker`
# first on PATH. The stub prints its arguments and the version variables and
# exits 0, so no image is built and Docker is not needed. Checks: the
# fallback to the tag line of scripts/upstream-base with its message line,
# OPENVIKING_VERSION in the environment wins, a portable-v* tag goes into
# the version, an ancestor tag v* wins over the file, and the build stops
# when the file has no valid tag line.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/openviking-build-version-test.XXXXXX")
tmp=$(CDPATH='' cd -- "$tmp" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
failures=0

ok() { printf 'ok - %s\n' "$*"; }
not_ok() {
    printf 'not ok - %s\n' "$*"
    failures=$((failures + 1))
}

base_tag=$(awk -F '\t' '$1 == "tag" { print $2; exit }' "$repo/scripts/upstream-base")
printf '%s\n' "$base_tag" | grep -Eq '^v[0-9]+(\.[0-9]+)*$' || {
    echo "error: no valid tag line in scripts/upstream-base" >&2
    exit 2
}
base_version=${base_tag#v}

# No configuration, hooks or identity of the caller.
HOME=$tmp GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
export HOME GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset OPENVIKING_VERSION PORTABLE_VERSION REVISION SOURCE_DATE_EPOCH BUILD_ENGINE

mkdir "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*"
printf 'env OPENVIKING_VERSION=%s UPSTREAM_VERSION=%s PORTABLE_VERSION=%s\n' \
    "$OPENVIKING_VERSION" "$UPSTREAM_VERSION" "$PORTABLE_VERSION"
EOF
chmod 755 "$tmp/bin/docker"
PATH=$tmp/bin:$PATH

# One parentless commit with the tracked files of this tree.
work=$tmp/work
mkdir "$work"
(cd "$repo" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$work"
git -C "$work" init -q
git -C "$work" symbolic-ref HEAD refs/heads/portable
git -C "$work" add -A
git -C "$work" commit -q -m 'Promote test'
sha=$(git -C "$work" rev-parse --short=8 HEAD)

# run NAME [VAR=VALUE...]: run build.sh smoke in $work, keep status and output.
run() {
    name=$1
    shift
    status=0
    (cd "$work" && env "$@" sh scripts/build.sh smoke) >"$tmp/$name.out" 2>"$tmp/$name.err" || status=$?
}
has() { grep -qF -- "$2" "$tmp/$1.$3"; }

fallback_line="build: upstream version $base_tag from scripts/upstream-base (no upstream tag in the history)"

run fallback
if [ "$status" -eq 0 ]; then ok "fallback: exit 0"; else not_ok "fallback: exit $status: $(cat "$tmp/fallback.err")"; fi
if has fallback "$fallback_line" err; then ok "fallback: message line"; else not_ok "fallback: no message line"; fi
if has fallback "docker buildx bake -f docker-bake.hcl smoke" out; then ok "fallback: reaches bake"; else not_ok "fallback: bake not called"; fi
if has fallback "env OPENVIKING_VERSION=$base_version+p0.g$sha UPSTREAM_VERSION=$base_version PORTABLE_VERSION=0-g$sha" out; then
    ok "fallback: version $base_version+p0.g$sha"
else
    not_ok "fallback: version: $(grep '^env' "$tmp/fallback.out" || true)"
fi

run override OPENVIKING_VERSION=1.2.3+p9.9.9
if [ "$status" -eq 0 ] && has override "env OPENVIKING_VERSION=1.2.3+p9.9.9 UPSTREAM_VERSION=1.2.3 " out; then
    ok "override: OPENVIKING_VERSION wins"
else
    not_ok "override: exit $status: $(grep '^env' "$tmp/override.out" || true)"
fi
if has override "$fallback_line" err; then not_ok "override: fallback line printed"; else ok "override: no fallback line"; fi

git -C "$work" tag portable-v0.1.0
run tagged
if [ "$status" -eq 0 ] && has tagged "env OPENVIKING_VERSION=$base_version+p0.1.0 UPSTREAM_VERSION=$base_version PORTABLE_VERSION=0.1.0" out; then
    ok "portable tag: version $base_version+p0.1.0"
else
    not_ok "portable tag: exit $status: $(grep '^env' "$tmp/tagged.out" || true)"
fi
git -C "$work" tag -d portable-v0.1.0 >/dev/null

# An ancestor tag wins over the file.
git -C "$work" tag v0.0.1
git -C "$work" commit -q --allow-empty -m next
run ancestor
if [ "$status" -eq 0 ] && has ancestor "UPSTREAM_VERSION=0.0.1 " out; then
    ok "ancestor tag: v0.0.1 wins"
else
    not_ok "ancestor tag: exit $status: $(grep '^env' "$tmp/ancestor.out" || true)"
fi
if has ancestor "$fallback_line" err; then not_ok "ancestor tag: fallback line printed"; else ok "ancestor tag: no fallback line"; fi
git -C "$work" tag -d v0.0.1 >/dev/null

# Podman gets the same version values, image arguments and labels as bake.
cat >"$tmp/bin/podman" <<'EOF'
#!/bin/sh
if [ "$1 $2" = 'image exists' ]; then exit "${PODMAN_IMAGE_EXISTS:-1}"; fi
printf 'podman %s\n' "$*"
EOF
chmod 755 "$tmp/bin/podman"
podman_sha=$(git -C "$work" rev-parse --short=8 HEAD)
run podman BUILD_ENGINE=podman GATEWAY_IMAGE=openviking-pp-mac-podman:test SOURCE_DATE_EPOCH=0
if [ "$status" -eq 0 ] && has podman "podman build -f Dockerfile --build-arg OPENVIKING_VERSION=$base_version+p0.g$podman_sha" out &&
    has podman '--label org.opencontainers.image.created=1970-01-01T00:00:00Z' out &&
    has podman '-t openviking-pp-mac-podman:test .' out &&
    [ "$(grep -c '^podman run --rm --network none openviking-pp-mac-podman:test ' "$tmp/podman.out")" -eq 2 ]; then
    ok 'podman: missing image builds with the version, UTC label and two offline checks'
else
    not_ok "podman: exit $status or missing build arguments, label or checks"
fi
for variable in UV_LOCK_STRATEGY REGISTRY_PREFIX RUST_IMAGE RUST_DIGEST NODE_IMAGE NODE_DIGEST PYTHON_IMAGE PYTHON_DIGEST SOURCE_DATE_EPOCH; do
    if has podman "--build-arg $variable=" out; then ok "podman: argument $variable"; else not_ok "podman: missing $variable"; fi
done
for label in source revision version title licenses; do
    if has podman "--label org.opencontainers.image.$label=" out; then ok "podman: label $label"; else not_ok "podman: missing $label"; fi
done
if has podman '--platform' out || has podman 'docker buildx' out; then not_ok 'podman: uses platform override or bake'; else ok 'podman: native build, no bake'; fi
run existing BUILD_ENGINE=podman PODMAN_IMAGE_EXISTS=0
if [ "$status" -eq 0 ] && ! has existing 'podman build ' out && [ "$(grep -c '^podman run ' "$tmp/existing.out")" -eq 2 ]; then
    ok 'podman: smoke reuses an existing image'
else
    not_ok 'podman: smoke did not reuse the image'
fi
for target in gateway test release; do
    status=0
    (cd "$work" && BUILD_ENGINE=podman PODMAN_IMAGE_EXISTS=0 SOURCE_DATE_EPOCH=0 sh scripts/build.sh "$target") \
        >"$tmp/$target.out" 2>"$tmp/$target.err" || status=$?
    case $target in
        gateway)
            if [ "$status" -eq 0 ] && has gateway 'podman build ' out; then ok 'podman: gateway always builds'; else not_ok 'podman: gateway did not build'; fi
            ;;
        *)
            if [ "$status" -eq 1 ] && has "$target" 'needs BuildKit (docker buildx bake)' err; then ok "podman: $target refuses without BuildKit"; else not_ok "podman: $target refusal"; fi
            ;;
    esac
done

# No valid tag line: the build stops before bake.
awk -F '\t' -v OFS='\t' '$1 == "tag" { $2 = "not-a-tag" } { print }' \
    "$work/scripts/upstream-base" >"$tmp/upstream-base"
cp "$tmp/upstream-base" "$work/scripts/upstream-base"
git -C "$work" commit -q -a -m 'bad tag line'
run badtag
if [ "$status" -eq 1 ] && has badtag "scripts/upstream-base has no valid tag line" err; then
    ok "bad tag line: exit 1 with message"
else
    not_ok "bad tag line: exit $status: $(cat "$tmp/badtag.err")"
fi
if [ -s "$tmp/badtag.out" ]; then not_ok "bad tag line: bake called"; else ok "bad tag line: bake not called"; fi

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
else
    echo "$failures test(s) failed"
    exit 1
fi
