# Host configuration

The tracked files hold no value of a particular host.
A new clone runs on any host with Docker Compose: a Linux server, a Mac or a CI system.
Each host keeps its own values in files that Git ignores.

## Host values and where they live

A host value is a value that is true on one host only.

| Host value | Location | Tracked |
| --- | --- | --- |
| Root API key | `.env` (`OPENVIKING_ROOT_API_KEY`) | No |
| Image reference, bind address, host port | `.env` (`OPENVIKING_IMAGE`, `OPENVIKING_BIND`, `OPENVIKING_PORT`) | No |
| Public base URL (public domain) | `.env` (`OPENVIKING_PUBLIC_BASE_URL`) or `.local/compose.host.yaml` | No |
| External ingress network, fixed container name | `.local/compose.host.yaml` | No |
| Private addresses, host names, model endpoints, provider keys | `data/ov.conf` | No |
| Record of the deployment (host, paths, image digest, history) | A file under `.local/` of the checkout that runs the service | No |

`.env.example` lists every variable that `compose.yaml` reads, with portable defaults.
`.local/`, `.env`, `.env.*` (except `.env.example`) and `data/` are in `.gitignore`.

## Portable default

`compose.yaml` defines one service, `openviking`, in the Compose project `openviking`.
It publishes port 1933 on `127.0.0.1` and keeps its state in `./data`.
It has no fixed container name and joins no external network.

The upstream `docker-compose.yml` also had a `caddy` service and a `version:` key.
This file drops both. To read the upstream file, run:

```sh
upstream=$(awk -F '\t' '$1 == "tag" { print $2 }' scripts/upstream-base)
git show "refs/upstream/tags/$upstream:docker-compose.yml"
```

## Host override

A host that needs an ingress network, a fixed container name or a public URL adds `.local/compose.host.yaml`.
The example uses placeholder values; put the real values in the host copy only.

```yaml
# .local/compose.host.yaml (not tracked)
services:
  openviking:
    container_name: openviking
    environment:
      OPENVIKING_PUBLIC_BASE_URL: https://openviking.example.com
    networks:
      - ingress

networks:
  ingress:
    external: true
```

Load the override through `.env` with this line:

```sh
COMPOSE_FILE=compose.yaml:.local/compose.host.yaml
```

`env_file: .env` also passes `COMPOSE_FILE` into the container environment.
The server does not read it.

## Check the configuration

Run this check after each change to `.env` or to the override:

```sh
docker compose config --quiet
```

It exits 0 when the files are valid and `OPENVIKING_ROOT_API_KEY` is set.
With an empty key, it fails with the message `is empty; see .env.example`.

Warning: do not print the full `docker compose config` output of a live host. It contains the root API key.

## Live data

Warning: `docker compose up` in a checkout that holds the live `data/` replaces the live container.
The project name is `openviking` in every checkout, so Compose treats the new service as the live one.
Use a separate copy with its own `data/` and a different project name (`docker compose -p <name>`) for tests.
