#!/bin/bash
# Bootable qcow2 only: unpack, apply the microVM boot prep, and pack once.
# The release image runs orchestrator-guest.sh on the rootfs before the pack.

set -euo pipefail

IMAGE=""
SIZE="2G"
OUTPUT=""
WORKDIR=""

usage() {
  echo "usage: $0 --image REF --output PATH [--size 2G]" >&2
  exit 2
}

die() {
  echo "oci-to-qcow2: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image) IMAGE="${2:-}"; shift 2 ;;
    --size) SIZE="${2:-}"; shift 2 ;;
    --output) OUTPUT="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$IMAGE" && -n "$OUTPUT" ]] || usage

here=$(cd "$(dirname "$0")" && pwd)
WORKDIR=$(mktemp -d /tmp/oci-to-qcow2.XXXXXX)
trap 'rm -rf "$WORKDIR"' EXIT

"$here/oci-to-rootfs.sh" --image "$IMAGE" --rootfs "$WORKDIR/rootfs"
"$here/rootfs-to-qcow2.sh" --rootfs "$WORKDIR/rootfs" --size "$SIZE" --output "$OUTPUT"
