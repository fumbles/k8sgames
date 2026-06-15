#!/usr/bin/env bash
#
# build.sh - build, check, and ship the k8sgames OLM package.
#
# Usage:
#   ./build.sh build                  Build current version (from Makefile VERSION)
#   ./build.sh build 0.2.0            Build a specific version
#   ./build.sh build --new-version    Bump patch version (0.1.0 -> 0.1.1), then build
#   ./build.sh build --ship           Build multi-arch (linux/amd64+arm64) and push
#                                     app + bundle + catalog images to Docker Hub
#   ./build.sh check                  Run quality gates only (no image build)
#   ./build.sh clean                  Remove build artifacts
#
# Flags can be combined: ./build.sh build --new-version --ship
#   --skip-checks                     Skip quality gates (not recommended)
#
set -euo pipefail
cd "$(dirname "$0")"

# ---------- helpers ----------------------------------------------------------

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()    { red "ERROR: $*" >&2; exit 1; }

current_version() {
  awk '/^VERSION \?=/ {print $3; exit}' Makefile
}

bump_patch() {
  local v=$1 major minor patch
  IFS=. read -r major minor patch <<<"$v"
  echo "${major}.${minor}.$((patch + 1))"
}

# Rewrite the version everywhere it is pinned so all artifacts stay consistent.
set_version() {
  local old=$1 new=$2
  step "Setting version: ${old} -> ${new}"

  sed -i.bak -E "s/^VERSION \?= .*/VERSION ?= ${new}/" Makefile

  local csv=bundle/manifests/k8sgames.clusterserviceversion.yaml

  # CSV name, version, containerImage annotation, and Deployment image reference
  sed -i.bak -E "s/^  name: k8sgames\.v[0-9]+\.[0-9]+\.[0-9]+/  name: k8sgames.v${new}/" "$csv"
  sed -i.bak -E "s/^  version: [0-9]+\.[0-9]+\.[0-9]+/  version: ${new}/" "$csv"
  sed -i.bak -E \
    "s|(containerImage: .*k8sgames):v[0-9]+\.[0-9]+\.[0-9]+|\1:v${new}|" "$csv"
  sed -i.bak -E \
    "s|(image: .*k8sgames):v[0-9]+\.[0-9]+\.[0-9]+|\1:v${new}|" "$csv"

  if [[ -f config/catalog/catalogsource.yaml ]]; then
    sed -i.bak -E \
      "s|(image: .*k8sgames-catalog):v[0-9]+\.[0-9]+\.[0-9]+|\1:v${new}|" \
      config/catalog/catalogsource.yaml
  fi

  # Maintain the OLM upgrade graph: the new CSV replaces the previous one.
  if grep -qE '^  replaces:' "$csv"; then
    sed -i.bak -E "s/^  replaces: .*/  replaces: k8sgames.v${old}/" "$csv"
  else
    awk -v old="$old" '/^  version:/ {print "  replaces: k8sgames.v" old} {print}' "$csv" > "$csv.tmp" \
      && mv "$csv.tmp" "$csv"
  fi
  yellow "NOTE: spec.replaces now points at v${old}. If v${old} was never published"
  yellow "      to a catalog, remove 'replaces:' from ${csv}."

  find . -name '*.bak' -not -path './bin/*' -delete
}

# ---------- quality gates ----------------------------------------------------

run_checks() {
  local failed=0

  step "Tooling"
  printf '  %-14s %s\n' "containers" "$CONTAINER_TOOL ($(command -v "$CONTAINER_TOOL"))"

  step "Bundle manifests"
  for f in bundle/manifests/k8sgames.clusterserviceversion.yaml bundle/metadata/annotations.yaml; do
    [[ -f "$f" ]] && green "$f" || { red "Missing: $f"; failed=1; }
  done

  step "Config manifests"
  for f in config/catalog/catalogsource.yaml config/catalog/subscription.yaml \
            config/catalog/operatorgroup.yaml config/catalog/service.yaml \
            config/catalog/route.yaml; do
    [[ -f "$f" ]] && green "$f" || { red "Missing: $f"; failed=1; }
  done

  # Optional linters - used when installed, skipped otherwise.
  if command -v operator-sdk >/dev/null; then
    step "operator-sdk bundle validate"
    operator-sdk bundle validate ./bundle && green "OK" || { red "Bundle validation failed"; failed=1; }
  fi
  if command -v kube-linter >/dev/null; then
    step "kube-linter (config/catalog)"
    kube-linter lint config/catalog/ && green "OK" || yellow "kube-linter warnings (non-fatal)"
  fi
  if command -v yamllint >/dev/null; then
    step "yamllint"
    yamllint -d '{extends: relaxed, rules: {line-length: disable}}' config/ bundle/ && green "OK" || yellow "yamllint warnings (non-fatal)"
  fi

  [[ $failed -eq 0 ]] || die "quality gates failed - fix the issues above (or use --skip-checks at your own risk)"
  green "All quality gates passed"
}

# ---------- commands ----------------------------------------------------------

cmd_build() {
  local ship=$1 new_version=$2 skip_checks=$3 version_override=$4

  local version
  version=$(current_version)
  [[ -n "$version" ]] || die "could not read VERSION from Makefile"

  if [[ "$new_version" == true && -n "$version_override" ]]; then
    die "use either --new-version or an explicit version, not both"
  fi

  if [[ "$new_version" == true ]]; then
    local bumped
    bumped=$(bump_patch "$version")
    set_version "$version" "$bumped"
    version=$bumped
  elif [[ -n "$version_override" ]]; then
    [[ "$version_override" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must be X.Y.Z (got: $version_override)"
    if [[ "$version_override" != "$version" ]]; then
      set_version "$version" "$version_override"
      version=$version_override
    fi
  fi

  local img="docker.io/fumbles/k8sgames:v${version}"
  local bundle_img="docker.io/fumbles/k8sgames-bundle:v${version}"

  step "Building k8sgames v${version}"
  echo "  app image:    ${img}"
  echo "  bundle image: ${bundle_img}"
  echo "  ship to Docker Hub: ${ship}"

  if [[ "$skip_checks" == true ]]; then
    yellow "Skipping quality gates (--skip-checks)"
  else
    run_checks
  fi

  if [[ "$ship" == true ]]; then
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
      yellow "WARNING: shipping with uncommitted changes in the working tree"
    fi
    local catalog_img="docker.io/fumbles/k8sgames-catalog:v${version}"
    step "Building + pushing multi-arch app image (linux/amd64, linux/arm64)"
    make docker-buildx VERSION="$version" IMG="$img"
    step "Building + pushing multi-arch bundle image"
    make bundle-buildx VERSION="$version" BUNDLE_IMG="$bundle_img"
    step "Building + pushing multi-arch catalog image (file-based catalog)"
    make catalog-buildx VERSION="$version" BUNDLE_IMG="$bundle_img" CATALOG_IMG="$catalog_img"
    step "Shipped"
    green "  ${img}"
    green "  ${bundle_img}"
    green "  ${catalog_img}"
    echo
    echo "Make it installable on a cluster with OLM:"
    echo "  kubectl apply -f config/catalog/catalogsource.yaml"
    echo "  kubectl apply -f config/catalog/operatorgroup.yaml"
    echo "  kubectl apply -f config/catalog/subscription.yaml"
    echo "  kubectl apply -f config/catalog/service.yaml"
    echo "  kubectl apply -f config/catalog/route.yaml"
    echo "Or test just the bundle without a catalog:"
    echo "  operator-sdk run bundle ${bundle_img}"
  else
    step "Building local single-arch app image (use --ship for multi-arch + push)"
    make docker-build VERSION="$version" IMG="$img"
    green "Built ${img} (local only)"
  fi

  if [[ "$new_version" == true ]]; then
    echo
    yellow "Version files changed (Makefile, CSV, catalogsource.yaml)."
    yellow "Commit and tag: git add -A && git commit -m 'k8sgames v${version}' && git tag v${version}"
  fi
}

cmd_clean() {
  step "Cleaning"
  rm -rf bin catalog
  find . -name '*.bak' -delete
  green "Done"
}

usage() {
  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------- main --------------------------------------------------------------

# Container tool: docker or podman (override with CONTAINER_TOOL=...)
if [[ -z "${CONTAINER_TOOL:-}" ]]; then
  if command -v docker >/dev/null 2>&1; then CONTAINER_TOOL=docker
  elif command -v podman >/dev/null 2>&1; then CONTAINER_TOOL=podman
  else die "docker or podman is required but neither is installed"
  fi
fi
export CONTAINER_TOOL

COMMAND=""
SHIP=false
NEW_VERSION=false
SKIP_CHECKS=false
VERSION_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    build|check|clean|help) COMMAND=$arg ;;
    --ship)                 SHIP=true ;;
    --new-version)          NEW_VERSION=true ;;
    --skip-checks)          SKIP_CHECKS=true ;;
    -h|--help)              COMMAND=help ;;
    [0-9]*.[0-9]*.[0-9]*)   VERSION_OVERRIDE=$arg ;;
    *)                      die "unknown argument: $arg (see ./build.sh help)" ;;
  esac
done

case "${COMMAND:-build}" in
  build) cmd_build "$SHIP" "$NEW_VERSION" "$SKIP_CHECKS" "$VERSION_OVERRIDE" ;;
  check) run_checks ;;
  clean) cmd_clean ;;
  help)  usage ;;
esac
