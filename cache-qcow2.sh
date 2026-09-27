#!/bin/bash
# Empty ext4 image. The filesystem label is orchestrator-cache.

set -euo pipefail

SIZE="10G"
OUTPUT=""
WORKDIR=""
PARTIAL=""

usage() {
  echo "usage: $0 --output PATH [--size 1G]" >&2
  exit 2
}

die() {
  echo "cache-qcow2: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --size) SIZE="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$OUTPUT" ]] || usage
[[ "$(id -u)" -eq 0 ]] || die "must run as root"

for tool in qemu-img mkfs.ext4 truncate; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

cleanup() {
  if [[ -n "${PARTIAL:-}" ]]; then
    rm -f "$PARTIAL"
  fi
  rm -rf "$WORKDIR"
}

WORKDIR=$(mktemp -d /tmp/cache-qcow2.XXXXXX)
PARTIAL="${OUTPUT}.partial"
trap cleanup EXIT

RAW_IMAGE="${WORKDIR}/disk.raw"
truncate -s "$SIZE" "$RAW_IMAGE"
mkfs.ext4 -F -L orchestrator-cache "$RAW_IMAGE"
mkdir -p "$(dirname "$OUTPUT")"
qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$PARTIAL"
mv -f "$PARTIAL" "$OUTPUT"
PARTIAL=""
