#!/bin/bash
# Pack a prepared rootfs into one qcow2. The filesystem label is microvm-root.

set -euo pipefail

ROOTFS=""
SIZE="2G"
OUTPUT=""
WORKDIR=""
PARTIAL=""

usage() {
  echo "usage: $0 --rootfs PATH --output PATH [--size 2G]" >&2
  exit 2
}

die() {
  echo "rootfs-to-qcow2: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rootfs) ROOTFS="${2:-}"; shift 2 ;;
    --size) SIZE="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$ROOTFS" && -n "$OUTPUT" ]] || usage
[[ "$(id -u)" -eq 0 ]] || die "must run as root"
[[ -d "$ROOTFS/etc" ]] || die "rootfs has no /etc: $ROOTFS"

for tool in qemu-img mkfs.ext4; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

cleanup() {
  if [[ -n "${PARTIAL:-}" ]]; then
    rm -f "$PARTIAL"
  fi
  rm -rf "$WORKDIR"
}

WORKDIR=$(mktemp -d /tmp/rootfs-to-qcow2.XXXXXX)
PARTIAL="${OUTPUT}.partial"
trap cleanup EXIT

RAW_IMAGE="${WORKDIR}/disk.raw"
truncate -s "$SIZE" "$RAW_IMAGE"
mkfs.ext4 -F -L microvm-root -d "$ROOTFS" "$RAW_IMAGE"
mkdir -p "$(dirname "$OUTPUT")"
qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$PARTIAL"
mv -f "$PARTIAL" "$OUTPUT"
PARTIAL=""
