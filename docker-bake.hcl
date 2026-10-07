# Local image build of OpenViking from this source tree. See docs/image.md.
# Use scripts/build.sh; it sets the Git-derived variables below.
#
#   docker buildx bake -f docker-bake.hcl --print
#   sh scripts/build.sh gateway | smoke | test | release

variable "GATEWAY_IMAGE" {
  default = "openviking:local"
}

# Name of the release image, used only with scripts/build.sh --push.
variable "RELEASE_IMAGE" {
  default = "openviking"
}

# Output of the release target: an OCI archive path, or empty for an image
# output (pushed only when RELEASE_PUSH is true).
variable "RELEASE_OCI" {
  default = ""
}

variable "RELEASE_PUSH" {
  default = false
}

variable "RELEASE_PLATFORMS" {
  default = "linux/amd64,linux/arm64"
}

# Mirror or air-gapped registry for the base images, with a trailing "/".
variable "REGISTRY_PREFIX" {
  default = ""
}

# Base images: the same pins as the ARG defaults of the Dockerfile.
# scripts/build.sh refuses to build when the two differ.
variable "RUST_IMAGE" {
  default = "rust:1.91.1-trixie"
}
variable "RUST_DIGEST" {
  default = "sha256:867f1d1162913c401378a8504fb17fe2032c760dc316448766f150a130204aad"
}
variable "NODE_IMAGE" {
  default = "node:24-trixie-slim"
}
variable "NODE_DIGEST" {
  default = "sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe"
}
variable "PYTHON_IMAGE" {
  default = "python:3.13-slim-trixie"
}
variable "PYTHON_DIGEST" {
  default = "sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c"
}

# PEP 440 version for the Python package and the ov CLI (scripts/build.sh).
variable "OPENVIKING_VERSION" {
  default = ""
}

# Upstream release version without the "v", for the version label.
variable "UPSTREAM_VERSION" {
  default = "0.0.0"
}

variable "PORTABLE_VERSION" {
  default = "0"
}

variable "REVISION" {
  default = ""
}

variable "SOURCE_DATE_EPOCH" {
  default = "0"
}

variable "SOURCE_URL" {
  default = "https://github.com/volcengine/OpenViking"
}

# "locked" fails on a stale uv.lock. Set UV_LOCK_STRATEGY=auto only on purpose.
variable "UV_LOCK_STRATEGY" {
  default = "locked"
}

variable "PROVENANCE" {
  default = false
}

group "default" {
  targets = ["gateway"]
}

# The runtime image. No output of its own; the other targets use it.
target "image" {
  context    = "."
  dockerfile = "Dockerfile"
  args = {
    OPENVIKING_VERSION = OPENVIKING_VERSION
    UV_LOCK_STRATEGY   = UV_LOCK_STRATEGY
    REGISTRY_PREFIX    = REGISTRY_PREFIX
    RUST_IMAGE         = RUST_IMAGE
    RUST_DIGEST        = RUST_DIGEST
    NODE_IMAGE         = NODE_IMAGE
    NODE_DIGEST        = NODE_DIGEST
    PYTHON_IMAGE       = PYTHON_IMAGE
    PYTHON_DIGEST      = PYTHON_DIGEST
    SOURCE_DATE_EPOCH  = SOURCE_DATE_EPOCH
  }
  labels = {
    "org.opencontainers.image.source"   = SOURCE_URL
    "org.opencontainers.image.revision" = REVISION
    "org.opencontainers.image.version"  = "${UPSTREAM_VERSION}-p${PORTABLE_VERSION}"
    "org.opencontainers.image.created"  = timeadd("1970-01-01T00:00:00Z", "${SOURCE_DATE_EPOCH}s")
    "org.opencontainers.image.title"    = "OpenViking"
    "org.opencontainers.image.licenses" = "AGPL-3.0"
  }
  attest = PROVENANCE ? ["type=provenance,mode=max"] : ["type=provenance,disabled=true", "type=sbom,disabled=true"]
}

# Python build stage of the Dockerfile; the test target copies uv from it.
target "builder" {
  inherits = ["image"]
  target   = "py-builder"
}

target "gateway" {
  inherits = ["image"]
  tags     = [GATEWAY_IMAGE]
  output   = ["type=docker"]
}

target "smoke" {
  contexts = {
    image = "target:image"
  }
  dockerfile-inline = <<-EOT
    FROM image
    RUN --network=none python -I -c "import openviking; print('openviking', openviking.__version__)" \
     && command -v ov openviking-server openviking-entrypoint
  EOT
  output = ["type=cacheonly"]
}

# The upstream lite test set (.github/workflows/_test_lite.yml) inside the
# image. Only pytest, pytest-asyncio and numpy (from the test extra) are added,
# with the versions and hashes of uv.lock; the tests run without network.
target "test" {
  contexts = {
    image   = "target:image"
    builder = "target:builder"
    tests   = "tests"
  }
  args = {
    UV_LOCK_STRATEGY = UV_LOCK_STRATEGY
  }
  dockerfile-inline = <<-EOT
    FROM image
    COPY --from=builder /usr/local/bin/uv /usr/local/bin/uv
    WORKDIR /src
    COPY pyproject.toml uv.lock ./
    COPY --from=tests / tests/
    RUN uv export --frozen --no-emit-project --no-header --no-annotate --extra test --group dev -o /tmp/all.txt \
     && python -I -c "import re; keep = {'pytest', 'pytest-asyncio', 'iniconfig', 'pluggy', 'packaging', 'pygments', 'numpy'}; blocks = re.split(r'\n(?=\S)', open('/tmp/all.txt').read()); open('/tmp/req.txt', 'w').write('\n'.join(b for b in blocks if b.split('==')[0].strip() in keep) + '\n')" \
     && uv pip install --python /app/.venv/bin/python --no-deps --require-hashes -r /tmp/req.txt
    RUN --network=none python -m pytest -q -p no:cacheprovider -o addopts='' -rs \
          tests/vectordb/test_cuvs_config.py \
          tests/vectordb/test_cuvs_index.py \
          tests/vectordb/test_cuvs_collection.py \
          tests/vectordb/test_str_to_uint64.py
  EOT
  output = ["type=cacheonly"]
}

target "release" {
  inherits  = ["image"]
  platforms = split(",", RELEASE_PLATFORMS)
  tags      = RELEASE_OCI == "" ? ["${RELEASE_IMAGE}:${UPSTREAM_VERSION}-p${PORTABLE_VERSION}"] : []
  output = [
    RELEASE_OCI != ""
    ? "type=oci,dest=${RELEASE_OCI},rewrite-timestamp=true"
    : "type=image,push=${RELEASE_PUSH},rewrite-timestamp=true"
  ]
}
