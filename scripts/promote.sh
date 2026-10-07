#!/bin/sh
# Copy local-dev to the portable chain. See docs/branches.md.
# No option: check and print a dry run, without writing an object or a ref.
set -eu
LC_ALL=C
export LC_ALL

usage() {
    echo 'usage: sh scripts/promote.sh [--version X.Y.Z [--root] | --tag portable-vX.Y.Z] [--push REMOTE [--dry-run] [--development-remote]] [--host-deny-required]' >&2
}
refuse() { echo "promote: refused: $*" >&2; exit 1; }
error() { echo "promote: error: $*" >&2; exit 2; }
version=
tag=
remote=
root=0
host_required=0
push_dry=0
development=0
while [ $# -gt 0 ]; do
    case $1 in
        --version|--tag|--push)
            [ $# -ge 2 ] || { usage; exit 2; }
            case $1 in
                --version) [ -z "$version" ] || error 'duplicate version'; version=$2 ;;
                --tag) [ -z "$tag" ] || error 'duplicate tag'; tag=$2 ;;
                --push) [ -z "$remote" ] || error 'duplicate remote'; remote=$2 ;;
            esac
            [ -n "$2" ] || error 'empty option value'
            shift 2 ;;
        --root) root=1; shift ;;
        --dry-run) push_dry=1; shift ;;
        --development-remote) development=1; shift ;;
        --host-deny-required) host_required=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage; exit 2 ;;
    esac
done
[ -z "$version" ] || [ -z "$tag" ] || error 'version and tag are mutually exclusive'
[ "$root" -eq 0 ] || [ -n "$version" ] || error 'root requires version'
[ -z "$tag" ] || [ -n "$remote" ] || error 'tag requires push'
[ -z "$remote" ] || [ -n "$version$tag" ] || error 'push requires version or tag'
[ "$push_dry" -eq 0 ] || [ -n "$remote" ] || error 'dry-run requires push'
[ "$push_dry" -eq 0 ] || [ -z "$version" ] || error 'dry-run requires an existing tag; create the local release separately'
[ "$development" -eq 0 ] || [ -n "$remote" ] || error 'development-remote requires push'
valid_version() {
    printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
}
[ -z "$version" ] || valid_version "$version" || error 'version must be canonical X.Y.Z'
if [ -n "$tag" ]; then
    case $tag in portable-v*) valid_version "${tag#portable-v}" || error 'invalid release tag' ;; *) error 'invalid release tag' ;; esac
fi
case $remote in -*|*[!A-Za-z0-9._-]*) error 'invalid remote name' ;; upstream) refuse 'upstream is fetch-only' ;; esac
command -v git >/dev/null 2>&1 || error 'Git is required'
top=$(git rev-parse --show-toplevel 2>/dev/null) || error 'not inside a Git working tree'
cd -- "$top"
[ "$(git rev-parse --is-shallow-repository)" = false ] || refuse 'shallow repository'
status=$(git status --porcelain --untracked-files=all) || error 'cannot read working tree status'
[ -z "$status" ] || refuse 'dirty working tree or index'
[ "$(git symbolic-ref -q HEAD || true)" != refs/heads/portable ] || refuse 'portable is checked out'
if git worktree list --porcelain | grep -qx 'branch refs/heads/portable'; then
    refuse 'portable is checked out in another worktree'
fi
[ -f scripts/scan.sh ] && [ -f scripts/public-check.sh ] || error 'required check commands are missing'
git symbolic-ref -q refs/heads/portable >/dev/null 2>&1 && refuse 'portable must not be a symbolic ref'
old=$(git rev-parse --verify --quiet refs/heads/portable || true)
rev=$(git rev-parse --verify --quiet 'refs/heads/local-dev^{commit}' || true)
# A portable-only clone may check or push a release, but cannot create one.
if [ -n "$version" ] && [ -z "$rev" ]; then refuse 'local-dev is absent'; fi

# Treat local and remote-tracking local-dev refs as retained private history.
# Also recognize a retained source commit named by the portable tip.
if [ -n "$(git for-each-ref --format='%(refname)' refs/heads/local-dev refs/remotes | grep -E '/local-dev$' || true)" ]; then
    host_required=1
elif [ -n "$old" ]; then
    source=$(git log -1 --format=%s "$old" | sed -n 's/^Promote local-dev \([0-9a-f]\{40\}\)$/\1/p')
    if [ -n "$source" ] && git cat-file -e "$source^{commit}" 2>/dev/null; then host_required=1; fi
fi
if [ "$host_required" -eq 1 ]; then
    [ -f .local/host-values.deny ] && [ ! -L .local/host-values.deny ] &&
        [ ! -L .local ] && [ -s .local/host-values.deny ] || refuse 'a nonempty regular .local/host-values.deny is required'
    # Comments and whitespace alone do not supply a host pattern.
    grep -Eq '^[[:space:]]*[^#[:space:]]' .local/host-values.deny || refuse 'the host deny list has no pattern'
fi
[ -n "$rev" ] || rev=$(git rev-parse --verify HEAD) || error 'no source commit'
source_tree=$(git rev-parse --verify "$rev^{tree}") || error 'cannot read source tree'
trees_differ=yes
if [ -n "$old" ]; then
    old_tree=$(git rev-parse --verify "$old^{tree}") || error 'cannot read portable tree'
    [ "$source_tree" != "$old_tree" ] || trees_differ=no
fi
if [ -n "$version" ] && [ "$root" -eq 0 ] && [ "$trees_differ" = no ]; then
    refuse 'nothing to promote; local-dev and portable have the same tree'
fi

if [ -n "$version" ]; then
    tag=portable-v$version
    git show-ref --verify --quiet "refs/tags/$tag" && refuse 'the release tag already exists'
    # Compare decimal components as strings; shell integers and awk numbers
    # can overflow or round large components.
    for previous in $(git for-each-ref --format='%(refname:strip=2)' 'refs/tags/portable-v*'); do
        valid_version "${previous#portable-v}" || refuse 'a local release tag has an invalid version'
        awk -v new="$version" -v old="${previous#portable-v}" 'BEGIN {
            split(new, n, "."); split(old, o, ".")
            for (i = 1; i <= 3; i++) {
                if (length(n[i]) != length(o[i])) exit !(length(n[i]) > length(o[i]))
                if ("x" n[i] != "x" o[i]) exit !("x" n[i] > "x" o[i])
            }
            exit 1
        }' || refuse 'version must exceed every local portable release tag'
    done
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/promote.XXXXXX") || error 'cannot create temporary directory'
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Do not print Git network output: it can echo a URL or a credential.
# Require one effective fetch URL and one identical effective push URL.
if [ -n "$remote" ]; then
    url=$(git remote get-url --all "$remote" 2>/dev/null) || refuse 'remote is absent'
    pushurl=$(git remote get-url --push --all "$remote" 2>/dev/null) || refuse 'push URL is absent'
    configured_url=$(git config --get-all "remote.$remote.url" 2>/dev/null) || refuse 'remote URL is absent'
    configured_pushurl=$(git config --get-all "remote.$remote.pushurl" 2>/dev/null || true)
    [ -n "$configured_pushurl" ] || configured_pushurl=$configured_url
    for value in "$configured_url" "$configured_pushurl" "$url" "$pushurl"; do
        case $value in
            DISABLED) refuse 'push URL is DISABLED' ;;
            ''|*@*|*'?'*|*'#'*|*[[:space:][:cntrl:]]*) refuse 'remote URL has user information, query data or whitespace' ;;
            *::*) refuse 'remote helpers are not supported' ;;
        esac
    done
    [ "$url" = "$pushurl" ] || refuse 'fetch and push URLs must match'
    mirror=$(git config --get "remote.$remote.mirror" 2>/dev/null || true)
    case $mirror in ''|false) ;; *) refuse 'mirror remote' ;; esac
    git ls-remote "$remote" >"$work/before" 2>"$work/network-error" || refuse 'cannot read target remote'
    if [ "$root" -eq 1 ] && grep -Eq '[[:space:]]refs/(heads/portable$|tags/portable-v)' "$work/before"; then
        refuse 'root requires a target without portable or portable release tags'
    fi
fi

run_check() {
    if sh "$@"; then return; else code=$?; fi
    echo 'promote: a required check failed; no release refs were changed' >&2
    case $code in 2) exit 2 ;; *) exit 1 ;; esac
}
SCAN_NAME_PREFIX=${SCAN_NAME_PREFIX:-openviking-promote-}
export SCAN_NAME_PREFIX
run_check scripts/scan.sh --level fail tree
run_check scripts/public-check.sh

new=
tag_object=
if [ -n "$tag" ] && [ -z "$version" ]; then
    tagref=refs/tags/$tag
    tag_object=$(git rev-parse --verify --quiet "$tagref") || refuse 'local release tag is absent'
    [ "$(git cat-file -t "$tag_object")" = tag ] || refuse 'release tag must be annotated'
    new=$(git rev-parse --verify "$tagref^{commit}" 2>/dev/null) || refuse 'release tag must name a commit'
    [ "$new" = "$old" ] || refuse 'release tag must name the current portable tip'
    if ! git cat-file -e "$new:scripts/public-rules.json" 2>/dev/null; then
        refuse 'existing tag has no public rules; create a new checked release instead; push refused'
    fi
    run_check scripts/public-check.sh --ref "$tag_object"
    if [ "$(git rev-list --parents -n 1 "$new")" = "$new" ]; then
        # A later push of a locally created root must obey the same boundary.
        # Annotated tags use their peeled commit; lightweight tags use their ID.
        awk -v new="$new" '
            { objects[$2] = $1 }
            END {
                for (ref in objects) {
                    if (ref == "refs/heads/portable" && objects[ref] != new) exit 1
                    if (ref ~ /^refs\/tags\/portable-v/ && ref !~ /\^\{\}$/) {
                        commit = ((ref "^{}") in objects) ? objects[ref "^{}"] : objects[ref]
                        if (commit != new) exit 1
                    }
                }
            }
        ' "$work/before" || refuse 'a root tag cannot replace a different published portable chain'
    fi
    SCAN_REF=refs/heads/portable SCAN_EXCLUDE_UPSTREAM=0
    export SCAN_REF SCAN_EXCLUDE_UPSTREAM
    run_check scripts/scan.sh --level fail history "$new"
elif [ -n "$version" ]; then
    # The source can differ from HEAD in a topic checkout. Check its exact tree.
    run_check scripts/public-check.sh --ref "$rev"
    GIT_AUTHOR_NAME='OpenViking portable' GIT_AUTHOR_EMAIL=portable@example.invalid
    GIT_COMMITTER_NAME='OpenViking portable' GIT_COMMITTER_EMAIL=portable@example.invalid
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    if [ "$root" -eq 0 ] && [ -n "$old" ]; then
        new=$(git commit-tree -p "$old" -m "Promote local-dev $rev" "$rev^{tree}") || error 'cannot create commit'
        range=$old..$new
    else
        new=$(git commit-tree -m "Promote local-dev $rev" "$rev^{tree}") || error 'cannot create root commit'
        range=$new
    fi
    SCAN_REF=refs/heads/portable SCAN_EXCLUDE_UPSTREAM=0
    export SCAN_REF SCAN_EXCLUDE_UPSTREAM
    run_check scripts/scan.sh --level fail history "$range"
    # Build the annotated object without creating its ref. Publish both local
    # refs in one compare-and-swap transaction after all checks pass.
    tag_object=$({
        printf 'object %s\ntype commit\ntag %s\n' "$new" "$tag"
        printf 'tagger %s\n\n' "$(git var GIT_COMMITTER_IDENT)"
        printf 'Portable release %s\n' "$version"
    } | git mktag) || error 'cannot create tag object'
    {
        if [ -n "$old" ]; then printf 'update refs/heads/portable %s %s\n' "$new" "$old"
        else printf 'create refs/heads/portable %s\n' "$new"; fi
        printf 'create refs/tags/%s %s\n' "$tag" "$tag_object"
    } | git update-ref --stdin >"$work/update" 2>&1 || refuse 'release refs changed concurrently or cannot be updated'
    printf 'promote: commit %s\n' "$new"
    git log -1 --format='author: %an <%ae>%ncommitter: %cn <%ce>' "$new"
    git for-each-ref --format='tagger: %(taggername) %(taggeremail)' "refs/tags/$tag"
else
    printf 'promote: dry run; no objects, refs or remotes changed\nsource commit: %s\nold portable: %s\n' "$rev" "${old:-absent}"
    printf 'trees differ: %s\nhost deny required: %s\n' "$trees_differ" "$host_required"
    echo 'commit author and committer: OpenViking portable <portable@example.invalid>'
    echo 'tagger: OpenViking portable <portable@example.invalid>'
    echo 'refs: refs/heads/portable and refs/tags/portable-vX.Y.Z'
    exit 0
fi

if [ -n "$remote" ]; then
    remote_old=$(awk '$2 == "refs/heads/portable" { print $1 }' "$work/before")
    printf 'promote: push plan\nremote: %s\nURL: %s\nold remote portable: %s\nnew portable: %s\n' "$remote" "$url" "${remote_old:-absent}" "$new"
    printf 'ref: %s:refs/heads/portable\nref: %s:refs/tags/%s\n' "$new" "$tag_object" "$tag"
    if [ "$development" -eq 1 ]; then echo 'audit mode: development'; else echo 'audit mode: release'; fi
    # Pin the checked source objects so a concurrent local ref update cannot
    # change the actual push. Config must not add other annotated tags.
    git -c push.followTags=false push --dry-run "$remote" \
        "$new:refs/heads/portable" "$tag_object:refs/tags/$tag" \
        >"$work/push-dry" 2>&1 || refuse 'push dry run failed; local release refs remain'
    echo 'promote: push dry run passed'
    [ "$push_dry" -eq 0 ] || exit 0
    git -c push.followTags=false push "$remote" \
        "$new:refs/heads/portable" "$tag_object:refs/tags/$tag" \
        >"$work/push" 2>&1 || refuse 'push failed; local release refs remain; inspect the remote before retry'
    git ls-remote "$remote" >"$work/after" 2>"$work/network-error" || refuse 'push completed, but remote audit failed'
    printf 'promote: git ls-remote %s\n' "$remote"
    # Pull refs are server state. Print their count, never their individual refs.
    awk -v development="$development" '
        $2 ~ /^refs\/pull\// { pulls++; next }
        $2 != "HEAD" && $2 != "refs/heads/portable" && $2 !~ /^refs\/tags\/portable-v/ {
            foreign++
            if (development) next
        }
        $2 == "HEAD" && development { next }
        { print }
        END {
            printf "server pull refs: %d\n", pulls
            if (development) printf "other refs: %d\n", foreign
            else printf "foreign refs: %d\n", foreign
            exit (!development && foreign > 0)
        }
    ' "$work/after" || refuse 'remote has foreign refs; nothing was deleted'
    # Development HEAD may name another branch; the release audit stays strict.
    if [ "$development" -eq 0 ]; then
        head=$(awk '$2 == "HEAD" { print $1 }' "$work/after")
        [ -z "$head" ] || [ "$head" = "$new" ] || refuse 'remote HEAD does not name portable; nothing was deleted'
    fi
fi
