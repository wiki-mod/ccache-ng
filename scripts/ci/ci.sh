#!/usr/bin/env bash
set -Eeuo pipefail

readonly PROJECT_NAME="ccache-ng"
readonly NIGHTLY_RELEASE="${PROJECT_NAME}-nightly"
readonly FAILURE_LABEL_NIGHTLY="Nightly"
readonly FAILURE_LABEL_CI="CI-Failure"
readonly FAILURE_MARKER="<!-- ccache-ng-nightly-failure -->"
readonly BUILD_DOCKERFILE="debian-13"
readonly BUILD_IMAGE_BASE="debian:13"
readonly RUNTIME_IMAGE_BASE="debian:13"
readonly RETENTION_KEEP="7"
readonly RETENTION_DAYS="14"

MODE="${MODE:-${1:-nightly}}"
ARCH="${ARCH:-all}"
REQUESTED_MODE="${REQUESTED_MODE:-$MODE}"
REQUESTED_ARCH="${REQUESTED_ARCH:-$ARCH}"
FORCE="${FORCE:-false}"
PUBLISH="${PUBLISH:-true}"
CLEANUP="${CLEANUP:-true}"
DEBUG="${DEBUG:-false}"
RELEASE_TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"

if [ "$DEBUG" = "true" ]; then
  set -x
fi

if [ -n "${PROJECT_AUTOMATION_PAT:-}" ]; then
  export GH_TOKEN="$PROJECT_AUTOMATION_PAT"
  export GITHUB_TOKEN="$PROJECT_AUTOMATION_PAT"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  export GH_TOKEN="${GH_TOKEN:-$GITHUB_TOKEN}"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && { pwd -W 2>/dev/null || pwd; })"
WORK_DIR="${RUNNER_TEMP:-$ROOT_DIR/.tmp}/ccache-ng-ci"
OUT_DIR="$ROOT_DIR/dist/ccache-ng"
META_DIR="$OUT_DIR/metadata"
BIN_DIR="$OUT_DIR/bin"
RELEASE_DIR="$OUT_DIR/release"

log() {
  printf '%s\n' "$*" >&2
}

die() {
  log "error: $*"
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

ensure_dirs() {
  mkdir -p "$WORK_DIR" "$OUT_DIR" "$META_DIR" "$BIN_DIR" "$RELEASE_DIR"
}

repo_owner() {
  printf '%s\n' "${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY%%/*}}"
}

gh_repo() {
  printf '%s\n' "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
}

image_name() {
  printf 'ghcr.io/%s/%s\n' "$(repo_owner)" "$PROJECT_NAME"
}

runtime_image_name() {
  image_name
}

redis_cache_image_name() {
  printf '%s-redis-cache:local\n' "$PROJECT_NAME"
}

redis_cache_network_name() {
  printf '%s-redis-%s-%s\n' "$PROJECT_NAME" "$(native_arch)" "${GITHUB_RUN_ID:-local}"
}

redis_cache_container_name() {
  printf '%s-redis-cache-%s-%s\n' "$PROJECT_NAME" "$(native_arch)" "${GITHUB_RUN_ID:-local}"
}

selected_arches() {
  case "$REQUESTED_ARCH" in
    all) printf '%s\n' amd64 arm64 ;;
    amd64|arm64) printf '%s\n' "$REQUESTED_ARCH" ;;
    *) die "unsupported REQUESTED_ARCH: $REQUESTED_ARCH" ;;
  esac
}

arch_requested() {
  [ "$REQUESTED_ARCH" = "all" ] || [ "$REQUESTED_ARCH" = "$1" ]
}

native_arch() {
  case "$(uname -m)" in
    x86_64) printf 'amd64\n' ;;
    aarch64|arm64) printf 'arm64\n' ;;
    *) die "unsupported native machine: $(uname -m)" ;;
  esac
}

source_sha() {
  git -C "$ROOT_DIR" rev-parse HEAD
}

source_version() {
  git -C "$ROOT_DIR" describe --tags --always --dirty --abbrev=12
}

release_tag_name() {
  if [ -n "$RELEASE_TAG" ]; then
    printf '%s\n' "$RELEASE_TAG"
    return 0
  fi
  if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    printf '%s\n' "${GITHUB_REF_NAME:?release tag is required}"
    return 0
  fi
  die "release tag is required for release mode"
}

ci_identity() {
  {
    git -C "$ROOT_DIR" hash-object scripts/ci/ci.sh
    git -C "$ROOT_DIR" hash-object ci/build
    git -C "$ROOT_DIR" hash-object misc/build-in-docker
    git -C "$ROOT_DIR" hash-object ci/prepare-release
  } | sha256sum | awk '{print $1}'
}

metadata_json() {
  local created
  created="$(date -u +%FT%TZ)"
  jq -n \
    --arg project "$PROJECT_NAME" \
    --arg repository "$(gh_repo)" \
    --arg source_sha "$(source_sha)" \
    --arg source_version "$(source_version)" \
    --arg ci_identity "$(ci_identity)" \
    --arg build_dockerfile "$BUILD_DOCKERFILE" \
    --arg build_image_base "$BUILD_IMAGE_BASE" \
    --arg runtime_image_base "$RUNTIME_IMAGE_BASE" \
    --arg created "$created" \
    '{
      project:$project,
      repository:$repository,
      source_sha:$source_sha,
      source_version:$source_version,
      ci_identity:$ci_identity,
      build_dockerfile:$build_dockerfile,
      build_image_base:$build_image_base,
      runtime_image_base:$runtime_image_base,
      created:$created
    }'
}

metadata_path() {
  printf '%s/build-metadata.json\n' "$META_DIR"
}

write_metadata() {
  metadata_json > "$(metadata_path)"
}

release_name() {
  if [ "$REQUESTED_MODE" = "release" ] || [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    release_tag_name
    return 0
  fi
  printf '%s\n' "$NIGHTLY_RELEASE"
}

release_prerelease() {
  if [ "$REQUESTED_MODE" = "release" ] || [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
}

release_title() {
  if [ "$REQUESTED_MODE" = "release" ] || [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    printf '%s\n' "$(release_name)"
  else
    printf '%s nightly\n' "$PROJECT_NAME"
  fi
}

release_notes_path() {
  printf '%s/release-notes.md\n' "$WORK_DIR"
}

write_release_notes() {
  {
    printf '%s\n\n' "$(release_title)"
    printf 'Repository: %s\n' "$(gh_repo)"
    printf 'Source SHA: %s\n' "$(source_sha)"
    printf 'Version: %s\n' "$(source_version)"
    printf 'Run: %s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  } > "$(release_notes_path)"
}

download_current_metadata() {
  local dest_dir dest
  dest_dir="$WORK_DIR/current-release"
  dest="$dest_dir/build-metadata.json"
  rm -rf "$dest_dir"
  mkdir -p "$dest_dir"
  gh release download "$(release_name)" \
    --repo "$(gh_repo)" \
    --pattern build-metadata.json \
    --dir "$dest_dir" >/dev/null 2>&1 || return 1
  [ -s "$dest" ] || return 1
  printf '%s\n' "$dest"
}

admission_needed() {
  [ "$FORCE" = "true" ] && return 0
  [ "$REQUESTED_MODE" = "release" ] && return 0
  [ "${GITHUB_REF_TYPE:-}" = "tag" ] && return 0
  local current
  current="$(download_current_metadata)" || return 0
  cmp -s "$(metadata_path)" "$current" && return 1
  return 0
}

emit_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
  fi
}

docker_login() {
  [ "$PUBLISH" = "true" ] || return 0
  printf '%s' "${GH_TOKEN:?PROJECT_AUTOMATION_PAT or GITHUB_TOKEN is required}" \
    | docker login ghcr.io -u "${GITHUB_ACTOR:?GITHUB_ACTOR is required}" --password-stdin
}

ensure_buildx_builder() {
  local name="$1"
  docker buildx rm -f "$name" >/dev/null 2>&1 || true
  docker buildx create --name "$name" --driver docker-container --use --bootstrap >/dev/null
}

platform_for_arch() {
  case "$1" in
    amd64) printf 'linux/amd64\n' ;;
    arm64) printf 'linux/arm64\n' ;;
    *) die "unsupported arch: $1" ;;
  esac
}

build_arch_dir() {
  printf '%s/build/nightly-%s\n' "$WORK_DIR" "$1"
}

start_redis_cache() {
  require_cmd docker
  local image network container
  image="$(redis_cache_image_name)"
  network="$(redis_cache_network_name)"
  container="$(redis_cache_container_name)"

  docker network create "$network" >/dev/null 2>&1 || true
  docker build -t "$image" "$ROOT_DIR/dockerfiles/redis-cache" >/dev/null
  docker run -d \
    --name "$container" \
    --network "$network" \
    --network-alias redis-cache \
    "$image" >/dev/null

  for _ in $(seq 1 60); do
    if docker exec "$container" redis-cli ping >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  docker exec "$container" redis-cli ping >/dev/null 2>&1 \
    || die "redis cache container did not become ready"

  docker logs "$container"

  export DOCKER_NETWORK="$network"
  export CCACHE_REMOTE_STORAGE="redis://redis-cache|connect-timeout=5000|operation-timeout=5000"
  export CCACHE_RESHARE="${CCACHE_RESHARE:-true}"
}

stop_redis_cache() {
  local network container
  network="$(redis_cache_network_name)"
  container="$(redis_cache_container_name)"
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}

build_binary() {
  local arch build_dir
  arch="$(native_arch)"
  arch_requested "$arch" || return 0
  build_dir="$(build_arch_dir "$arch")"
  rm -rf "$build_dir"
  mkdir -p "$WORK_DIR/build-cache"
  mkdir -p "$WORK_DIR/build"
  mkdir -p "$WORK_DIR/install"
  WORK_DIR="$WORK_DIR" \
  BUILDDIR="/work/build/nightly-${arch}" \
  CMAKE_PARAMS="-D DEPS=DOWNLOAD" \
  JOBS="$(( $(nproc) * 2 ))" \
  bash "$ROOT_DIR/misc/build-in-docker" "$BUILD_DOCKERFILE"
  [ -x "$build_dir/ccache" ] || die "missing built binary: $build_dir/ccache"
  mkdir -p "$BIN_DIR/$arch"
  cp "$build_dir/ccache" "$BIN_DIR/$arch/ccache"
  chmod 0755 "$BIN_DIR/$arch/ccache"
}

build_release_docs() {
  rm -rf "$WORK_DIR/build-docs" "$WORK_DIR/install"
  mkdir -p "$WORK_DIR/build-docs" "$WORK_DIR/install"
  WORK_DIR="$WORK_DIR" \
  BUILDDIR="/work/build-docs" \
  INSTALLDIR="/work/install" \
  COMMAND=/source/ci/build-docs \
  LAUNCHER="cd /source &&" \
  bash "$ROOT_DIR/misc/build-in-docker" "$BUILD_DOCKERFILE"
  [ -d "$WORK_DIR/install/usr/local/share/doc/ccache" ] || die "missing release docs: $WORK_DIR/install/usr/local/share/doc/ccache"
  [ -f "$WORK_DIR/install/usr/local/share/man/man1/ccache.1" ] || die "missing release manpage: $WORK_DIR/install/usr/local/share/man/man1/ccache.1"
}

package_binary_release() {
  local arch name root
  arch="$(native_arch)"
  name="${PROJECT_NAME}-$(source_version)-$(source_sha)-${arch}"
  root="$WORK_DIR/$name"
  rm -rf "$root"
  mkdir -p "$root"
  cp "$BIN_DIR/$arch/ccache" "$root/ccache"
  chmod 0755 "$root/ccache"
  cp "$ROOT_DIR"/misc/install.sh "$ROOT_DIR"/misc/Makefile.posix-binary-release \
    "$ROOT_DIR"/misc/patch-binary.py "$ROOT_DIR"/GPL-3.0.txt "$ROOT_DIR"/README.md \
    "$root/"
  cp -a "$WORK_DIR/install/usr/local/share/doc/ccache/." "$root/"
  cp "$WORK_DIR/install/usr/local/share/man/man1/ccache.1" "$root/"
  tar -C "$WORK_DIR" -czf "$RELEASE_DIR/${name}.tar.gz" "$name"
  tar -C "$WORK_DIR" -cJf "$RELEASE_DIR/${name}.tar.xz" "$name"
}

prepare_source_release() {
  local name
  name="${PROJECT_NAME}-$(source_version)-$(source_sha)"
  git -C "$ROOT_DIR" archive --prefix="${name}/" -o "$RELEASE_DIR/${name}.tar" HEAD
  gzip --keep -9 "$RELEASE_DIR/${name}.tar"
  xz --keep -9 "$RELEASE_DIR/${name}.tar"
  rm "$RELEASE_DIR/${name}.tar"
}

write_checksums() {
  (
    cd "$OUT_DIR"
    find release -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tar.xz' -o -name '*.json' \) \
      | sort \
      | xargs sha256sum > SHA256SUMS
  )
}

runtime_containerfile() {
  local file="$WORK_DIR/Containerfile.runtime"
  cat > "$file" <<EOF
FROM ${RUNTIME_IMAGE_BASE}
LABEL org.opencontainers.image.title="${PROJECT_NAME}"
LABEL org.opencontainers.image.source="https://github.com/$(gh_repo)"
LABEL org.opencontainers.image.revision="$(source_sha)"
LABEL org.opencontainers.image.version="$(source_version)"
LABEL org.opencontainers.image.created="$(date -u +%FT%TZ)"
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates libhiredis-dev libzstd-dev \
 && apt-get dist-upgrade -y \
 && rm -rf /var/lib/apt/lists/*
COPY ccache /usr/local/bin/ccache
ENTRYPOINT ["ccache"]
EOF
  printf '%s\n' "$file"
}

build_runtime_image() {
  require_cmd docker
  docker_login
  local arch image file output rootfs
  arch="$(native_arch)"
  arch_requested "$arch" || return 0
  image="$(runtime_image_name)"
  file="$(runtime_containerfile)"
  rootfs="$WORK_DIR/runtime-$arch"
  rm -rf "$rootfs"
  mkdir -p "$rootfs"
  cp "$BIN_DIR/$arch/ccache" "$rootfs/ccache"
  ensure_buildx_builder "${PROJECT_NAME}-runtime-${arch}"
  output="type=image,name=${image},push-by-digest=true,name-canonical=true,push=true"
  if [ "$PUBLISH" != "true" ]; then
    output="type=docker,dest=${META_DIR}/runtime-${arch}.tar"
  fi
  docker buildx build \
    --pull \
    --platform "$(platform_for_arch "$arch")" \
    --cache-from "type=gha,scope=${PROJECT_NAME}-runtime-${arch}" \
    --cache-to "type=gha,mode=max,scope=${PROJECT_NAME}-runtime-${arch}" \
    --attest type=provenance,mode=max \
    --attest type=sbom \
    --metadata-file "$META_DIR/runtime-${arch}.json" \
    --output "$output" \
    -f "$file" "$rootfs"
  if [ "$PUBLISH" = "true" ]; then
    jq -r '."containerimage.digest"' "$META_DIR/runtime-${arch}.json" > "$META_DIR/runtime-${arch}.digest"
  fi
}

manifest_platform_digest() {
  require_cmd jq
  local image digest arch
  image="$1"
  digest="$2"
  arch="$3"
  docker manifest inspect "${image}@${digest}" \
    | jq -r --arg arch "$arch" '
        .manifests[]?
        | select(.platform.os == "linux" and .platform.architecture == $arch)
        | .digest
      ' \
    | head -n1
}

build() {
  require_cmd bash
  require_cmd cp
  require_cmd tar
  require_cmd gzip
  require_cmd xz
  require_cmd git
  require_cmd docker
  ensure_dirs
  start_redis_cache
  trap 'stop_redis_cache' EXIT INT TERM
  build_binary
  build_release_docs
  package_binary_release
  prepare_source_release
  write_metadata
  cp "$(metadata_path)" "$RELEASE_DIR/build-metadata.json"
  write_checksums
  if [ "$PUBLISH" = "true" ]; then
    build_runtime_image
  fi
  stop_redis_cache
  trap - EXIT INT TERM
}

verify() {
  require_cmd docker
  ensure_dirs
  start_redis_cache
  trap 'stop_redis_cache' EXIT INT TERM
  build_binary
  stop_redis_cache
  trap - EXIT INT TERM
  log "verify=ok"
}

promote() {
  require_cmd docker
  docker_login
  local image sha arch digest platform_digest refs=()
  image="$(runtime_image_name)"
  sha="$(source_sha)"
  while IFS= read -r arch; do
    digest="$(cat "$META_DIR/runtime-${arch}.digest")"
    platform_digest="$(manifest_platform_digest "$image" "$digest" "$arch")"
    [ -n "$platform_digest" ] || die "missing runtime platform digest for $arch"
    refs+=("${image}@${platform_digest}")
  done < <(selected_arches)
  [ "${#refs[@]}" -gt 0 ] || die "no runtime digests found"
  if [ "$REQUESTED_MODE" = "release" ] || [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
    docker buildx imagetools create \
      -t "${image}:latest" \
      -t "${image}:nightly" \
      -t "${image}:${sha}" \
      -t "${image}:$(release_tag_name)" \
      "${refs[@]}"
  else
    docker buildx imagetools create \
      -t "${image}:latest" \
      -t "${image}:nightly" \
      -t "${image}:${sha}" \
      "${refs[@]}"
  fi
}

publish_release() {
  [ "$PUBLISH" = "true" ] || return 0
  require_cmd gh
  ensure_dirs
  write_release_notes
  local name prerelease
  name="$(release_name)"
  prerelease="$(release_prerelease)"
  if gh release view "$name" --repo "$(gh_repo)" >/dev/null 2>&1; then
    if [ "$prerelease" = "true" ]; then
      gh release edit "$name" --repo "$(gh_repo)" --title "$(release_title)" --notes-file "$(release_notes_path)" --prerelease >/dev/null
    else
      gh release edit "$name" --repo "$(gh_repo)" --title "$(release_title)" --notes-file "$(release_notes_path)" >/dev/null
    fi
  else
    if [ "$prerelease" = "true" ]; then
      gh release create "$name" --repo "$(gh_repo)" --title "$(release_title)" --notes-file "$(release_notes_path)" --prerelease >/dev/null
    else
      gh release create "$name" --repo "$(gh_repo)" --title "$(release_title)" --notes-file "$(release_notes_path)" >/dev/null
    fi
  fi
  find "$RELEASE_DIR" -maxdepth 1 -type f -print0 \
    | xargs -0 gh release upload "$name" --repo "$(gh_repo)" --clobber >/dev/null
}

failure_issue_number() {
  if [ "$(gh repo view "$(gh_repo)" --json hasIssues --jq '.hasIssues' || printf 'false')" != "true" ]; then
    return 0
  fi
  gh issue list \
    --repo "$(gh_repo)" \
    --label "$FAILURE_LABEL_NIGHTLY" \
    --label "$FAILURE_LABEL_CI" \
    --state open \
    --json number,body \
    --jq ".[] | select(.body | contains(\"$FAILURE_MARKER\")) | .number" \
    | head -n1
}

report_failure() {
  [ "$PUBLISH" = "true" ] || return 0
  require_cmd gh
  ensure_dirs
  local number body title
  title="ccache-ng nightly failed"
  body="$WORK_DIR/failure.md"
  {
    printf '%s\n\n' "$FAILURE_MARKER"
    printf 'Nightly failed.\n\n'
    printf 'Run: %s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
  } > "$body"
  gh label create "$FAILURE_LABEL_NIGHTLY" --repo "$(gh_repo)" --force >/dev/null 2>&1 || true
  gh label create "$FAILURE_LABEL_CI" --repo "$(gh_repo)" --force >/dev/null 2>&1 || true
  number="$(failure_issue_number || true)"
  if [ "$(gh repo view "$(gh_repo)" --json hasIssues --jq '.hasIssues' || printf 'false')" != "true" ]; then
    log "issue tracking is disabled; skipping failure issue creation"
    return 0
  fi
  if [ -n "$number" ]; then
    gh issue comment "$number" --repo "$(gh_repo)" --body-file "$body" >/dev/null || {
      log "failed to update failure issue; continuing"
      return 0
    }
  else
    gh issue create --repo "$(gh_repo)" --title "$title" --body-file "$body" --label "$FAILURE_LABEL_NIGHTLY,$FAILURE_LABEL_CI" >/dev/null || {
      log "failed to create failure issue; continuing"
      return 0
    }
  fi
}

close_failure_issue() {
  [ "$PUBLISH" = "true" ] || return 0
  require_cmd gh
  ensure_dirs
  local number body
  number="$(failure_issue_number || true)"
  [ -n "$number" ] || return 0
  body="$WORK_DIR/recovered.md"
  printf 'Nightly recovered in %s\n' "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" > "$body"
  gh issue comment "$number" --repo "$(gh_repo)" --body-file "$body" >/dev/null
  gh issue close "$number" --repo "$(gh_repo)" --reason completed >/dev/null
}

gc_images() {
  [ "$PUBLISH" = "true" ] || return 0
  [ "$CLEANUP" = "true" ] || return 0
  require_cmd gh
  require_cmd jq
  local owner package base cutoff protected
  owner="$(repo_owner)"
  package="$PROJECT_NAME"
  base="/orgs/${owner}/packages/container/${package}/versions"
  gh api "$base" --paginate >/dev/null 2>&1 || base="/users/${owner}/packages/container/${package}/versions"
  cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +%s)"
  protected="$(mktemp)"
  gh api "$base" --paginate \
    --jq '.[] | select(.metadata.container.tags[]? == "latest" or .metadata.container.tags[]? == "nightly" or (.metadata.container.tags[]? | startswith("v"))) | .id' \
    > "$protected" || true
  gh api "$base" --paginate \
    --jq '.[] | [.id, .created_at, (.metadata.container.tags | join(","))] | @tsv' \
    | sort -k2r \
    | awk -F '\t' -v keep="$RETENTION_KEEP" -v cutoff="$cutoff" -v protected="$protected" '
        BEGIN {
          while ((getline line < protected) > 0) safe[line] = 1
        }
        {
          id = $1
          created = $2
          tags = $3
          cmd = "date -u -d \"" created "\" +%s"
          cmd | getline ts
          close(cmd)
          if (safe[id]) next
          if (tags !~ /(^|,)[0-9a-f]{40}(,|$)/) next
          seen++
          if (seen > keep || ts < cutoff) print id
        }' \
    | while IFS= read -r id; do
        gh api -X DELETE "${base}/${id}" >/dev/null
      done
}

admission() {
  require_cmd gh
  require_cmd jq
  ensure_dirs
  write_metadata
  local decision="build"
  if admission_needed; then
    decision="build"
  else
    decision="noop"
  fi
  emit_output decision "$decision"
  emit_output source_sha "$(source_sha)"
  emit_output source_version "$(source_version)"
  emit_output image "$(image_name)"
  emit_output runtime_image "$(runtime_image_name)"
  emit_output release_name "$(release_name)"
  log "decision=$decision"
}

usage() {
  cat <<EOF
usage: ci.sh <admission|build|build-runtime|verify|promote|publish-release|gc|report-failure|close-failure>
EOF
}

main() {
  case "$MODE" in
    admission) admission ;;
    build) build ;;
    build-runtime) build_runtime_image ;;
    verify) verify ;;
    promote) promote ;;
    publish-release) publish_release ;;
    gc) gc_images ;;
    report-failure) report_failure ;;
    close-failure) close_failure_issue ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
