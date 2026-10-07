#!/bin/sh
# Scan for secrets and host values before they go to a remote or into an image.
# See docs/secret-handling.md for the rules, the levels and the hooks.
#
# Usage: scripts/scan.sh [--level warn|fail] <mode> [<argument>]
#   tree               tracked files (working tree) and the staged content,
#                      the content of archives, the target text of symlinks
#                      and the names of the tracked files
#   staged             the staged changes and their file names (the hooks
#                      pre-commit and pre-merge-commit use this)
#   history [<range>]  the commits in <range> (git log syntax), their messages
#                      and the names of the files they change; the default
#                      range is HEAD without the commits of the upstream base
#   image <reference> [<base>]
#                      the file system of a local image; with <base>, only the
#                      layers that <reference> adds on top of the image <base>
#   all                tree and history (default range)
#   selftest           negative control: a synthetic token must give a finding
#   baseline           print scripts/upstream-base with new "hit" lines: the
#                      host-value hits of the tracked rules in the upstream
#                      base tree (needs the base commit)
#
# A secret finding always fails. A host-value finding (scripts/host-values.deny,
# the untracked .local/host-values.deny when it exists, scripts/host-values.regex)
# fails at level "fail" and only prints at level "warn". The default level is
# "fail" for the branch portable, for a tag portable-v* and for the mode image;
# "warn" otherwise.
# Upstream content (scripts/upstream-base names the upstream tag and its
# commit): a host-value finding of a tracked rule (scripts/host-values.deny,
# scripts/host-values.regex) in a file that is equal to the file of the
# upstream base commit is dropped. Without the base commit (a shallow clone),
# a finding is dropped when its path and the hash of its line are a "hit" line
# of scripts/upstream-base. A rule of .local/host-values.deny has no exception.
# Third-party content (mode image with <base>): a finding in a file of an
# add-on layer is dropped when the RECORD of a package of uv.lock or a dpkg
# md5sums list verifies the file (rules in filter_third_party below).
# A policy finding always fails (modes tree, staged, history, all): a tracked
# file named .gitleaksignore or .gitleaksbaseline, a tracked file in .local/,
# or a tracked archive, database dump or Git bundle, known by the extension or
# by the first bytes of the content (list in classify below). An upstream
# file with the exact blob and path of an "archive" line of
# scripts/upstream-base is accepted.
# Content does not switch the scan off: a "gitleaks:allow" comment does not
# hide a finding, and gitleaks reads no .gitleaksignore of the repository.
#
# Exit: 0 clean, 1 finding, 2 usage or tool error.
#
# Needs: a POSIX shell with od and readlink, Git 2.5 or later (tested with
# 2.39.5), and docker or the gitleaks binary.
#
# Environment:
#   GITLEAKS_IMAGE    replaces the pinned scanner image (for a mirror)
#   SCAN_ENGINE       auto (default), docker or binary
#   SCAN_REF          the ref that sets the default level, for example
#                     refs/tags/portable-v1 (default: the current branch and tags)
#   SCAN_NAME_PREFIX  name prefix of the helper containers (default scan-)
#   SCAN_IMAGE_METHOD mount (default): scan the whole image through a Docker mount;
#                     any other value selects docker export. A failed mount
#                     or the binary engine also uses export; no effect with a base.
#   SCAN_EXCLUDE_UPSTREAM
#                     1: history also excludes the commits of the upstream base
#                     from an explicit range (the hook pre-push sets it)

set -eu

GITLEAKS_VERSION=v8.30.1
GITLEAKS_IMAGE=${GITLEAKS_IMAGE:-zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f}
SCAN_ENGINE=${SCAN_ENGINE:-auto}
SCAN_NAME_PREFIX=${SCAN_NAME_PREFIX:-scan-}
# Paths of the deny lists, relative to the repository root. A deny list contains
# the patterns that it forbids, so host-value findings in these two files are
# dropped. The tracked list holds generic patterns only; the untracked local
# list holds the values of one host and is optional (a clone in the target environment has none).
DENY_REL=scripts/host-values.deny
LOCAL_DENY_REL=.local/host-values.deny
# Regular expressions for host values. The file contains no address, so it has
# no exception.
REGEX_REL=scripts/host-values.regex
# The upstream base of this source fork and the upstream files that the scan
# accepts (format in the file).
UPSTREAM_REL=scripts/upstream-base

script_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
base_config=$script_root/.gitleaks.toml
deny_file=$script_root/$DENY_REL
local_deny_file=$script_root/$LOCAL_DENY_REL
regex_file=$script_root/$REGEX_REL
upstream_file=$script_root/$UPSTREAM_REL

usage() {
    echo "usage: $0 [--level warn|fail] tree|staged|history [<range>]|image <reference> [<base>]|all|selftest|baseline" >&2
    exit 2
}
die() {
    echo "scan: error: $*" >&2
    exit 2
}

level=
while [ $# -gt 0 ]; do
    case $1 in
        --level) [ $# -ge 2 ] || usage; level=$2; shift 2 ;;
        --level=*) level=${1#--level=}; shift ;;
        -h|--help) usage ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || usage
mode=$1; shift
arg=
base=
case $mode in
    tree|staged|all|selftest|baseline) [ $# -eq 0 ] || usage ;;
    history) [ $# -le 1 ] || usage; arg=${1:-} ;;
    image) [ $# -ge 1 ] && [ $# -le 2 ] || usage; arg=$1; base=${2:-} ;;
    *) usage ;;
esac
case $level in
    ''|warn|fail) ;;
    *) usage ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/scan.XXXXXX")
# Docker Desktop and some CI systems share only resolved paths.
work=$(CDPATH='' cd -- "$work" && pwd -P)
export_cid=
cleanup() {
    if [ -n "$export_cid" ]; then docker rm -f "$export_cid" >/dev/null 2>&1 || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
# In sh, an INT or TERM handler does not end the script; exit runs the EXIT trap.
trap 'exit 130' INT TERM

# --- scanner engine ---------------------------------------------------------

engine=
select_engine() {
    case $SCAN_ENGINE in
        docker|auto)
            if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
                engine=docker
                docker image inspect "$GITLEAKS_IMAGE" >/dev/null 2>&1 ||
                    die "scanner image $GITLEAKS_IMAGE is not present; run: docker pull $GITLEAKS_IMAGE"
                return
            fi
            [ "$SCAN_ENGINE" = auto ] || die "docker is not available"
            ;;
        binary) ;;
        *) die "SCAN_ENGINE must be auto, docker or binary" ;;
    esac
    command -v gitleaks >/dev/null 2>&1 || die "no docker and no gitleaks binary"
    v=$(gitleaks version 2>/dev/null || true)
    [ "$v" = "$GITLEAKS_VERSION" ] || die "gitleaks binary is ${v:-unknown}, need $GITLEAKS_VERSION"
    engine=binary
}

run_count=0
# bind_mount <path>: a read-only --mount value for <path> at the same path.
# The value is CSV and each field is quoted, so a path may hold a blank, a
# comma or a colon.
bind_mount() {
    q=$(printf '%s' "$1" | sed 's/"/""/g')
    printf 'type=bind,"source=%s","target=%s",readonly' "$q" "$q"
}
# run_gitleaks <mounts> <gitleaks-argument>...
# <mounts>: none, repo (the repository) or image=<reference>. Paths are mounted
# read-only at the same path, so the arguments are the same for the container
# and for the binary. The report goes to stdout.
run_gitleaks() {
    mounts=$1; shift
    if [ "$engine" = binary ]; then
        gitleaks "$@"
        return
    fi
    run_count=$((run_count + 1))
    set -- "$GITLEAKS_IMAGE" "$@"
    case $mounts in
        repo)
            # The Git directory is inside the working tree or inside the common directory.
            case $common/ in
                "$repo_top"/*) ;;
                *) set -- --mount "$(bind_mount "$common")" "$@" ;;
            esac
            case $git_dir/ in
                "$repo_top"/*|"$common"/*) ;;
                *) set -- --mount "$(bind_mount "$git_dir")" "$@" ;;
            esac
            set -- --mount "$(bind_mount "$repo_top")" "$@"
            # The index file is inside the Git directory.
            if [ -n "${GIT_INDEX_FILE:-}" ]; then set -- -e GIT_INDEX_FILE "$@"; fi
            ;;
        image=*) set -- --mount "type=image,source=${mounts#image=},target=$image_root" "$@" ;;
    esac
    docker run --rm --network none --name "${SCAN_NAME_PREFIX}gitleaks-$$-$run_count" \
        --mount "$(bind_mount "$work")" \
        -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
        "$@"
}
# gl <mounts> <gitleaks-command> <argument>...: gitleaks with the common options.
# --ignore-gitleaks-allow: a "gitleaks:allow" comment does not hide a finding.
# --gitleaks-ignore-path: an empty directory, so that no .gitleaksignore of the
# current directory applies. gitleaks also reads <source>/.gitleaksignore; in
# git mode the source is the Git directory, not the working tree (see
# require_repo), and in dir mode it is a directory of this script.
gl() {
    m=$1 c=$2; shift 2
    run_gitleaks "$m" "$c" --no-banner --no-color --log-level error --redact --exit-code 0 \
        --ignore-gitleaks-allow --gitleaks-ignore-path "$work/no-ignore" \
        --config "$work/config.toml" --report-format template \
        --report-template "$work/report.tmpl" --report-path - "$@"
}

# --- configuration ------------------------------------------------------------

build_config() {
    [ -f "$base_config" ] || die "missing $base_config"
    [ -f "$deny_file" ] || die "missing $deny_file"
    [ -f "$regex_file" ] || die "missing $regex_file"
    read_upstream
    # The allowlists of .gitleaks.toml are for secrets. Limit each top-level
    # allowlist to the secret rules, so that no allowlist hides a host value.
    ! grep -q '^[[:space:]]*targetRules' "$base_config" ||
        die ".gitleaks.toml: do not set targetRules; scripts/scan.sh sets it"
    ids=$(awk '/^\[\[rules\]\]/ { r = 1; next } /^\[/ { r = 0 }
        r && /^id = / { sub(/^id = /, ""); printf "%s%s", sep, $0; sep = ", " }' "$base_config")
    [ -n "$ids" ] || die ".gitleaks.toml has no rule"
    awk -v ids="$ids" '{ print } /^\[\[allowlists\]\][[:space:]]*$/ { print "targetRules = [" ids "]" }' \
        "$base_config" >"$work/config.toml"
    : >"$work/patterns"
    # The rule ids: host-value-<n> for the tracked list, host-value-local-<n>
    # for the local list.
    add_deny "$deny_file" "$DENY_REL" host-value-
    if [ -f "$local_deny_file" ]; then
        add_deny "$local_deny_file" "$LOCAL_DENY_REL" host-value-local-
    fi
    printf '\n# Generated from %s\n' "$REGEX_REL" >>"$work/config.toml"
    # One line for each rule: <name> <sample> <regex> (see the file).
    : >"$work/samples"
    while read -r name sample re rest; do
        case $name in ''|'#'*) continue ;; esac
        [ -n "$re" ] && [ -z "$rest" ] || die "$REGEX_REL: rule $name needs three fields"
        case $name in *[!A-Za-z0-9-]*|local-*) die "$REGEX_REL: bad rule name $name" ;; esac
        case $re in *"'''"*) die "$REGEX_REL: the regex of $name contains three quotes" ;; esac
        printf 'host-value-%s\t%s (regex)\n' "$name" "$name" >>"$work/patterns"
        printf 'host-value-%s\t%s\n' "$name" "$(printf '%s' "$sample" | tr '_-' '.:')" >>"$work/samples"
        printf "\n[[rules]]\nid = \"host-value-%s\"\ndescription = \"host value: %s\"\nregex = '''%s'''\nsecretGroup = 1\n" \
            "$name" "$name" "$re" >>"$work/config.toml"
    done <"$regex_file"
    # The deny lists and the regex list together must give at least one rule.
    [ -s "$work/patterns" ] || die "no host-value rule in $DENY_REL, $LOCAL_DENY_REL and $REGEX_REL"
    # One line for each finding: rule, file, line, commit (tab separated).
    printf '%s\n' '{{- range . }}{{ .RuleID }}	{{ .File }}	{{ .StartLine }}	{{ .Commit }}{{ "\n" }}{{- end }}' \
        >"$work/report.tmpl"
    mkdir "$work/no-ignore"
}

# add_deny <file> <relative path> <rule id prefix>: one rule for each pattern.
add_deny() {
    printf '\n# Generated from %s\n' "$2" >>"$work/config.toml"
    n=0
    # Strip leading and trailing blanks; skip comments and empty lines.
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$1" >"$work/deny"
    while IFS= read -r p; do
        case $p in ''|'#'*) continue ;; esac
        case $p in *[\'\"\\]*) die "$2: a pattern contains a quote or a backslash" ;; esac
        n=$((n + 1))
        re=$(printf '%s\n' "$p" | sed 's/[].*^$+?(){}|[]/\\&/g')
        printf '%s%s\t%s\n' "$3" "$n" "$p" >>"$work/patterns"
        printf "\n[[rules]]\nid = \"%s%s\"\ndescription = \"host value: %s\"\nregex = '''(?i)%s'''\n" \
            "$3" "$n" "$p" "$re" >>"$work/config.toml"
    done <"$work/deny"
}

# read_upstream: the lines of scripts/upstream-base (tab separated):
#   tag <tag> <commit>      the upstream base: tag name and its commit
#   archive <blob> <path>   an upstream file that the policy check accepts
#   hit <line hash> <path>  a host-value hit in the base tree (scan.sh baseline)
base_tag=
base_commit=
read_upstream() {
    [ -f "$upstream_file" ] || die "missing $upstream_file"
    tab=$(printf '\t')
    awk -F '\t' -v OFS='\t' -v t="$work/upstream." '
        /^#/ || /^[[:space:]]*$/ { next }
        $1 == "tag" && NF == 3 && !tag++ { print $2, $3 > (t "tag"); next }
        $1 == "archive" && NF == 3 { print $2, $3 > (t "archive"); next }
        $1 == "hit" && NF == 3 { print $2, $3 > (t "hit"); next }
        { printf "bad line %d\n", NR > "/dev/stderr"; bad = 1 }
        END { exit bad }' "$upstream_file" || die "$UPSTREAM_REL: format error"
    touch "$work/upstream.tag" "$work/upstream.archive" "$work/upstream.hit"
    IFS=$tab read -r base_tag base_commit <"$work/upstream.tag" || true
    case $base_tag in ''|*[!A-Za-z0-9._@+-]*) die "$UPSTREAM_REL: no valid tag line" ;; esac
    case $base_commit in *[!0-9a-f]*) die "$UPSTREAM_REL: bad commit" ;; esac
    [ "${#base_commit}" -eq 40 ] || die "$UPSTREAM_REL: the commit needs 40 hex digits"
}

# --- repository helpers ---------------------------------------------------------

repo_top=
git_dir=
common=
image_root=/scan-image-root
require_repo() {
    [ -z "$repo_top" ] || return 0
    repo_top=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a Git working tree"
    repo_top=$(CDPATH='' cd -- "$repo_top" && pwd -P)
    # A hook gets the index of the commit in GIT_INDEX_FILE: a relative
    # ".git/index", or a temporary index for "git commit -a" and
    # "git commit <path>". Make it absolute before the cd below; run_gitleaks
    # passes it to the container.
    if [ -n "${GIT_INDEX_FILE:-}" ]; then
        case $GIT_INDEX_FILE in
            /*) ;;
            *) GIT_INDEX_FILE=$(pwd -P)/$GIT_INDEX_FILE ;;
        esac
        export GIT_INDEX_FILE
    fi
    # The Git commands below run at the top of the working tree. There a
    # relative --git-dir or --git-common-dir is relative to the current
    # directory in each Git version, so --path-format=absolute (Git 2.31) is
    # not needed.
    cd -- "$repo_top"
    common=$(git rev-parse --git-common-dir)
    common=$(CDPATH='' cd -- "$common" && pwd -P)
    # gitleaks git runs on the Git directory of this working tree (its HEAD
    # and index). A .gitleaksignore in the working tree then does not apply.
    git_dir=$(git rev-parse --git-dir)
    git_dir=$(CDPATH='' cd -- "$git_dir" && pwd -P)
}

# upstream_edited: 0 when scripts/upstream-base of the checkout that holds
# this script differs from its version in HEAD (in the working tree or in the
# index), or when HEAD has no such file. 1 when that checkout is not in a Git
# repository or has no HEAD (an empty repository): no committed version exists.
upstream_edited() {
    git -C "$script_root" rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1 || return 1
    git -C "$script_root" cat-file -e "HEAD:./$UPSTREAM_REL" 2>/dev/null || return 0
    ! git -C "$script_root" diff --quiet HEAD -- "$UPSTREAM_REL" 2>/dev/null
}

# have_base: the upstream base commit is in this repository (a full clone of
# local-dev has it; a shallow clone or an unrelated repository has not).
# A ref refs/upstream/tags/<tag> must point to the same commit. Without the
# ref, scripts/upstream-base must be the committed version.
have_base=
check_base() {
    [ -z "$have_base" ] || return 0
    have_base=no
    ref=refs/upstream/tags/$base_tag
    if r=$(git rev-parse -q --verify "$ref^{commit}" 2>/dev/null); then
        [ "$r" = "$base_commit" ] || die "$ref is $r, but $UPSTREAM_REL names $base_commit"
    elif upstream_edited; then
        die "$UPSTREAM_REL differs from HEAD and $ref does not exist; get the ref with: sh scripts/fetch-upstream.sh $base_tag"
    fi
    if git cat-file -e "$base_commit^{commit}" 2>/dev/null; then
        have_base=yes
        # <blob><TAB><path> for each file of the base tree
        git ls-tree -r -z --full-tree "$base_commit" | tr '\0' '\n' |
            awk -F '\t' '{ split($1, a, " "); if (a[2] == "blob") print a[3] "\t" $2 }' >"$work/base.blobs"
    fi
}

default_level() {
    [ "$mode" = image ] && { echo fail; return; }
    if [ -n "${SCAN_REF:-}" ]; then
        refs=$SCAN_REF
    else
        refs=$(git symbolic-ref -q --short HEAD 2>/dev/null || true)
        refs="$refs $(git tag --points-at HEAD 2>/dev/null | tr '\n' ' ')"
    fi
    for r in $refs; do
        case $r in
            portable|refs/heads/portable|portable-v*|refs/tags/portable-v*) echo fail; return ;;
        esac
    done
    echo warn
}

# --- scans --------------------------------------------------------------------
# Each scan appends "rule<TAB>file<TAB>line<TAB>commit" lines to $work/findings,
# with file relative to the scanned root.

# strip_prefix <prefix>: remove <prefix> from the file column.
strip_prefix() {
    awk -F '\t' -v OFS='\t' -v p="$1" 'index($2, p) == 1 { $2 = substr($2, length(p) + 1) } { print }'
}
# strip_archive: remove "<archive>!" from the file column.
strip_archive() {
    awk -F '\t' -v OFS='\t' '{ sub(/^[^!]*!/, "", $2); print }'
}
# map_meta: a finding in a helper file of a meta/ directory names the commit
# message or the file names, not the helper file. "(file names):N" is line N
# of the name list: git ls-files (tree), git diff --cached --name-only
# (staged), or the files that the commit changes (history).
map_meta() {
    awk -F '\t' -v OFS='\t' '
        $2 ~ /^meta\/msg-/ { $4 = substr($2, 10); $2 = "(commit message)" }
        $2 ~ /^meta\/names-/ { c = substr($2, 12); $2 = "(file names)"; $4 = (c ~ /^[0-9a-f]+$/) ? c : "" }
        { print }'
}

# join_hex: read "P<TAB><path>" lines, each followed by the od lines of its
# first bytes, and write "<path><TAB><TAB><hex>" lines for classify. One od
# for each file, no other process.
join_hex() {
    awk 'function out() { if (n) print p "\t\t" x }
        /^P\t/ { out(); n = 1; p = substr($0, 3); x = ""; next }
        { x = x " " $0 }
        END { out() }'
}

# classify: read "path<TAB>commit<TAB>hex" lines and write policy findings.
# Ignore files: .gitleaksignore, .gitleaksbaseline (any directory, any case).
# Local files: a path in the directory .local/ at the root. It holds the values
# of one host (.local/host-values.deny) and is not tracked.
# Extensions: zip jar war ear whl egg apk aab ipa nupkg tar tgz taz tbz tbz2
#   tb2 txz tlz tzst gz bz2 xz zst lz lz4 lzma lzo z 7z rar cab cpio ar deb rpm
#   iso dmg sql dump pgdump backup db sqlite sqlite3 db3 mdb accdb rdb bundle pack
# Content: gzip, compress, zip, bzip2, xz, zstd, 7z, rar, ar/deb, lz4, lzip,
#   rpm, cab, tar (ustar at byte 257), PostgreSQL custom dump (PGDMP), SQLite,
#   Git bundle v2 and v3, Git pack, Redis dump, and a text dump with the header
#   of pg_dump, mysqldump or mariadb-dump in the first 264 bytes.
classify() {
    awk -F '\t' -v OFS='\t' '
    function h(s,   r, i) { r = ""; for (i = 1; i < length(s); i += 2) r = r " " substr(s, i, 2); return r }
    BEGIN {
        n = split("1f8b 1f9d 504b0304 504b0506 504b0708 425a68 fd377a585a00 28b52ffd " \
            "377abcaf271c 526172211a07 213c617263683e0a 04224d18 4c5a4950 edabeedb " \
            "4d534346 5047444d50 53514c69746520666f726d6174203300 " \
            "23207632206769742062756e646c65 23207633206769742062756e646c65 " \
            "5041434b00000002 5041434b00000003 524544495330", m, " ")
        for (i = 1; i <= n; i++) magic[i] = h(m[i])
        tar = h("7573746172")
        k = split("506f737467726553514c2064617461626173652064756d70 4d7953514c2064756d70 " \
            "4d6172696144422064756d70", t, " ")
        for (i = 1; i <= k; i++) text[i] = h(t[i])
        ext = "\\.(zip|jar|war|ear|whl|egg|apk|aab|ipa|nupkg|tar|tgz|taz|tbz|tbz2|tb2|txz|tlz|tzst|" \
            "gz|bz2|xz|zst|lz|lz4|lzma|lzo|z|7z|rar|cab|cpio|ar|deb|rpm|iso|dmg|" \
            "sql|dump|pgdump|backup|db|sqlite|sqlite3|db3|mdb|accdb|rdb|bundle|pack)$"
    }
    {
        path = $1; name = path; sub(/.*\//, "", name); name = tolower(name)
        if (name == ".gitleaksignore" || name == ".gitleaksbaseline") {
            print "policy-ignore-file", path, "", $2
            next
        }
        if (index(path, ".local/") == 1) {
            print "policy-local-file", path, "", $2
            next
        }
        hit = (name ~ ext)
        x = " " $3
        gsub(/  +/, " ", x)
        for (i = 1; !hit && i <= n; i++) hit = (index(x, magic[i]) == 1)
        if (!hit) hit = (substr(x, 257 * 3 + 1, length(tar)) == tar)
        for (i = 1; !hit && i <= k; i++) hit = (index(x, text[i]) > 0)
        if (hit) print "policy-archive", path, "", $2
    }'
}

# classify_blobs <file>: <file> has "blob<TAB>path<TAB>commit" lines.
classify_blobs() {
    awk -F '\t' '!seen[$1]++ { print $1 }' "$1" | while IFS= read -r id; do
        printf 'P\t%s\n' "$id"
        git cat-file blob "$id" | od -An -tx1 -v -N 264
    done | join_hex >"$work/hex"
    awk -F '\t' -v OFS='\t' -v hexf="$work/hex" '
        BEGIN { while ((getline l < hexf) > 0) { split(l, a, "\t"); hex[a[1]] = a[3] } }
        { print $2, $3, hex[$1] }' "$1" | classify >>"$work/findings"
}

scan_tree() {
    require_repo
    rm -rf "$work/tree"
    mkdir -p "$work/tree/worktree" "$work/tree/index" "$work/tree/meta"
    # Tracked files as they are in the working tree (untracked and ignored files stay out).
    # shellcheck disable=SC2016 # the inner sh expands $f
    git ls-files -z | xargs -0 sh -c \
        'for f do { [ -e "$f" ] || [ -L "$f" ]; } && printf "%s\0" "$f"; done; :' sh |
        tar --null -T - -cf - | tar -xf - -C "$work/tree/worktree"
    # The staged content of each tracked file that differs from the working
    # tree, or that is not in the working tree. A file that is equal in both
    # has its one copy in worktree/.
    git diff --name-only -z | git checkout-index -q -z --stdin --prefix="$work/tree/index/"
    # gitleaks does not read a symlink. Replace each symlink with a file that
    # holds its target text, as the modes staged and history see it.
    find "$work/tree/worktree" "$work/tree/index" -type l | while IFS= read -r l; do
        t=$(readlink -- "$l")
        rm -f -- "$l"
        printf '%s\n' "$t" >"$l"
    done
    git ls-files -z | tr '\0' '\n' >"$work/tree/meta/names-tree"
    (cd "$work/tree" && find worktree index -type f) | while IFS= read -r f; do
        printf 'P\t%s\n' "${f#*/}"
        od -An -tx1 -v -N 264 <"$work/tree/$f"
    done | join_hex | classify >>"$work/findings"
    gl none dir --max-archive-depth 3 "$work/tree" >"$work/raw" || die "gitleaks failed"
    strip_prefix "$work/tree/" <"$work/raw" | strip_prefix worktree/ | strip_prefix index/ |
        map_meta | sort -u >>"$work/findings"
}

scan_staged() {
    require_repo
    # gitleaks --pre-commit runs its own "git diff --staged" and takes no Git
    # option; that diff shows no content of a file that Git treats as binary.
    # The dir scan below reads the staged blob of each such file.
    gl repo git --pre-commit --staged "$git_dir" >>"$work/findings" || die "gitleaks failed"
    # The policy check reads the files of the staged changes: each file of the
    # index that is new or changed against HEAD. The modes history and tree
    # check the files that are already in a commit.
    git diff --cached --name-only -z --no-renames --diff-filter=d | tr '\0' '\n' >"$work/changed"
    git ls-files -s -z | tr '\0' '\n' | awk -F '\t' -v OFS='\t' -v cf="$work/changed" '
        BEGIN { while ((getline l < cf) > 0) changed[l] = 1 }
        ($2 in changed) { split($1, a, " "); if (a[1] != "160000") print a[2], $2, "" }' >"$work/blobs"
    classify_blobs "$work/blobs"
    rm -rf "$work/staged"
    mkdir -p "$work/staged/meta" "$work/staged/files"
    git diff --cached --name-only -z | tr '\0' '\n' >"$work/staged/meta/names-staged"
    # The staged files that Git treats as binary ("-<TAB>-<TAB><path>" in
    # --numstat: a NUL byte, or the attribute -diff): their staged blob goes
    # to files/<path>.
    git diff --cached --numstat -z --no-renames --diff-filter=d |
        tr '\0' '\n' | awk '/^-\t-\t/ { print substr($0, 5) }' >"$work/binary"
    awk -F '\t' -v bf="$work/binary" 'BEGIN { while ((getline l < bf) > 0) bin[l] = 1 }
        ($2 in bin) { print $1 "\t" $2 }' "$work/blobs" | while IFS='	' read -r id path; do
        mkdir -p "$work/staged/files/$(dirname -- "$path")"
        git cat-file blob "$id" >"$work/staged/files/$path"
    done
    gl none dir "$work/staged" >"$work/raw" || die "gitleaks failed"
    strip_prefix "$work/staged/" <"$work/raw" | map_meta | strip_prefix files/ >>"$work/findings"
}

# scan_commits <range>: the messages, the file names and the new blobs of the
# commits in <range>. gitleaks reads neither messages nor names in git mode.
scan_commits() {
    rm -rf "$work/hist"
    mkdir -p "$work/hist/meta"
    # <range> is a list of git log arguments, for example "<sha> --not --remotes=origin".
    set -f
    # shellcheck disable=SC2086
    git rev-list $1 >"$work/commits" || die "git rev-list $1 failed"
    set +f
    : >"$work/blobs"
    while IFS= read -r c; do
        git log -1 --format=%B "$c" >"$work/hist/meta/msg-$c"
        # :<old mode> <new mode> <old blob> <new blob> <status><TAB><path>
        git -c core.quotePath=false diff-tree -r -m --root --no-commit-id --no-abbrev "$c" >"$work/diff"
        cut -f 2- "$work/diff" >"$work/hist/meta/names-$c"
        awk -F '\t' -v OFS='\t' -v c="$c" '{ split($1, a, " ") }
            a[5] != "D" && a[2] != "160000" { print a[4], $2, c }' "$work/diff" >>"$work/blobs"
    done <"$work/commits"
    classify_blobs "$work/blobs"
    gl none dir "$work/hist/meta" >"$work/raw" || die "gitleaks failed"
    strip_prefix "$work/hist/" <"$work/raw" | map_meta >>"$work/findings"
}

# scan_history [<range>]: without <range>, HEAD without the commits of the
# upstream base (all of HEAD when the base commit is not in the repository).
# SCAN_EXCLUDE_UPSTREAM=1 excludes them from an explicit <range> too.
scan_history() {
    require_repo
    check_base
    range=${1:-HEAD}
    if [ "$have_base" = yes ] && { [ -z "$1" ] || [ "${SCAN_EXCLUDE_UPSTREAM:-}" = 1 ]; }; then
        # First, so that a "--not" in <range> does not invert it.
        range="^$base_commit $range"
    fi
    set -f
    # shellcheck disable=SC2086 # <range> is a list of git log arguments
    n=$(git rev-list --count $range) || die "git rev-list $range failed"
    set +f
    echo "scan: history $range: $n commit(s)" >&2
    # --text: git log -p shows the content of a file that Git treats as binary
    # (a NUL byte, a PNG header), not "Binary files differ".
    gl repo git --log-opts="--text $range" "$git_dir" >>"$work/findings" || die "gitleaks failed"
    scan_commits "$range"
}

scan_image() {
    command -v docker >/dev/null 2>&1 || die "mode image needs docker"
    docker image inspect "$1" >/dev/null 2>&1 || die "image $1 is not present locally"
    if [ "$engine" = docker ] && [ "${SCAN_IMAGE_METHOD:-mount}" = mount ]; then
        # Docker 28 and later mount an image read-only, with no container of it.
        if gl "image=$1" dir "$image_root" >"$work/raw" 2>"$work/err"; then
            strip_prefix "$image_root/" <"$work/raw" >>"$work/findings"
            return
        fi
        echo "scan: image mount failed, using docker export" >&2
    fi
    export_cid=$(docker create --network none --name "${SCAN_NAME_PREFIX}export-$$" "$1" /scan-no-command) ||
        die "cannot create a container of $1"
    docker export -o "$work/rootfs.tar" "$export_cid"
    docker rm -f "$export_cid" >/dev/null
    export_cid=
    gl none dir --max-archive-depth 1 "$work/rootfs.tar" >"$work/raw" || die "gitleaks failed"
    strip_archive <"$work/raw" >>"$work/findings"
}

# The layers of <reference> after the layers of <base>. Each layer is a tar
# file; gitleaks reads it as an archive, so no file of the image is unpacked.
scan_layers() {
    command -v docker >/dev/null 2>&1 || die "mode image needs docker"
    for i in "$1" "$2"; do
        docker image inspect "$i" >/dev/null 2>&1 || die "image $i is not present locally"
    done
    fmt='{{range .RootFS.Layers}}{{println .}}{{end}}'
    docker image inspect -f "$fmt" "$1" | sed '/^$/d' >"$work/layers.image"
    docker image inspect -f "$fmt" "$2" | sed '/^$/d' >"$work/layers.base"
    nbase=$(wc -l <"$work/layers.base" | tr -d ' ')
    head -n "$nbase" "$work/layers.image" | cmp -s - "$work/layers.base" ||
        die "$2 is not a base image of $1"
    docker save -o "$work/image.tar" "$1"
    tar -xf "$work/image.tar" -C "$work" manifest.json
    # manifest.json: [{"Config":...,"Layers":["<path>",...],...}], in RootFS order.
    tr -d '\n' <"$work/manifest.json" | sed 's/.*"Layers":\[\([^]]*\)\].*/\1/' |
        tr ',' '\n' | tr -d '" ' | awk 'NF' >"$work/layer.paths"
    mkdir "$work/layers"
    # layer.list: the add-on layer files in RootFS order (filter_third_party).
    : >"$work/layer.list"
    base_image=$2
    n=0
    while IFS= read -r path; do
        n=$((n + 1))
        [ "$n" -gt "$nbase" ] || continue
        tar -xOf "$work/image.tar" "$path" >"$work/layers/layer-$n.tar"
        printf '%s\n' "$work/layers/layer-$n.tar" >>"$work/layer.list"
    done <"$work/layer.paths"
    rm -f "$work/image.tar"
    echo "scan: $((n - nbase)) add-on layer(s) of $n" >&2
    gl none dir --max-archive-depth 1 "$work/layers" >"$work/raw" || die "gitleaks failed"
    strip_archive <"$work/raw" >>"$work/findings"
}

# --- upstream content -------------------------------------------------------------

# copies <file> <commit>: the scanned content of <file>, one line for each copy:
#   f<TAB><path>    a copy of mode tree (worktree/ and, if it differs, index/)
#   o<TAB><object>  <commit>:<file> (history) or :<file> (staged)
copies() {
    if [ -n "$2" ]; then
        printf 'o\t%s:%s\n' "$2" "$1"
    elif [ "$mode" = staged ]; then
        printf 'o\t:%s\n' "$1"
    else
        for d in worktree index; do
            if [ -f "$work/tree/$d/$1" ]; then printf 'f\t%s\n' "$work/tree/$d/$1"; fi
        done
    fi
}
blob_id() {
    case $1 in
        f) git hash-object --no-filters -- "$2" </dev/null ;;
        o) git rev-parse -q --verify "$2" </dev/null ;;
    esac
}
cat_copy() {
    case $1 in
        f) cat -- "$2" ;;
        o) git cat-file blob "$2" </dev/null ;;
    esac
}
# line_hash <line>: the Git blob id of line <line> of stdin (with its newline).
line_hash() {
    sed -n "$1{p;q;}" | git hash-object --stdin
}

# accepted <rule> <file> <line> <commit>: 0 if each copy of <file> is upstream
# content for this finding.
accepted() {
    copies "$2" "$4" >"$work/copies"
    [ -s "$work/copies" ] || return 1
    while IFS='	' read -r kind loc; do
        id=$(blob_id "$kind" "$loc") || return 1
        case $1 in
            policy-archive)
                grep -qxF "$id	$2" "$work/upstream.archive" || return 1
                ;;
            *)
                if [ "$have_base" = yes ]; then
                    b=$(awk -F '\t' -v p="$2" '$2 == p { print $1; exit }' "$work/base.blobs")
                    [ -n "$b" ] && [ "$id" = "$b" ] || return 1
                else
                    [ -n "$3" ] || return 1
                    h=$(cat_copy "$kind" "$loc" | line_hash "$3")
                    grep -qxF "$h	$2" "$work/upstream.hit" || return 1
                fi
                ;;
        esac
    done <"$work/copies"
    return 0
}

# filter_upstream: drop the host-value findings of the tracked rules and the
# archive findings that accepted names upstream content. A rule of
# .local/host-values.deny (host-value-local-<n>) has no exception.
filter_upstream() {
    check_base
    awk -F '\t' -v OFS='\t' '
        ($1 ~ /^host-value-/ && $1 !~ /^host-value-local-/) || $1 == "policy-archive" {
            for (i = 1; i <= 4; i++) if ($i == "") $i = "-"
            print $1, $2, $3, $4
        }' "$work/findings" >"$work/cand"
    : >"$work/drop"
    while IFS='	' read -r rule file line commit; do
        [ "$line" != - ] || line=
        [ "$commit" != - ] || commit=
        if accepted "$rule" "$file" "$line" "$commit"; then
            printf '%s\t%s\t%s\t%s\n' "$rule" "$file" "$line" "$commit" >>"$work/drop"
        fi
    done <"$work/cand"
    dropped=$(wc -l <"$work/drop" | tr -d ' ')
    awk -v df="$work/drop" 'BEGIN { while ((getline l < df) > 0) d[l] = 1 } !($0 in d)' \
        "$work/findings" >"$work/findings.new"
    mv "$work/findings.new" "$work/findings"
}

# --- third-party content (mode image with <base>) ------------------------------
# A finding in an add-on layer is accepted when the file comes unchanged from a
# package that the build installed, and the package is not the project itself:
#   venv  <site-packages>/<name>-<version>.dist-info/RECORD lists the file with
#         its SHA-256, and uv.lock of this checkout has that package at that
#         version from a registry, git or url source. An editable, directory,
#         virtual or path source is the project or a local copy: no exception.
#   pyc   __pycache__/<module>.cpython-*.pyc has no hash in RECORD. It is
#         accepted when <module>.py next to __pycache__ is accepted, or when
#         <module>.py is in the base image and in no add-on layer (Python wrote
#         the cache when a build step ran it).
#   dpkg  /var/lib/dpkg/info/<package>.md5sums lists the file with its MD5.
#         Debian packages are not pinned, so this accepts what apt installed.
# Secret findings in such files are the test keys and examples of public
# packages. A rule of .local/host-values.deny has no exception. The check reads
# uv.lock of the checkout that holds this script: scan the image from the
# commit that built it.

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1"; else shasum -a 256 -- "$1"; fi |
        cut -d ' ' -f 1
}
md5_file() {
    if command -v md5sum >/dev/null 2>&1; then md5sum -- "$1" | cut -d ' ' -f 1; else md5 -q -- "$1"; fi
}
# pyc_source <path>: the source path of a __pycache__ file, or nothing.
pyc_source() {
    printf '%s\n' "$1" | awk -F / '
        NF >= 2 && $(NF - 1) == "__pycache__" && $NF ~ /^[^.]+\.cpython-[0-9]+(\.opt-[12])?\.pyc$/ {
            m = $NF; sub(/\..*/, "", m)
            s = ""; for (i = 1; i <= NF - 2; i++) s = s $i "/"
            print s m ".py"
        }'
}
# lock_packages <uv.lock>: "name==version" for each package from a registry,
# git or url source. Names in the form of a dist-info directory: lower case,
# "-" for each run of "-", "_" and ".".
lock_packages() {
    awk '
        function flush() { if (name != "" && ver != "" && ok) print name "==" ver }
        /^\[\[package\]\]/ { flush(); name = ""; ver = ""; ok = 0; next }
        /^\[/ { flush(); name = ""; next }
        /^name = "/ { name = $0; sub(/^name = "/, "", name); sub(/".*/, "", name)
            name = tolower(name); gsub(/[-_.]+/, "-", name); next }
        /^version = "/ { ver = $0; sub(/^version = "/, "", ver); sub(/".*/, "", ver); next }
        /^source = \{ *(registry|git|url) = / { ok = 1; next }
        END { flush() }' "$1"
}
# record_index <root>: "path<TAB>name==version<TAB>sha256 (hex)" for each
# hashed file of each RECORD under a site-packages directory of <root>. A
# RECORD path is relative to site-packages and may start with "../".
record_index() {
    find "$1" -path '*/site-packages/*.dist-info/RECORD' -type f | sort | while IFS= read -r rec; do
        di=${rec%/RECORD}
        dn=${di##*/}; dn=${dn%.dist-info}
        sp=${di%/*}; sp=${sp#"$1"/}
        awk -F , -v sp="$sp" -v name="${dn%%-*}" -v ver="${dn#*-}" '
            BEGIN {
                B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
                name = tolower(name); gsub(/[-_.]+/, "-", name); key = name "==" ver
            }
            function b64hex(s,   i, v, n, bits, out, x) {
                n = 0; bits = 0; out = ""
                for (i = 1; i <= length(s); i++) {
                    v = index(B64, substr(s, i, 1)) - 1
                    if (v < 0) continue
                    n = n * 64 + v; bits += 6
                    if (bits >= 8) { bits -= 8; x = int(n / 2 ^ bits); n -= x * 2 ^ bits; out = out sprintf("%02x", x) }
                }
                return out
            }
            function resolve(base, rel,   n, i, k, parts, stack, out) {
                n = split(base "/" rel, parts, "/"); k = 0
                for (i = 1; i <= n; i++) {
                    if (parts[i] == "" || parts[i] == ".") continue
                    if (parts[i] == "..") { if (k > 0) k--; continue }
                    stack[++k] = parts[i]
                }
                out = ""; for (i = 1; i <= k; i++) out = out (i > 1 ? "/" : "") stack[i]
                return out
            }
            $1 !~ /^"/ && $2 ~ /^sha256=/ { print resolve(sp, $1) "\t" key "\t" b64hex(substr($2, 8)) }' "$rec"
    done
}
# dpkg_index <root>: "path<TAB>package<TAB>md5" for each file of each md5sums
# list in var/lib/dpkg/info of <root>.
dpkg_index() {
    [ -d "$1/var/lib/dpkg/info" ] || return 0
    find "$1/var/lib/dpkg/info" -name '*.md5sums' -type f | sort | while IFS= read -r f; do
        p=${f##*/}; p=${p%.md5sums}
        awk -v pkg="$p" 'NF >= 2 { print substr($0, index($0, $2)) "\t" pkg "\t" $1 }' "$f"
    done
}
# base_members: the file list of the base image (made once, on first use).
base_members() {
    [ ! -f "$work/base.members" ] || return 0
    docker save -o "$work/base.tar" "$base_image"
    tar -xf "$work/base.tar" -C "$work" manifest.json
    tr -d '\n' <"$work/manifest.json" | sed 's/.*"Layers":\[\([^]]*\)\].*/\1/' |
        tr ',' '\n' | tr -d '" ' | awk 'NF' >"$work/base.paths"
    : >"$work/base.members"
    while IFS= read -r path; do
        tar -xOf "$work/base.tar" "$path" | tar -t | sed 's|^\./||' >>"$work/base.members"
    done <"$work/base.paths"
    rm -f "$work/base.tar"
}
# accepted_tp <path>: 0 if the file is third-party content (rules above).
# Prints the class: venv, pyc, dpkg or base.
accepted_tp() {
    e=$(awk -F '\t' -v p="$1" '$1 == p { print $2 "\t" $3; exit }' "$work/tp.records")
    if [ -n "$e" ]; then
        grep -qxF "${e%	*}" "$work/tp.lock" || return 1
        [ -f "$work/fs/$1" ] && [ "$(sha256_file "$work/fs/$1")" = "${e#*	}" ] || return 1
        echo venv
        return 0
    fi
    e=$(awk -F '\t' -v p="$1" '$1 == p { print $3; exit }' "$work/tp.dpkg")
    if [ -n "$e" ]; then
        [ -f "$work/fs/$1" ] && [ "$(md5_file "$work/fs/$1")" = "$e" ] || return 1
        echo dpkg
        return 0
    fi
    s=$(pyc_source "$1")
    [ -n "$s" ] || return 1
    if [ -f "$work/fs/$s" ]; then
        accepted_tp "$s" >/dev/null || return 1
        echo pyc
        return 0
    fi
    base_members
    grep -qxF "$s" "$work/base.members" || return 1
    echo base
}
# filter_third_party: drop the accepted findings of the add-on layers. Reads
# $work/layer.list (the layer files in order) and $base_image.
dropped_tp=0
tp_detail=
filter_third_party() {
    lock=${1:-$script_root/uv.lock}
    [ -f "$lock" ] || die "missing $lock"
    lock_packages "$lock" >"$work/tp.lock"
    awk -F '\t' '$1 !~ /^host-value-local-/' "$work/findings" | sort -u >"$work/tp.cand"
    [ -s "$work/tp.cand" ] || return 0
    # The files to read: each candidate, the source of each .pyc candidate,
    # each RECORD and each md5sums list.
    cut -f 2 "$work/tp.cand" | sort -u >"$work/tp.files"
    while IFS= read -r f; do pyc_source "$f"; done <"$work/tp.files" |
        sort -u "$work/tp.files" - >"$work/tp.want"
    rm -rf "$work/fs"
    mkdir "$work/fs"
    while IFS= read -r t; do
        tar -tf "$t" >"$work/tp.members"
        {
            grep -xF -f "$work/tp.want" "$work/tp.members" || true
            grep -E '(^|/)site-packages/[^/]+\.dist-info/RECORD$|^var/lib/dpkg/info/[^/]+\.md5sums$' \
                "$work/tp.members" || true
        } | sort -u >"$work/tp.take"
        [ -s "$work/tp.take" ] || continue
        tar -xf "$t" -C "$work/fs" -o -T "$work/tp.take" ||
            echo "scan: warning: cannot read every file of ${t##*/}" >&2
    done <"$work/layer.list"
    record_index "$work/fs" >"$work/tp.records"
    dpkg_index "$work/fs" >"$work/tp.dpkg"
    : >"$work/tp.drop"
    venv=0; pyc=0; dpkg=0; basen=0
    while IFS='	' read -r rule file line commit; do
        c=$(accepted_tp "$file") || continue
        printf '%s\t%s\t%s\t%s\n' "$rule" "$file" "$line" "$commit" >>"$work/tp.drop"
        case $c in venv) venv=$((venv + 1)) ;; pyc) pyc=$((pyc + 1)) ;; dpkg) dpkg=$((dpkg + 1)) ;; base) basen=$((basen + 1)) ;; esac
    done <"$work/tp.cand"
    dropped_tp=$(wc -l <"$work/tp.drop" | tr -d ' ')
    tp_detail="venv $venv, pyc $pyc, dpkg $dpkg, base image $basen"
    awk -v df="$work/tp.drop" 'BEGIN { while ((getline l < df) > 0) d[l] = 1 } !($0 in d)' \
        "$work/findings" >"$work/findings.new"
    mv "$work/findings.new" "$work/findings"
}

# make_baseline: print scripts/upstream-base with new "hit" lines. The hits
# are the findings of the tracked host-value rules in the tree of the base
# commit: the Git blob id of the line and the path. No rule of
# .local/host-values.deny goes into the file.
make_baseline() {
    require_repo
    check_base
    [ "$have_base" = yes ] ||
        die "the base commit $base_commit is not in this repository; run scripts/fetch-upstream.sh $base_tag"
    mkdir "$work/base"
    GIT_INDEX_FILE=$work/base.index git read-tree "$base_commit"
    GIT_INDEX_FILE=$work/base.index git checkout-index --all --prefix="$work/base/"
    find "$work/base" -type l | while IFS= read -r l; do
        t=$(readlink -- "$l")
        rm -f -- "$l"
        printf '%s\n' "$t" >"$l"
    done
    gl none dir "$work/base" >"$work/raw" || die "gitleaks failed"
    strip_prefix "$work/base/" <"$work/raw" |
        awk -F '\t' '$1 ~ /^host-value-/ && $1 !~ /^host-value-local-/ { print $3 "\t" $2 }' |
        sort -u >"$work/base.hits"
    : >"$work/hits"
    while IFS='	' read -r line file; do
        printf 'hit\t%s\t%s\n' "$(line_hash "$line" <"$work/base/$file")" "$file" >>"$work/hits"
    done <"$work/base.hits"
    grep -v '^hit	' "$upstream_file" || true
    sort -u "$work/hits"
    echo "scan: $(sort -u "$work/hits" | wc -l | tr -d ' ') hit line(s) for $base_tag ($base_commit)" >&2
}

selftest() {
    # The tokens are built at run time, so no tracked file contains them.
    mkdir -p "$work/selftest"
    tok=$(printf '%s%s%s%s' ghp _ Zx9QwEr7TyUi3OpA s5DfGh1JkLz2XcVbNm4Q)
    # Line 2: a token that contains "false" (the anchored allowlist of .gitleaks.toml).
    # Line 3: a "gitleaks:allow" comment does not hide a finding.
    tokf=$(printf '%s%s%s%s' ghp _ falseZx9QwEr7TyUi3O pAs5DfGh1JkLz2XcV)
    printf 'token = "%s"\ntoken = "%s"\ntoken = "%s" # gitleaks:%s\n' "$tok" "$tokf" "$tok" allow \
        >"$work/selftest/token.txt"
    # One line for each deny pattern and each regex sample; each must give a finding.
    { grep -v ' (regex)$' "$work/patterns" | cut -f 2; cut -f 2 "$work/samples"; } |
        sed 's/^/host = /' >"$work/selftest/host.txt"
    # No finding: version pins, loopback and documentation addresses.
    v=$(printf '%s.%s' 10 2.3.4)
    {
        printf 'nothing here\n'
        printf 'pin = "pkg==%s" "pkg>=%s" pkg-%s pkg:%s v%s %s.dev0\n' "$v" "$v" "$v" "$v" "$v" "$v"
        printf 'loopback = %s.0.0.1 ::1\n' 127
        printf 'docs = %s.0.2.10 %s.51.100.7 %s.0.113.9 %s:db8::1\n' 192 198 203 2001
    } >"$work/selftest/clean.txt"
    gl none dir "$work/selftest" >"$work/raw0" || die "gitleaks failed"
    strip_prefix "$work/selftest/" <"$work/raw0" >"$work/raw"
    ok=0
    for line in 1 2 3; do
        grep -q "^github-pat	token.txt	$line	" "$work/raw" ||
            { echo "selftest: FAIL - synthetic token on line $line not found" >&2; ok=1; }
    done
    while IFS='	' read -r id p; do
        grep -q "^$id	host.txt	" "$work/raw" || { echo "selftest: FAIL - host value $id ($p) not found" >&2; ok=1; }
    done <"$work/patterns"
    ! grep -q "	clean.txt	" "$work/raw" || { echo "selftest: FAIL - finding in a clean file" >&2; ok=1; }
    selftest_third_party "$tok" || ok=1
    [ "$ok" -eq 0 ] && echo "selftest: ok - the rules find the synthetic tokens and each host value"
    return "$ok"
}

# hex_b64url: the RECORD form of a SHA-256 hex digest on stdin.
hex_b64url() {
    awk 'BEGIN { B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_" }
        { n = 0; bits = 0; out = ""
          for (i = 1; i <= length($1); i++) {
              n = n * 16 + index("0123456789abcdef", substr($1, i, 1)) - 1; bits += 4
              if (bits >= 6) { bits -= 6; x = int(n / 2 ^ bits); n -= x * 2 ^ bits; out = out substr(B64, x + 1, 1) }
          }
          if (bits > 0) out = out substr(B64, n * 2 ^ (6 - bits) + 1, 1)
          print out }'
}
# selftest_third_party <token>: a synthetic add-on layer. The token in a file
# that RECORD or an md5sums list verifies is accepted; the token in a changed
# file, in a file of the project, or in a file of no package is a finding.
selftest_third_party() {
    s=$work/selftest/tp
    sp=$s/app/.venv/lib/python3.13/site-packages
    mkdir -p "$sp/acme/__pycache__" "$sp/acme-1.0.dist-info" "$sp/myproj/__pycache__" \
        "$sp/myproj-0.1.dist-info" "$s/var/lib/dpkg/info" "$s/usr/share/foo" \
        "$s/usr/local/lib/python3.13/__pycache__"
    for f in acme/keys.py acme/bad.py acme/__pycache__/keys.cpython-313.pyc \
        myproj/k.py myproj/__pycache__/k.cpython-313.pyc; do
        printf 'token = "%s"\n' "$1" >"$sp/$f"
    done
    printf 'token = "%s"\n' "$1" >"$s/usr/share/foo/k.txt"
    cp "$s/usr/share/foo/k.txt" "$s/usr/share/foo/other.txt"
    cp "$s/usr/share/foo/k.txt" "$s/usr/local/lib/python3.13/__pycache__/ipaddress.cpython-313.pyc"
    cp "$s/usr/share/foo/k.txt" "$s/usr/local/lib/python3.13/__pycache__/socket.cpython-313.pyc"
    h=$(sha256_file "$sp/acme/keys.py" | hex_b64url)
    printf 'acme/keys.py,sha256=%s,20\nacme/bad.py,sha256=%s,20\nacme/__pycache__/keys.cpython-313.pyc,,\n' \
        "$h" "$(printf 'acme/bad.py' | sha256_file /dev/stdin | hex_b64url)" >"$sp/acme-1.0.dist-info/RECORD"
    printf 'myproj/k.py,sha256=%s,20\n' "$h" >"$sp/myproj-0.1.dist-info/RECORD"
    printf '%s  usr/share/foo/k.txt\n' "$(md5_file "$s/usr/share/foo/k.txt")" >"$s/var/lib/dpkg/info/foo.md5sums"
    printf '[[package]]\nname = "acme"\nversion = "1.0"\nsource = { registry = "https://pypi.org/simple" }\n\n' >"$s/uv.lock"
    printf '[[package]]\nname = "myproj"\nversion = "0.1"\nsource = { editable = "." }\n' >>"$s/uv.lock"
    rm -rf "$work/layers"
    mkdir "$work/layers"
    tar -cf "$work/layers/layer-1.tar" -C "$s" app var usr
    printf '%s\n' "$work/layers/layer-1.tar" >"$work/layer.list"
    printf 'usr/local/lib/python3.13/ipaddress.py\n' >"$work/base.members"
    gl none dir --max-archive-depth 1 "$work/layers" >"$work/raw" || die "gitleaks failed"
    strip_archive <"$work/raw" >"$work/findings"
    filter_third_party "$s/uv.lock"
    ok=0
    for f in acme/keys.py acme/__pycache__/keys.cpython-313.pyc; do
        ! grep -q "	app/.venv/lib/python3.13/site-packages/$f	" "$work/findings" ||
            { echo "selftest: FAIL - third-party file $f not accepted" >&2; ok=1; }
    done
    ! grep -q "	usr/share/foo/k.txt	" "$work/findings" ||
        { echo "selftest: FAIL - dpkg file k.txt not accepted" >&2; ok=1; }
    ! grep -q "	usr/local/lib/python3.13/__pycache__/ipaddress.cpython-313.pyc	" "$work/findings" ||
        { echo "selftest: FAIL - base image cache file not accepted" >&2; ok=1; }
    for f in app/.venv/lib/python3.13/site-packages/acme/bad.py \
        app/.venv/lib/python3.13/site-packages/myproj/k.py \
        app/.venv/lib/python3.13/site-packages/myproj/__pycache__/k.cpython-313.pyc \
        usr/share/foo/other.txt usr/local/lib/python3.13/__pycache__/socket.cpython-313.pyc; do
        grep -q "	$f	" "$work/findings" || { echo "selftest: FAIL - $f accepted" >&2; ok=1; }
    done
    [ "$dropped_tp" -eq 4 ] || { echo "selftest: FAIL - $dropped_tp third-party findings accepted, not 4" >&2; ok=1; }
    return "$ok"
}

# --- main -----------------------------------------------------------------------

select_engine
build_config
: >"$work/findings"

if [ "$mode" = selftest ]; then
    selftest
    exit $?
fi
if [ "$mode" = baseline ]; then
    make_baseline
    exit 0
fi

[ -n "$level" ] || level=$(default_level)

case $mode in
    tree) scan_tree ;;
    staged) scan_staged ;;
    history) scan_history "$arg" ;;
    image) if [ -n "$base" ]; then scan_layers "$arg" "$base"; else scan_image "$arg"; fi ;;
    all) scan_tree; scan_history '' ;;
esac

dropped=0
if [ "$mode" != image ]; then filter_upstream; fi
if [ "$mode" = image ] && [ -n "$base" ]; then filter_third_party; fi

# Drop host-value findings in the two deny lists (repository modes only).
# Secret rules still scan these files, and no other file gets this exception.
# The local list is not tracked, so only a tracked copy can reach a scan, and
# a tracked file in .local/ is a policy finding.
if [ "$mode" = image ]; then
    cp "$work/findings" "$work/kept"
else
    awk -F '\t' -v f="$DENY_REL" -v l="$LOCAL_DENY_REL" \
        '!($1 ~ /^host-value-/ && ($2 == f || $2 == l))' "$work/findings" >"$work/kept"
fi
tab=$(printf '\t')
sort -t "$tab" -u -k2,2 -k3,3n -k1,1 -k4,4 "$work/kept" >"$work/sorted"

awk -F '\t' -v level="$level" -v pfile="$work/patterns" -v dropped="$dropped" \
    -v dropped_tp="$dropped_tp" -v tp_detail="$tp_detail" \
    -v base="$base_tag, $([ "$have_base" = yes ] && echo "base commit" || echo "baseline of $UPSTREAM_REL")" '
BEGIN {
    while ((getline l < pfile) > 0) { split(l, a, "\t"); pat[a[1]] = a[2] }
    pat["policy-ignore-file"] = "gitleaks ignore or baseline file"
    pat["policy-archive"] = "archive, database dump or Git bundle"
    pat["policy-local-file"] = "tracked file in .local/"
}
NF < 2 { next }
{
    where = ($3 != "") ? $2 ":" $3 : $2
    at = ($4 != "") ? "  commit " substr($4, 1, 12) : ""
    if ($1 ~ /^host-value-/) {
        hosts++
        printf "%s  host value  %s  rule %s (%s)%s\n", (level == "fail" ? "FAIL" : "warn"), where, $1, pat[$1], at
    } else if ($1 ~ /^policy-/) {
        policy++
        printf "FAIL  policy  %s  rule %s (%s)%s\n", where, $1, pat[$1], at
    } else {
        secrets++
        printf "FAIL  secret  %s  rule %s%s\n", where, $1, at
    }
}
END {
    printf "scan: %d secret finding(s), %d host-value finding(s), %d policy finding(s), level %s\n",
        secrets, hosts, policy, level
    if (dropped > 0) printf "scan: %d finding(s) in upstream content accepted (%s)\n", dropped, base
    if (dropped_tp > 0) printf "scan: %d finding(s) in third-party packages accepted (%s)\n", dropped_tp, tp_detail
    exit (secrets > 0 || policy > 0 || (hosts > 0 && level == "fail")) ? 1 : 0
}' "$work/sorted"
