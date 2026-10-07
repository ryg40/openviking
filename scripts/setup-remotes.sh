#!/bin/sh
# Create or convert the fetch-only remote "upstream" (volcengine/OpenViking)
# in this clone, and, with SHARED_URL, the remote "shared" that accepts only
# the branch portable and the tags portable-v*.
#
# A clone does not copy remote configuration, so run this once per clone.
# See docs/remotes.md for the reasons behind each setting.
#
# Usage: scripts/setup-remotes.sh [--check]
#   --check  change nothing; exit 0 if the configuration is correct,
#            exit 1 with a message for each wrong setting.
# Environment:
#   UPSTREAM_URL   replaces https://github.com/volcengine/OpenViking.git
#                  (for a mirror)
#   SHARED_URL     create or convert the remote "shared" with this URL
#                  (your release repository on the shared Git server)
#   SHARED_REMOTE  replaces the remote name "shared"
# Without SHARED_URL, an existing remote "shared" is checked, not changed;
# an absent one is reported and is not an error.

set -eu

UPSTREAM_URL=${UPSTREAM_URL:-https://github.com/volcengine/OpenViking.git}
PUSH_URL=DISABLED
TAG_OPT=--no-tags
# A wildcard refspec that matches no upstream ref: a plain "git fetch upstream"
# then transfers nothing. Use scripts/fetch-upstream.sh to fetch one tag.
FETCH_REFSPEC='+refs/upstream-none/*:refs/upstream/none/*'

SHARED_REMOTE=${SHARED_REMOTE:-shared}
SHARED_URL=${SHARED_URL:-}
# The shared remote gets the branch portable and the tags portable-v* only.
# A plain "git fetch" reads portable only, and a plain "git push" sends only
# these two refspecs. The hook pre-push refuses every other ref.
SHARED_FETCH='+refs/heads/portable:refs/remotes/'$SHARED_REMOTE'/portable'
SHARED_PUSH_BRANCH='refs/heads/portable:refs/heads/portable'
SHARED_PUSH_TAGS='refs/tags/portable-v*:refs/tags/portable-v*'

usage() {
    printf 'usage: %s [--check]\n' "$0" >&2
    exit 2
}

mode=setup
case $# in
    0) ;;
    1) [ "$1" = --check ] || usage; mode=check ;;
    *) usage ;;
esac

# The name goes into config keys and into a refspec.
case $SHARED_REMOTE in
    '' | -* | *[!A-Za-z0-9._-]* | origin | upstream | portable)
        printf "error: SHARED_REMOTE '%s' is not allowed (use letters, digits, '.', '_', '-'; not origin, upstream or portable)\n" "$SHARED_REMOTE" >&2
        exit 2
        ;;
esac

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "error: not inside a Git repository" >&2
    exit 2
}

# Print a URL (or a list of URLs) without user name, password or token.
# Remove everything from '://' to the last '@' before the next '/'. A password
# with a raw '/' ends that part too early, so if an '@' still follows '://',
# print '<url hidden>' in place of the URL. An scp-style URL (git@host:path)
# has no '://' and no secret, and stays as it is.
strip_credentials() {
    stripped=$(printf '%s\n' "$1" | sed 's#://[^/]*@#://#g')
    case $stripped in
        *://*@*) printf '%s\n' '<url hidden>' ;;
        *) printf '%s\n' "$stripped" ;;
    esac
}

# Print the values of a multi-value config key, or nothing.
config_all() {
    git config --get-all "$1" 2>/dev/null || true
}

# Print the values of a multi-value config key on one line, for messages.
config_line() {
    config_all "$1" | paste -s -d ' ' -
}

report_origin() {
    origin_url=$(git config --get remote.origin.url 2>/dev/null || true)
    if [ -n "$origin_url" ]; then
        printf 'origin: %s (not changed)\n' "$(strip_credentials "$origin_url")"
    else
        echo "warning: remote 'origin' is absent" >&2
    fi
}

check_upstream() {
    bad=0
    if ! git config --get remote.upstream.url >/dev/null 2>&1; then
        echo "check: remote 'upstream' is absent" >&2
        return 1
    fi
    url=$(config_all remote.upstream.url)
    [ "$url" = "$UPSTREAM_URL" ] || {
        printf "check: remote.upstream.url is '%s', expected '%s'\n" "$(strip_credentials "$(config_line remote.upstream.url)")" "$(strip_credentials "$UPSTREAM_URL")" >&2
        bad=1
    }
    pushurl=$(config_all remote.upstream.pushurl)
    [ "$pushurl" = "$PUSH_URL" ] || {
        printf "check: remote.upstream.pushurl is '%s', expected '%s'\n" "$(strip_credentials "$(config_line remote.upstream.pushurl)")" "$PUSH_URL" >&2
        bad=1
    }
    tagopt=$(config_all remote.upstream.tagOpt)
    [ "$tagopt" = "$TAG_OPT" ] || {
        printf "check: remote.upstream.tagOpt is '%s', expected '%s'\n" "$(config_line remote.upstream.tagOpt)" "$TAG_OPT" >&2
        bad=1
    }
    fetch=$(config_all remote.upstream.fetch)
    [ "$fetch" = "$FETCH_REFSPEC" ] || {
        printf "check: remote.upstream.fetch is '%s', expected '%s'\n" "$(config_line remote.upstream.fetch)" "$FETCH_REFSPEC" >&2
        bad=1
    }
    mirror=$(config_all remote.upstream.mirror)
    case $mirror in
        '' | false) ;;
        *)
            printf "check: remote.upstream.mirror is '%s', expected unset\n" "$(config_line remote.upstream.mirror)" >&2
            bad=1
            ;;
    esac
    return $bad
}

# Print 'yes' if the shared remote has any config key.
shared_exists() {
    re=$(printf '%s\n' "$SHARED_REMOTE" | sed 's/\./\\./g')
    if git config --get-regexp "^remote\.$re\." >/dev/null 2>&1; then echo yes; fi
}

# Compare one key of the shared remote with the expected values (one per line).
# Usage: check_shared_key <key> <expected> [url]  (url: strip credentials)
check_shared_key() {
    got=$(config_all "remote.$SHARED_REMOTE.$1")
    [ "$got" = "$2" ] && return 0
    if [ "${3:-}" = url ]; then
        printf "check: remote.%s.%s is '%s', expected '%s'\n" "$SHARED_REMOTE" "$1" "$(strip_credentials "$(config_line "remote.$SHARED_REMOTE.$1")")" "$(strip_credentials "$2")" >&2
    else
        printf "check: remote.%s.%s is '%s', expected '%s'\n" "$SHARED_REMOTE" "$1" "$(config_line "remote.$SHARED_REMOTE.$1")" "$(printf '%s\n' "$2" | paste -s -d ' ' -)" >&2
    fi
    return 1
}

check_shared() {
    bad=0
    if [ -n "$SHARED_URL" ]; then
        want_url=$SHARED_URL
    else
        # Without SHARED_URL the URL is not checked, but it must be one value.
        want_url=$(config_all "remote.$SHARED_REMOTE.url")
        case $want_url in
            '')
                printf "check: remote.%s.url is absent\n" "$SHARED_REMOTE" >&2
                return 1
                ;;
            *"$nl"*)
                printf "check: remote.%s.url has more than one value\n" "$SHARED_REMOTE" >&2
                return 1
                ;;
        esac
    fi
    check_shared_key url "$want_url" url || bad=1
    check_shared_key pushurl "$want_url" url || bad=1
    check_shared_key fetch "$SHARED_FETCH" || bad=1
    check_shared_key tagOpt "$TAG_OPT" || bad=1
    check_shared_key push "$SHARED_PUSH_BRANCH$nl$SHARED_PUSH_TAGS" || bad=1
    mirror=$(config_all "remote.$SHARED_REMOTE.mirror")
    case $mirror in
        '' | false) ;;
        *)
            printf "check: remote.%s.mirror is '%s', expected unset\n" "$SHARED_REMOTE" "$(config_line "remote.$SHARED_REMOTE.mirror")" >&2
            bad=1
            ;;
    esac
    return $bad
}

# Check the shared remote and print the result. Absent and no SHARED_URL: pass.
report_shared() {
    if [ -z "$(shared_exists)" ] && [ -z "$SHARED_URL" ]; then
        printf "%s: remote '%s' is absent (not configured; set SHARED_URL to create it)\n" "$SHARED_REMOTE" "$SHARED_REMOTE"
        return 0
    fi
    if [ -z "$(shared_exists)" ]; then
        printf "check: remote '%s' is absent\n" "$SHARED_REMOTE" >&2
        return 1
    fi
    if check_shared; then
        printf '%s: %s (push only portable and portable-v*, fetch portable, tagOpt %s)\n' "$SHARED_REMOTE" "$(strip_credentials "$(config_all "remote.$SHARED_REMOTE.url")")" "$TAG_OPT"
        return 0
    fi
    return 1
}

nl='
'

if [ "$mode" = check ]; then
    report_origin
    status=0
    if check_upstream; then
        echo "upstream: configuration is correct"
    else
        printf 'upstream: configuration is wrong; run %s to fix it\n' "$0" >&2
        status=1
    fi
    report_shared || {
        printf '%s: configuration is wrong; run SHARED_URL=<url> %s to fix it\n' "$SHARED_REMOTE" "$0" >&2
        status=1
    }
    exit "$status"
fi

changes=0

# Give a config key exactly one value. Touch the key only if it differs,
# so that a second run leaves the config file as it is.
# Usage: set_key <key> <value> [<value to print>]
set_key() {
    old=$(config_all "$1")
    [ "$old" = "$2" ] && return 0
    old_line=$(config_line "$1")
    git config --unset-all "$1" 2>/dev/null || true
    git config "$1" "$2"
    printf "changed %s: '%s' -> '%s'\n" "$1" "$(strip_credentials "$old_line")" "$(strip_credentials "${3:-$2}")"
    changes=$((changes + 1))
}

# Give a config key exactly these values, in this order. Touch the key only
# if it differs. Usage: set_values <key> <value>...
set_values() {
    key=$1
    shift
    old=$(config_all "$key")
    [ "$old" = "$(printf '%s\n' "$@")" ] && return 0
    old_line=$(config_line "$key")
    git config --unset-all "$key" 2>/dev/null || true
    for value in "$@"; do git config --add "$key" "$value"; done
    printf "changed %s: '%s' -> '%s'\n" "$key" "$old_line" "$*"
    changes=$((changes + 1))
}

# Remove a config key unless its value is unset or 'false'.
unset_key() {
    old=$(config_all "$1")
    case $old in '' | false) return 0 ;; esac
    old_line=$(config_line "$1")
    git config --unset-all "$1"
    printf "changed %s: '%s' -> (unset)\n" "$1" "$(strip_credentials "$old_line")"
    changes=$((changes + 1))
}

set_key remote.upstream.url "$UPSTREAM_URL"
set_key remote.upstream.pushurl "$PUSH_URL"
set_key remote.upstream.tagOpt "$TAG_OPT"
set_key remote.upstream.fetch "$FETCH_REFSPEC"
unset_key remote.upstream.mirror

[ "$changes" -eq 0 ] && echo "upstream: no change"

# Refs from an older configuration stay; docs/remotes.md gives the removal order.
old_remote_refs=$(git for-each-ref --format='%(refname)' refs/remotes/upstream | wc -l | tr -d ' ')
[ "$old_remote_refs" -eq 0 ] ||
    echo "note: $old_remote_refs ref(s) under refs/remotes/upstream/ are kept (not deleted); see docs/remotes.md"

report_origin
check_upstream
printf 'upstream: %s (fetch only, push %s, tagOpt %s)\n' "$(strip_credentials "$UPSTREAM_URL")" "$PUSH_URL" "$TAG_OPT"

if [ -n "$SHARED_URL" ]; then
    changes=0
    set_key "remote.$SHARED_REMOTE.url" "$SHARED_URL"
    set_key "remote.$SHARED_REMOTE.pushurl" "$SHARED_URL"
    set_values "remote.$SHARED_REMOTE.fetch" "$SHARED_FETCH"
    set_key "remote.$SHARED_REMOTE.tagOpt" "$TAG_OPT"
    set_values "remote.$SHARED_REMOTE.push" "$SHARED_PUSH_BRANCH" "$SHARED_PUSH_TAGS"
    unset_key "remote.$SHARED_REMOTE.mirror"
    [ "$changes" -eq 0 ] && echo "$SHARED_REMOTE: no change"
fi
report_shared || {
    printf '%s: configuration is wrong; run SHARED_URL=<url> %s to fix it\n' "$SHARED_REMOTE" "$0" >&2
    exit 1
}
