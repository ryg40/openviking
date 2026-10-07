#!/bin/sh
# Build the OpenViking image from this source tree with docker-bake.hcl.
#
# Usage: scripts/build.sh [--push] [--oci FILE] smoke|gateway|test|release
#   smoke    import the package and find the ov, openviking-server and
#            openviking-entrypoint commands in the built image
#   gateway  smoke, then load the image into the local Docker as $GATEWAY_IMAGE
#   test     run the upstream lite test set inside the built image
#   release  smoke, then build $RELEASE_PLATFORMS; needs a clean tree and
#            --oci FILE (an OCI archive) or --push (to $RELEASE_IMAGE)
#
# The Git-derived values below go to the bake file as variables. Each one
# can be set in the environment to override it: OPENVIKING_VERSION,
# PORTABLE_VERSION, REVISION, SOURCE_DATE_EPOCH. Other bake variables
# (GATEWAY_IMAGE, RELEASE_IMAGE, RELEASE_PLATFORMS, REGISTRY_PREFIX,
# UV_LOCK_STRATEGY, SOURCE_URL, PROVENANCE) and BUILDX_BUILDER pass through.
# BUILD_ENGINE=podman builds gateway and checks smoke without BuildKit.
# BUILD_ENGINE defaults to docker. Nothing is pushed without --push. See docs/image.md.

set -eu

usage() {
    printf 'usage: %s [--push] [--oci FILE] smoke|gateway|test|release\n' "$0" >&2
    exit 2
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

push=0
oci=
target=
while [ $# -gt 0 ]; do
    case $1 in
        --push) push=1 ;;
        --oci)
            [ $# -ge 2 ] || usage
            oci=$2
            shift
            ;;
        --oci=*) oci=${1#--oci=} ;;
        smoke | gateway | test | release)
            [ -z "$target" ] || usage
            target=$1
            ;;
        *) usage ;;
    esac
    shift
done
[ -n "$target" ] || usage
BUILD_ENGINE=${BUILD_ENGINE:-docker}

if [ -n "$oci" ]; then
    case $oci in
        /*) ;;
        *) oci=$(pwd)/$oci ;;
    esac
fi

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd -- "$script_dir/.."
[ -f docker-bake.hcl ] || die "docker-bake.hcl not found in $(pwd)"
git rev-parse --verify --quiet HEAD >/dev/null || die "not a Git work tree with a commit"

# The bake file repeats the base image pins of the Dockerfile so that
# `bake --print` shows them. Refuse to build when the two copies differ.
for name in RUST_IMAGE RUST_DIGEST NODE_IMAGE NODE_DIGEST PYTHON_IMAGE PYTHON_DIGEST; do
    in_dockerfile=$(sed -n "s/^ARG $name=//p" Dockerfile)
    in_bake=$(awk -v v="variable \"$name\" {" '
        index($0, v) == 1 { found = 1; next }
        found && $1 == "default" { gsub(/^[^"]*"|"[^"]*$/, ""); print; exit }' docker-bake.hcl)
    [ -n "$in_dockerfile" ] && [ "$in_dockerfile" = "$in_bake" ] ||
        die "$name differs: Dockerfile '$in_dockerfile', docker-bake.hcl '$in_bake'"
done

dirty=0
if [ -n "$(git status --porcelain)" ]; then
    dirty=1
fi
if [ "$target" = release ]; then
    if [ "$BUILD_ENGINE" = docker ]; then
        [ "$dirty" -eq 0 ] || die "release refuses a dirty tree; commit or remove the changes first"
        [ "$push" -eq 1 ] || [ -n "$oci" ] || die "release needs --push or --oci FILE"
        [ "$push" -eq 0 ] || [ -z "$oci" ] || die "give --push or --oci FILE, not both"
    fi
elif [ "$push" -eq 1 ] || [ -n "$oci" ]; then
    die "--push and --oci apply to release only"
fi

sha=$(git rev-parse --short=8 HEAD)
: "${REVISION:=$(git rev-parse HEAD)}"
: "${SOURCE_DATE_EPOCH:=$(git log -1 --format=%ct HEAD)}"

# Portable version: the nearest portable-v* tag, else 0-g<sha>.
if [ -z "${PORTABLE_VERSION:-}" ]; then
    if described=$(git describe --tags --abbrev=8 --match 'portable-v*' HEAD 2>/dev/null); then
        PORTABLE_VERSION=${described#portable-v}
    else
        PORTABLE_VERSION=0-g$sha
    fi
    if [ "$dirty" -eq 1 ]; then
        PORTABLE_VERSION=$PORTABLE_VERSION-dirty
    fi
fi

# Upstream version: the nearest ancestor tag v<digits>(.<digits>)* in
# refs/tags/ (existing clone) or refs/upstream/tags/ (scripts/fetch-upstream.sh),
# with the tag pattern of scripts/build_support/versioning.py.
upstream_tag=
best=
for ref in $(git for-each-ref --format='%(refname)' 'refs/tags/v*' 'refs/upstream/tags/v*'); do
    name=${ref##*/}
    printf '%s\n' "$name" | grep -Eq '^v[0-9]+(\.[0-9]+)*$' || continue
    git merge-base --is-ancestor "$ref" HEAD 2>/dev/null || continue
    distance=$(git rev-list --count "$ref..HEAD")
    if [ -z "$best" ] || [ "$distance" -lt "$best" ]; then
        best=$distance
        upstream_tag=$name
    fi
done

pep440='^v?[0-9]+(\.[0-9]+)*((a|b|rc)[0-9]+)?(\.post[0-9]+)?(\.dev[0-9]+)?(\+[a-z0-9]+(\.[a-z0-9]+)*)?$'
if [ -n "${OPENVIKING_VERSION:-}" ]; then
    printf '%s\n' "$OPENVIKING_VERSION" | grep -Eq "$pep440" ||
        die "OPENVIKING_VERSION '$OPENVIKING_VERSION' is not a normalized PEP 440 version"
    UPSTREAM_VERSION=${OPENVIKING_VERSION#v}
    UPSTREAM_VERSION=${UPSTREAM_VERSION%%+*}
else
    # A branch without upstream history (portable) has no ancestor tag:
    # take the tag line of scripts/upstream-base.
    if [ -z "$upstream_tag" ]; then
        if [ -f scripts/upstream-base ]; then
            upstream_tag=$(awk -F '\t' '$1 == "tag" { print $2; exit }' scripts/upstream-base)
        fi
        printf '%s\n' "$upstream_tag" | grep -Eq '^v[0-9]+(\.[0-9]+)*$' ||
            die "no upstream tag v* is an ancestor of HEAD and scripts/upstream-base has no valid tag line; set OPENVIKING_VERSION"
        printf 'build: upstream version %s from scripts/upstream-base (no upstream tag in the history)\n' "$upstream_tag" >&2
    fi
    UPSTREAM_VERSION=${upstream_tag#v}
    # The upstream release part stays as tagged; the portable version goes
    # into the PEP 440 local label, with '-' normalized to '.'.
    OPENVIKING_VERSION=$UPSTREAM_VERSION+p$(printf '%s' "$PORTABLE_VERSION" | tr 'A-Z-' 'a-z.')
fi

RELEASE_OCI=$oci
if [ "$push" -eq 1 ]; then
    RELEASE_PUSH=true
else
    RELEASE_PUSH=false
fi
export REVISION SOURCE_DATE_EPOCH PORTABLE_VERSION UPSTREAM_VERSION OPENVIKING_VERSION RELEASE_OCI RELEASE_PUSH

printf 'openviking build: target=%s version=%s label=%s-p%s revision=%s epoch=%s\n' \
    "$target" "$OPENVIKING_VERSION" "$UPSTREAM_VERSION" "$PORTABLE_VERSION" "$REVISION" "$SOURCE_DATE_EPOCH" >&2

case $BUILD_ENGINE in
    docker) ;;
    podman)
        case $target in
            test | release)
                die "$target needs BuildKit (docker buildx bake); use the default BUILD_ENGINE=docker"
                ;;
        esac
        GATEWAY_IMAGE=${GATEWAY_IMAGE-openviking:local}

        bake_default() {
            awk -v v="variable \"$1\" {" '
                index($0, v) == 1 { found = 1; next }
                found && $1 == "default" { gsub(/^[^\"]*\"|\"[^\"]*$/, ""); print; exit }' docker-bake.hcl
        }

        podman_build() {
            # GNU date uses -d; BSD date uses -r for seconds since the epoch.
            created=$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
                created=$(date -u -r "$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ||
                die "cannot format SOURCE_DATE_EPOCH '$SOURCE_DATE_EPOCH' with GNU or BSD date"
            podman build -f Dockerfile \
                --build-arg "OPENVIKING_VERSION=$OPENVIKING_VERSION" \
                --build-arg "UV_LOCK_STRATEGY=${UV_LOCK_STRATEGY-locked}" \
                --build-arg "REGISTRY_PREFIX=${REGISTRY_PREFIX-}" \
                --build-arg "RUST_IMAGE=${RUST_IMAGE-$(bake_default RUST_IMAGE)}" \
                --build-arg "RUST_DIGEST=${RUST_DIGEST-$(bake_default RUST_DIGEST)}" \
                --build-arg "NODE_IMAGE=${NODE_IMAGE-$(bake_default NODE_IMAGE)}" \
                --build-arg "NODE_DIGEST=${NODE_DIGEST-$(bake_default NODE_DIGEST)}" \
                --build-arg "PYTHON_IMAGE=${PYTHON_IMAGE-$(bake_default PYTHON_IMAGE)}" \
                --build-arg "PYTHON_DIGEST=${PYTHON_DIGEST-$(bake_default PYTHON_DIGEST)}" \
                --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
                --label "org.opencontainers.image.source=${SOURCE_URL-https://github.com/volcengine/OpenViking}" \
                --label "org.opencontainers.image.revision=$REVISION" \
                --label "org.opencontainers.image.version=$UPSTREAM_VERSION-p$PORTABLE_VERSION" \
                --label "org.opencontainers.image.created=$created" \
                --label 'org.opencontainers.image.title=OpenViking' \
                --label 'org.opencontainers.image.licenses=AGPL-3.0' \
                -t "$GATEWAY_IMAGE" .
        }

        if [ "$target" = gateway ] || ! podman image exists "$GATEWAY_IMAGE"; then
            podman_build
        fi
        podman run --rm --network none "$GATEWAY_IMAGE" python -I -c "import openviking; print('openviking', openviking.__version__)"
        podman run --rm --network none "$GATEWAY_IMAGE" sh -c 'command -v ov openviking-server openviking-entrypoint'
        exit 0
        ;;
    *) die "BUILD_ENGINE must be docker or podman" ;;
esac

bake() {
    docker buildx bake -f docker-bake.hcl "$@"
}

case $target in
    smoke) bake smoke ;;
    gateway) bake smoke && bake gateway ;;
    test) bake test ;;
    release)
        if [ -n "$oci" ]; then
            # Bake asks for an entitlement to write outside the working directory.
            bake smoke && bake --allow "fs.write=$(dirname -- "$oci")" release
        else
            bake smoke && bake release
        fi
        ;;
esac
