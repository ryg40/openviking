# syntax=docker/dockerfile:1.9@sha256:fe40cf4e92cd0c467be2cfc30657a680ae2398318afd50b0c80585784c604f28

# Base images, pinned by multi-platform index digest (docs/image.md).
# REGISTRY_PREFIX selects a mirror registry, for example "mirror.example/library/".
ARG REGISTRY_PREFIX=
# rust:1.91.1-trixie
ARG RUST_IMAGE=rust:1.91.1-trixie
ARG RUST_DIGEST=sha256:867f1d1162913c401378a8504fb17fe2032c760dc316448766f150a130204aad
# node:24-trixie-slim
ARG NODE_IMAGE=node:24-trixie-slim
ARG NODE_DIGEST=sha256:43b9ba1142b8dcf33fa8f922ca1be85714adc444e0586c7cf7726daaeabc1bea
# python:3.13-slim-trixie (Python build stage and runtime)
ARG PYTHON_IMAGE=python:3.13-slim-trixie
ARG PYTHON_DIGEST=sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962

# Stage 1: provide Rust toolchain (required by setup.py -> build_ov_cli_artifact -> cargo build)
# ragfs-python's default S3-enabled dependency set currently requires rustc >= 1.91.1.
FROM ${REGISTRY_PREFIX}${RUST_IMAGE}@${RUST_DIGEST} AS rust-toolchain

# Stage 2: build Studio separately so npm failures stop the Docker build.
FROM ${REGISTRY_PREFIX}${NODE_IMAGE}@${NODE_DIGEST} AS web-studio-builder
ARG TARGETPLATFORM
ARG npm_config_registry
WORKDIR /app/web-studio

# Keep npm install cached when only Studio sources change.
COPY web-studio/package.json web-studio/package-lock.json ./
RUN --mount=type=cache,target=/root/.npm,id=npm-${TARGETPLATFORM} npm ci
COPY web-studio/ ./
RUN npm run build -- --base=/studio/ \
 && test -f dist/index.html

# Stage 3: build Python environment with uv (builds Rust CLI + C++ extension)
FROM ${REGISTRY_PREFIX}${PYTHON_IMAGE}@${PYTHON_DIGEST} AS py-builder
ARG PIP_INDEX_URL
ARG UV_DEFAULT_INDEX

# uv from PyPI, pinned by hash, in place of the ghcr.io/astral-sh/uv image.
RUN printf '%s\n' 'uv==0.13.5 --hash=sha256:2386c2dc9b59fc1d39b1c500e4319d71d3268232eb3b38e29cd6775d6269e8d4 --hash=sha256:91e58e304b63b6c91bac5561459ab0c3ea24f17bc01ea9359d69fed72142978f --hash=sha256:d162669e3a7811c584b03690eaa11e796ad1d309aa8229d5dfe3cbcd68a90400 --hash=sha256:fa8d26e08e34c29c0c4e820cf3181757086d547240b4f4d31ff1d8bd810ca946' > /tmp/uv-requirements.txt \
 && python -m pip install --no-cache-dir --root-user-action=ignore --only-binary=:all: --require-hashes -r /tmp/uv-requirements.txt \
 && rm /tmp/uv-requirements.txt

# Reuse Rust toolchain from stage 1 so setup.py can compile ov CLI in-place.
COPY --from=rust-toolchain /usr/local/cargo /usr/local/cargo
COPY --from=rust-toolchain /usr/local/rustup /usr/local/rustup
ENV CARGO_HOME=/usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup
ENV PATH="/app/.venv/bin:/usr/local/cargo/bin:${PATH}"
ARG OPENVIKING_VERSION=
ARG TARGETPLATFORM
ARG UV_LOCK_STRATEGY=auto

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ccache \
    cmake \
    git \
 && rm -rf /var/lib/apt/lists/*

# Route gcc/g++/cc through ccache so cmake (which asks shutil.which("gcc")) picks
# up /usr/lib/ccache/gcc and benefits from the BuildKit cache mount on /root/.ccache.
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR=/root/.ccache
# Pin Cargo's target dir to a stable path so a BuildKit cache mount can persist
# build artifacts across layer reruns even when uv builds the wheel in an
# ephemeral isolated tempdir.
ENV CARGO_TARGET_DIR=/cargo-target

ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy
ENV UV_NO_DEV=1
WORKDIR /app

# Copy source required for setup.py artifact builds and native extension build.
COPY Cargo.toml Cargo.lock ./
COPY pyproject.toml uv.lock setup.py README.md ./
COPY scripts/build_support/ scripts/build_support/
COPY bot/ bot/
COPY crates/ crates/
COPY openviking/ openviking/
COPY --from=web-studio-builder /app/web-studio/dist/ openviking/web_studio/dist/
COPY openviking_cli/ openviking_cli/
COPY openviking_gateway/ openviking_gateway/
COPY src/ src/
COPY third_party/ third_party/

# Install project and dependencies. setup.py packages the copied Studio bundle
# without running npm again, while build_ext still builds native extensions.
# Default to auto-refreshing uv.lock inside the ephemeral build context when it is
# stale, so Docker builds stay unblocked after dependency changes. Set
# UV_LOCK_STRATEGY=locked to keep fail-fast reproducibility checks.
RUN --mount=type=cache,target=/root/.cache/uv,id=uv-${TARGETPLATFORM} \
    --mount=type=cache,target=/cargo-target,id=cargo-target-${TARGETPLATFORM} \
    --mount=type=cache,target=/usr/local/cargo/registry,id=cargo-registry-${TARGETPLATFORM} \
    --mount=type=cache,target=/usr/local/cargo/git,id=cargo-git-${TARGETPLATFORM} \
    --mount=type=cache,target=/root/.ccache,id=ccache-${TARGETPLATFORM} \
    if [ -n "${OPENVIKING_VERSION:-}" ]; then \
        export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_OPENVIKING="${OPENVIKING_VERSION}"; \
    elif [ -f openviking/_version.py ]; then \
        export SETUPTOOLS_SCM_PRETEND_VERSION_FOR_OPENVIKING="$(python -c "import runpy; print(runpy.run_path('openviking/_version.py')['version'])")"; \
    else \
        echo "OPENVIKING_VERSION build arg is required when building without openviking/_version.py" >&2; \
        exit 2; \
    fi; \
    case "${UV_LOCK_STRATEGY}" in \
        locked) \
            uv sync --locked --no-editable --reinstall-package openviking --extra bot --extra gemini --extra opengauss --extra expiry --extra mysql --extra redis-mysql \
            ;; \
        auto) \
            if ! uv lock --check; then \
                uv lock; \
            fi; \
            uv sync --locked --no-editable --reinstall-package openviking --extra bot --extra gemini --extra opengauss --extra expiry --extra mysql --extra redis-mysql \
            ;; \
        *) \
            echo "Unsupported UV_LOCK_STRATEGY: ${UV_LOCK_STRATEGY}" >&2; \
            exit 2 \
            ;; \
    esac

# Stage 4: runtime
FROM ${REGISTRY_PREFIX}${PYTHON_IMAGE}@${PYTHON_DIGEST}
ARG PYTHON_IMAGE
ARG PYTHON_DIGEST
LABEL org.opencontainers.image.base.name="${PYTHON_IMAGE}" \
      org.opencontainers.image.base.digest="${PYTHON_DIGEST}"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    libstdc++6 \
    libcairo2 \
 && rm -rf /var/lib/apt/lists/*

# Resolve relative storage paths inside the persistent mount.
WORKDIR /app/.openviking

COPY --from=py-builder /app/.venv /app/.venv
# Exercise SVG rendering so missing Python or Cairo runtime dependencies fail the build.
RUN /app/.venv/bin/python -I - <<'PYCODE'
import cairosvg

svg = b'<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="red"/></svg>'
png = cairosvg.svg2png(bytestring=svg)
assert png.startswith(b"\x89PNG\r\n\x1a\n"), "SVG conversion did not produce a PNG"
PYCODE
# Fail the image build if VikingBot and the separately released SDK drift apart.
RUN /app/.venv/bin/python -I -c "import inspect, typing; from importlib.metadata import version; from openviking_sdk.client import AsyncHTTPClient; from openviking_sdk.options import BatchWriteOptions; checks = {'get_skill.include_integrity': 'include_integrity' in inspect.signature(AsyncHTTPClient.get_skill).parameters, 'ls.offset': 'offset' in inspect.signature(AsyncHTTPClient.ls).parameters, 'grep.level_limit': 'level_limit' in inspect.signature(AsyncHTTPClient.grep).parameters, 'BatchWriteOptions.skip_conflicts': 'skip_conflicts' in typing.get_type_hints(BatchWriteOptions)}; missing = [name for name, ok in checks.items() if not ok]; raise SystemExit(f\"incompatible openviking-sdk {version('openviking-sdk')}: missing {', '.join(missing)}\" if missing else 0)"
RUN /app/.venv/bin/python -I -c "from importlib.util import find_spec; from pathlib import Path; spec = find_spec('openviking.web_studio'); locations = list(spec.submodule_search_locations or ()) if spec else []; root = Path('/app/.venv').resolve(); p = (Path(locations[0]).resolve() / 'dist/index.html').resolve() if len(locations) == 1 else None; valid = p is not None and p.is_file() and p.is_relative_to(root); raise SystemExit(0 if valid else f'missing or misplaced Studio bundle: spec_found={spec is not None}, locations={locations!r}, resource={p}')"
# Redis and the gateway Lua scripts must survive wheel packaging.
RUN /app/.venv/bin/python -I -c "import redis; from importlib.resources import files; assert any(p.name.endswith('.lua') for p in files('openviking_gateway').joinpath('lua').iterdir()), 'gateway Lua scripts missing from installed package'"
COPY deploy/docker/openviking-entrypoint.sh /usr/local/bin/openviking-entrypoint
COPY deploy/docker/pending_health_server.py /usr/local/bin/openviking-pending-health
RUN mkdir -p /app/.openviking \
 && sed -i 's/\r$//' /usr/local/bin/openviking-entrypoint /usr/local/bin/openviking-pending-health \
 && chmod +x /usr/local/bin/openviking-entrypoint /usr/local/bin/openviking-pending-health
ENV HOME="/app" \
    PATH="/app/.venv/bin:$PATH" \
    OPENVIKING_CONFIG_FILE="/app/.openviking/ov.conf" \
    OPENVIKING_CLI_CONFIG_FILE="/app/.openviking/ovcli.conf"

EXPOSE 1933

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["openviking-entrypoint", "--healthcheck"]

# Default persistent state (ov.conf, ovcli.conf, workspace data) lives under
# /app/.openviking, which mirrors the host's ~/.openviking layout. Mount one
# volume there to persist everything across container restarts:
#   docker run -v ~/.openviking:/app/.openviking <image>
# If ov.conf is absent on first start, set OPENVIKING_CONF_CONTENT to the full
# JSON, or `docker exec` in and run `openviking-server init`.
# Override command to run CLI, e.g.:
# docker run --rm -v ~/.openviking:/app/.openviking <image> openviking --help
ENTRYPOINT ["openviking-entrypoint"]
