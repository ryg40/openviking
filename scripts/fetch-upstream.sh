#!/bin/sh
# Fetch one upstream release tag into refs/upstream/tags/<tag>.
#
# By default the fetch has the full history of the tag: this repo is a source
# fork that merges upstream release tags, and a merge needs the ancestry.
# --shallow adds --depth 1 --filter=blob:none, for a clone that only compares
# files; the script refuses it unless the repo is already shallow or empty.
# Upstream tags never enter refs/tags/. See docs/remotes.md.
#
# Usage: scripts/fetch-upstream.sh [--shallow] <tag>
#   <tag>  v<digits>.<digits>.<digits>[suffix] or cli@<digits>.<digits>.<digits>
# Prints the commit ID of the tag.

set -eu

usage() {
    printf 'usage: %s [--shallow] v<major>.<minor>.<patch>[suffix] | cli@<major>.<minor>.<patch>\n' "$0" >&2
    exit 2
}

shallow=0
if [ $# -ge 1 ] && [ "$1" = --shallow ]; then
    shallow=1
    shift
fi
[ $# -eq 1 ] || usage
tag=$1

# v<digits>.<digits>.<digits>, then an optional suffix such as -rc.1 or .dev02
# that starts with '-', '.' or '+'. Or the upstream CLI form cli@<x>.<y>.<z>.
if ! printf '%s\n' "$tag" | grep -Eq '^(v[0-9]+\.[0-9]+\.[0-9]+([-.+][A-Za-z0-9][A-Za-z0-9.+-]*)?|cli@[0-9]+\.[0-9]+\.[0-9]+)$'; then
    printf "error: '%s' is not a release tag name (v<digits>.<digits>.<digits>[suffix] or cli@<digits>.<digits>.<digits>)\n" "$tag" >&2
    exit 2
fi
# grep tests each line on its own, so refuse white space (a newline) here.
case $tag in
    *..* | *. | *[[:space:]]*) printf "error: '%s' is not a valid tag name\n" "$tag" >&2; exit 2 ;;
esac

script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
sh "$script_dir/setup-remotes.sh" --check >/dev/null || {
    printf "error: remote 'upstream' is not configured; run %s/setup-remotes.sh\n" "$script_dir" >&2
    exit 1
}

depth_args=
if [ "$shallow" -eq 1 ]; then
    # A --depth fetch writes .git/shallow and cuts the ancestry of the commits
    # that it marks, also of commits that local branches share with upstream.
    # Allow it only where no history can be cut: the repo is already shallow,
    # or it has no ref, no valid HEAD and no second worktree.
    if [ "$(git rev-parse --is-shallow-repository)" != true ]; then
        refs=$(git for-each-ref --count=1 --format='%(refname)')
        worktrees=$(git worktree list --porcelain | grep -c '^worktree ' || true)
        if [ -n "$refs" ] || git rev-parse --verify --quiet HEAD >/dev/null ||
            [ "$worktrees" -gt 1 ]; then
            echo "error: --shallow refused: this repo is not shallow and has commits." >&2
            echo "error: a --depth fetch would cut the history that a merge of upstream needs." >&2
            echo "error: run without --shallow, or use --shallow in a new empty clone. See docs/remotes.md." >&2
            exit 2
        fi
    fi
    depth_args='--depth 1 --filter=blob:none'
fi

ref=refs/upstream/tags/$tag
# depth_args is empty or two fixed words; word splitting is intended.
# shellcheck disable=SC2086
git fetch --quiet --no-tags $depth_args upstream "+refs/tags/$tag:$ref"
git rev-parse --verify --quiet "$ref^{commit}"
