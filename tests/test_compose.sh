#!/bin/sh
# Start compose.yaml with a built image in a temporary copy and check it.
# See docs/operations.md.
#
# Usage: tests/test_compose.sh
#
# The test copies compose.yaml and scripts/verify.py to a new directory,
# writes a placeholder .env (random root API key, a free loopback port) and
# an empty data/ with examples/ov.conf.quickstart (unreachable embedding and
# VLM endpoints), and starts the service under its own Compose project name. It
# never uses this checkout's .env or data/, port 1933 or the project name
# openviking. It runs `up -d` without --build and fails when Compose pulls.
#
# Environment:
#   OPENVIKING_IMAGE        image to start; must exist locally (default openviking:local)
#   COMPOSE_TEST_PROJECT    Compose project name (default openviking-compose-test)
#   COMPOSE_TEST_DIR        new or empty directory for the copy (default: mktemp -d)
#   HEALTH_TIMEOUT          seconds to wait for a healthy container (default 240)

set -eu

[ $# -eq 0 ] || {
    printf 'usage: %s\n' "$0" >&2
    exit 2
}

image=${OPENVIKING_IMAGE:-openviking:local}
project=${COMPOSE_TEST_PROJECT:-openviking-compose-test}
health_timeout=${HEALTH_TIMEOUT:-240}
source_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
failures=0
dir=
started=0

ok() { printf 'ok - %s\n' "$*"; }
not_ok() {
    printf 'not ok - %s\n' "$*"
    failures=$((failures + 1))
}
die() {
    printf 'error: %s\n' "$*" >&2
    exit 2
}

case $project in
    openviking) die "COMPOSE_TEST_PROJECT must not be openviking, the project name of a live stack" ;;
    '' | *[!a-z0-9_-]*) die "COMPOSE_TEST_PROJECT '$project' is not a valid project name" ;;
esac
docker image inspect "$image" >/dev/null 2>&1 ||
    die "image $image not found locally; build it with: sh scripts/build.sh gateway"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

# Compose must read only the files of the copy and the variables below.
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_PROFILES COMPOSE_ENV_FILES \
    OPENVIKING_ROOT_API_KEY OPENVIKING_PUBLIC_BASE_URL OPENVIKING_BIND OPENVIKING_PORT

compose() {
    docker compose -p "$project" "$@"
}

cleanup() {
    status=$?
    if [ "$started" -eq 1 ]; then
        if [ "$failures" -ne 0 ] || [ "$status" -ne 0 ]; then
            (cd "$dir" && compose logs --tail 40) 2>&1 | sed 's/^/# log: /' || true
        fi
        (cd "$dir" && compose down -v --remove-orphans) >/dev/null 2>&1 || true
    fi
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        # Files that the container wrote belong to its user; remove them
        # from inside a container when the host user cannot.
        rm -rf "$dir" 2>/dev/null ||
            docker run --rm --network none -v "$dir:/copy" --entrypoint sh "$image" \
                -c 'rm -rf /copy/* /copy/.[!.]*' >/dev/null 2>&1 || true
        rm -rf "$dir" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if [ -n "${COMPOSE_TEST_DIR:-}" ]; then
    [ ! -e "$COMPOSE_TEST_DIR" ] || [ -z "$(ls -A "$COMPOSE_TEST_DIR")" ] ||
        die "COMPOSE_TEST_DIR $COMPOSE_TEST_DIR is not empty"
    mkdir -p "$COMPOSE_TEST_DIR"
    dir=$(CDPATH='' cd -- "$COMPOSE_TEST_DIR" && pwd)
else
    dir=$(mktemp -d "${TMPDIR:-/tmp}/openviking-compose-test.XXXXXX")
fi
[ "$dir" != "$source_dir" ] || die "the copy must not be the source tree"

mkdir -p "$dir/scripts" "$dir/data"
cp "$source_dir/compose.yaml" "$dir/compose.yaml"
cp "$source_dir/scripts/verify.py" "$dir/scripts/verify.py"
chmod 755 "$dir/data"

port=$(python3 -c '
import socket
while True:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    if port != 1933:
        print(port)
        break
')
root_key=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')

cat >"$dir/.env" <<EOF
OPENVIKING_ROOT_API_KEY=$root_key
OPENVIKING_IMAGE=$image
OPENVIKING_BIND=127.0.0.1
OPENVIKING_PORT=$port
OPENVIKING_PUBLIC_BASE_URL=http://127.0.0.1:$port
EOF
chmod 600 "$dir/.env"

# The quick start configuration of the README, with the random root key.
sed "s/REPLACE_WITH_OPENVIKING_ROOT_API_KEY/$root_key/" \
    "$source_dir/examples/ov.conf.quickstart" >"$dir/data/ov.conf"
grep -q "\"root_api_key\": \"$root_key\"" "$dir/data/ov.conf" ||
    die "examples/ov.conf.quickstart has no root_api_key placeholder"
chmod 644 "$dir/data/ov.conf"
cd "$dir"

# The rendered file holds the root key: read it with Python, never print it.
if compose config --quiet; then
    ok "docker compose config --quiet"
else
    not_ok "docker compose config --quiet failed"
    exit 1
fi
problems=$(compose config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
project, image = sys.argv[1], sys.argv[2]
problems = []
if config.get("name") != project:
    problems.append("project name %r" % config.get("name"))
for name, service in config.get("services", {}).items():
    if service.get("container_name") == "openviking":
        problems.append("service %s has container_name openviking" % name)
    if service.get("image") != image:
        problems.append("service %s image %r" % (name, service.get("image")))
    if service.get("pull_policy") != "never":
        problems.append("service %s pull_policy %r" % (name, service.get("pull_policy")))
    if "build" in service:
        problems.append("service %s has a build section" % name)
    for port in service.get("ports", []):
        if str(port.get("published")) == "1933" or port.get("host_ip") != "127.0.0.1":
            problems.append("service %s publishes %s:%s" % (name, port.get("host_ip"), port.get("published")))
    for volume in service.get("volumes", []):
        if volume.get("type") == "bind" and not volume.get("source", "").startswith(sys.argv[3] + "/"):
            problems.append("service %s binds %s" % (name, volume.get("source")))
for name, network in config.get("networks", {}).items():
    if network.get("external"):
        problems.append("network %s is external" % name)
print("; ".join(problems))
' "$project" "$image" "$dir")
if [ -z "$problems" ]; then
    ok "rendered config: project $project, image $image, pull_policy never, loopback port $port, no container_name openviking, no external network"
else
    not_ok "rendered config: $problems"
    exit 1
fi

started=1
if output=$(compose up -d 2>&1); then
    up_status=0
else
    up_status=$?
fi
printf '%s\n' "$output" | sed 's/^/# up: /'
if printf '%s\n' "$output" | grep -Eqi 'pull'; then
    not_ok "docker compose up tried to pull an image"
    exit 1
fi
if [ "$up_status" -eq 0 ]; then
    ok "docker compose up -d without --build, no pull"
else
    not_ok "docker compose up -d exited $up_status"
    exit 1
fi

container=$(compose ps -q openviking)
[ -n "$container" ] || {
    not_ok "no container for the service openviking"
    exit 1
}

waited=0
while :; do
    health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null || echo gone)
    case $health in
        healthy) break ;;
        unhealthy | none | gone)
            not_ok "container health is $health"
            exit 1
            ;;
    esac
    if [ "$waited" -ge "$health_timeout" ]; then
        not_ok "container not healthy after ${health_timeout}s (status $health)"
        exit 1
    fi
    sleep 5
    waited=$((waited + 5))
done
ok "container health check is healthy after about ${waited}s"

if verify=$(compose exec -T openviking python3 - "http://127.0.0.1:1933" --timeout 60 < scripts/verify.py); then
    verify_status=0
else
    verify_status=$?
fi
printf '%s\n' "$verify" | sed 's/^/# verify: /'
if [ "$verify_status" -eq 0 ]; then
    ok "scripts/verify.py in the service container passes"
else
    not_ok "scripts/verify.py in the service container exits $verify_status"
fi

name=$(docker inspect --format '{{.Name}}' "$container")
if [ "$name" = "/$project-openviking-1" ]; then
    ok "container name is the generated name $project-openviking-1"
else
    not_ok "container name '$name', expected /$project-openviking-1"
fi
networks=$(docker inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}' "$container")
if [ "$networks" = "${project}_default " ]; then
    ok "container joins only the network ${project}_default"
else
    not_ok "container networks '$networks', expected ${project}_default only"
fi
published=$(docker port "$container" 1933/tcp)
case $published in
    "127.0.0.1:$port") ok "port 1933 is published on 127.0.0.1:$port only" ;;
    *) not_ok "port 1933 is published on '$published', expected 127.0.0.1:$port" ;;
esac

if compose down -v --remove-orphans >/dev/null 2>&1; then
    started=0
    ok "docker compose down -v"
else
    not_ok "docker compose down -v failed"
fi
left=$(docker ps -aq --filter "label=com.docker.compose.project=$project")
left=$left$(docker network ls -q --filter "label=com.docker.compose.project=$project")
left=$left$(docker volume ls -q --filter "label=com.docker.compose.project=$project")
if [ -z "$left" ]; then
    ok "no container, network or volume of project $project remains"
else
    not_ok "objects of project $project remain after down"
fi

if [ "$failures" -eq 0 ]; then
    echo "all tests passed"
else
    printf '%s test(s) failed\n' "$failures"
    exit 1
fi
