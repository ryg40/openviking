#!/bin/sh
# Start a built OpenViking image offline and check it. See docs/image.md.
#
# Usage: tests/test_image.sh IMAGE
#
# The container gets --network none, a temporary state directory on
# /app/.openviking, a random root API key and a placeholder ov.conf with
# unreachable embedding and VLM endpoints. No host port is published: the API
# calls run with Python inside the container through `docker exec`.
#
# Environment:
#   TEST_NAME_PREFIX  container name prefix (default openviking-image-test)
#   EXPECTED_VERSION  exact version that /health must report (optional)
#   EXPECTED_USER     runtime user that docs/image.md states (default root)
#   HEALTH_TIMEOUT    seconds to wait for the first healthy answer (default 240)

set -eu

[ $# -eq 1 ] || {
    printf 'usage: %s IMAGE\n' "$0" >&2
    exit 2
}
image=$1
prefix=${TEST_NAME_PREFIX:-openviking-image-test}
expected_user=${EXPECTED_USER:-root}
health_timeout=${HEALTH_TIMEOUT:-240}
name=$prefix-$$
failures=0
state=

ok() { printf 'ok - %s\n' "$*"; }
not_ok() {
    printf 'not ok - %s\n' "$*"
    failures=$((failures + 1))
}

cleanup() {
    status=$?
    if [ "$failures" -ne 0 ] || [ "$status" -ne 0 ]; then
        docker logs --tail 40 "$name" 2>&1 | sed 's/^/# log: /' || true
    fi
    docker rm -f "$name" >/dev/null 2>&1 || true
    if [ -n "$state" ] && [ -d "$state" ]; then
        # Files that the container wrote belong to its user; remove them
        # from inside a container when the host user cannot.
        rm -rf "$state" 2>/dev/null ||
            docker run --rm --network none -v "$state:/state" --entrypoint sh "$image" \
                -c 'rm -rf /state/* /state/.[!.]*' >/dev/null 2>&1 || true
        rm -rf "$state" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker image inspect "$image" >/dev/null 2>&1 || {
    printf 'error: image %s not found\n' "$image" >&2
    exit 2
}

# Checks on the image without a mount.
label() {
    docker image inspect --format "{{index .Config.Labels \"org.opencontainers.image.$1\"}}" "$image"
}
missing=
for key in source revision version created base.name base.digest; do
    [ -n "$(label "$key")" ] || missing="$missing $key"
done
if [ -z "$missing" ]; then
    ok "OCI labels source, revision, version, created, base.name, base.digest are set"
else
    not_ok "OCI labels missing:$missing"
fi
label_version=$(label version)
case $label_version in
    *-p*) ok "version label has the form <upstream>-p<portable>: $label_version" ;;
    *) not_ok "version label '$label_version' lacks -p<portable>" ;;
esac
case $(label created) in
    [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9]T*Z) ok "created label is an RFC 3339 UTC time" ;;
    *) not_ok "created label '$(label created)' is not an RFC 3339 UTC time" ;;
esac
case $(label base.digest) in
    sha256:*) ok "base.digest label is a digest" ;;
    *) not_ok "base.digest label '$(label base.digest)' is not a digest" ;;
esac
host=$(hostname 2>/dev/null || true)
if [ -n "$host" ] && docker image inspect --format '{{json .Config.Labels}}' "$image" | grep -Fqi "$host"; then
    not_ok "a label contains the host name"
else
    ok "no label contains the host name"
fi

config_user=$(docker image inspect --format '{{.Config.User}}' "$image")
user_ok=0
case $expected_user in
    root) [ -z "$config_user" ] || [ "$config_user" = root ] || [ "$config_user" = 0 ] || user_ok=1 ;;
    *) [ "$config_user" = "$expected_user" ] || user_ok=1 ;;
esac
if [ "$user_ok" -eq 0 ]; then
    ok "image user is $expected_user (Config.User '$config_user')"
else
    not_ok "image user '$config_user', expected $expected_user"
fi

content=$(docker run --rm --network none --entrypoint sh "$image" -c 'ls -A /app/.openviking')
if [ -z "$content" ]; then
    ok "/app/.openviking is empty in the image"
else
    not_ok "/app/.openviking in the image holds: $content"
fi

found=$(docker run --rm --network none --entrypoint sh "$image" -c \
    'find / -xdev \( -name ov.conf -o -name ovcli.conf -o -name ovcli.settings.conf -o -name ".env" -o -name ".env.*" \) -print; ls -d /app/data /data 2>/dev/null' || true)
if [ -z "$found" ]; then
    ok "no ov.conf, ovcli.conf, .env or data/ in the image"
else
    not_ok "state or secret files in the image: $(printf '%s' "$found" | tr '\n' ' ')"
fi

# Start the server offline with a placeholder configuration.
state=$(mktemp -d "${TMPDIR:-/tmp}/openviking-image-test.XXXXXX")
chmod 755 "$state"
root_key=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
cat >"$state/ov.conf" <<EOF
{
  "server": {"host": "0.0.0.0", "port": 1933, "root_api_key": "$root_key"},
  "storage": {"workspace": "/app/.openviking/data"},
  "embedding": {
    "dense": {
      "provider": "openai",
      "api_key": "placeholder",
      "api_base": "http://127.0.0.1:9/v1",
      "model": "placeholder-embedding",
      "dimension": 1024
    }
  },
  "vlm": {
    "provider": "openai",
    "api_key": "placeholder",
    "api_base": "http://127.0.0.1:9/v1",
    "model": "placeholder-vlm"
  }
}
EOF
chmod 644 "$state/ov.conf"

docker run -d --rm --name "$name" --network none \
    -v "$state:/app/.openviking" "$image" >/dev/null

# GET a path on the server inside the container; print "<status> <body>".
call() {
    docker exec -e "OV_TEST_KEY=${2:-}" "$name" python -I -c '
import os, sys, urllib.error, urllib.request
request = urllib.request.Request("http://127.0.0.1:1933" + sys.argv[1])
if os.environ.get("OV_TEST_KEY"):
    request.add_header("X-API-Key", os.environ["OV_TEST_KEY"])
try:
    with urllib.request.urlopen(request, timeout=5) as response:
        print(response.status, response.read().decode())
except urllib.error.HTTPError as error:
    print(error.code, error.read().decode())
except OSError as error:
    print(0, error)
' "$1" 2>/dev/null || echo "0 exec failed"
}

healthy() {
    case $(call /health) in
        200\ *'"healthy":true'* | 200\ *'"healthy": true'*) return 0 ;;
    esac
    return 1
}

waited=0
until healthy; do
    if ! docker container inspect "$name" >/dev/null 2>&1; then
        not_ok "container exited before it became healthy"
        exit 1
    fi
    if [ "$waited" -ge "$health_timeout" ]; then
        not_ok "no healthy /health answer in ${health_timeout}s: $(call /health | cut -c1-200)"
        exit 1
    fi
    sleep 3
    waited=$((waited + 3))
done
ok "/health returns 200 with healthy true after about ${waited}s (not the 503 pending page)"

health=$(call /health)
version=$(printf '%s' "$health" | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p')
upstream=${label_version%%-p*}
if [ -n "${EXPECTED_VERSION:-}" ]; then
    if [ "$version" = "$EXPECTED_VERSION" ]; then
        ok "version $version"
    else
        not_ok "version '$version', expected $EXPECTED_VERSION"
    fi
fi
case $version in
    "$upstream" | "$upstream"+* | v"$upstream" | v"$upstream"+*)
        ok "version $version matches the label upstream version $upstream" ;;
    *) not_ok "version '$version' does not match the label upstream version $upstream" ;;
esac

run_user=$(docker exec "$name" id -un)
if [ "$run_user" = "$expected_user" ]; then
    ok "server process user is $run_user"
else
    not_ok "server process user '$run_user', expected $expected_user"
fi

status=$(call /api/v1/system/status | cut -d' ' -f1)
if [ "$status" = 401 ]; then
    ok "unauthenticated /api/v1/system/status gives 401"
else
    not_ok "unauthenticated /api/v1/system/status gives $status, expected 401"
fi
status=$(call /api/v1/system/status "$root_key" | cut -d' ' -f1)
if [ "$status" = 200 ]; then
    ok "/api/v1/system/status with the root key gives 200"
else
    not_ok "/api/v1/system/status with the root key gives $status, expected 200"
fi

stable=1
i=0
while [ "$i" -lt 6 ]; do
    sleep 5
    i=$((i + 1))
    healthy || {
        stable=0
        break
    }
done
if [ "$stable" -eq 1 ]; then
    ok "server stays healthy for 30s with unreachable model endpoints"
else
    not_ok "server became unhealthy within 30s: $(call /health | cut -c1-200)"
fi

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
else
    printf '%s test(s) failed\n' "$failures"
    exit 1
fi
