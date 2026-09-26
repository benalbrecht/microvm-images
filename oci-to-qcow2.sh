#!/bin/bash
# Turn an OCI image into a bootable qcow2 for a later microVM import.
# Enterprise Linux rootfs gets the pve-microvm-template boot prep:
# packages, NetworkManager DHCP, serial console, sshd, and qemu-guest-agent.
# No VM is created.

set -euo pipefail

IMAGE=""
SIZE="2G"
OUTPUT=""
ROOTFS_DIR=""

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

for tool in skopeo umoci qemu-img mkfs.ext4 systemctl; do
  command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

if [[ "$IMAGE" != */* ]]; then
  IMAGE="docker.io/library/${IMAGE}"
elif [[ "$IMAGE" == docker.com/* ]]; then
  IMAGE="docker.io/${IMAGE#docker.com/}"
fi

WORKDIR=$(mktemp -d /tmp/pve-oci-to-qcow2.XXXXXX)
PARTIAL="${OUTPUT}.partial"

unmount_rootfs() {
  local rootfs="${ROOTFS_DIR:-}"
  [[ -n "$rootfs" && -d "$rootfs" ]] || return 0
  umount "$rootfs/dev" 2>/dev/null || true
  umount "$rootfs/sys" 2>/dev/null || true
  umount "$rootfs/proc" 2>/dev/null || true
}

cleanup() {
  unmount_rootfs
  rm -rf "$WORKDIR"
  if [[ -n "${PARTIAL:-}" ]]; then
    rm -f "$PARTIAL"
  fi
}
trap cleanup EXIT

is_enterprise_linux_rootfs() {
  local rootfs="$1" ids
  ids=$(awk -F= '/^(ID|ID_LIKE)=/ {
    value=$2
    gsub(/"/, "", value)
    printf "%s ", tolower(value)
  }' "$rootfs/etc/os-release" 2>/dev/null) || return 1
  case " $ids " in
    *" rhel "*|*" centos "*|*" fedora "*|*" rocky "*|*" almalinux "*|*" ol "*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_rootfs_resolver() {
  local rootfs="$1"
  mkdir -p "$rootfs/etc"
  if [[ -L "$rootfs/etc/resolv.conf" || ! -s "$rootfs/etc/resolv.conf" ]]; then
    rm -f "$rootfs/etc/resolv.conf"
    if [[ -s /etc/resolv.conf ]]; then
      cp -L /etc/resolv.conf "$rootfs/etc/resolv.conf"
    else
      echo "nameserver 1.1.1.1" > "$rootfs/etc/resolv.conf"
    fi
  fi
}

configure_guest_agent() {
  local rootfs="$1" qemu_ga=""
  if [[ -x "$rootfs/usr/sbin/qemu-ga" ]]; then
    qemu_ga="/usr/sbin/qemu-ga"
  elif [[ -x "$rootfs/usr/bin/qemu-ga" ]]; then
    qemu_ga="/usr/bin/qemu-ga"
  else
    die "qemu-guest-agent is installed but qemu-ga was not found"
  fi

  mkdir -p "$rootfs/etc/systemd/system"
  rm -f "$rootfs/etc/systemd/system/microvm-agent.service"
  rm -f "$rootfs/etc/systemd/system/multi-user.target.wants/microvm-agent.service"
  rm -f "$rootfs/etc/systemd/system/qemu-guest-agent.service"
  rm -rf "$rootfs/etc/systemd/system/qemu-guest-agent.service.d"
  cat > "$rootfs/etc/systemd/system/qemu-guest-agent.service" <<EOF
[Unit]
Description=QEMU Guest Agent for microVM
After=local-fs.target

[Service]
Type=simple
ExecStart=/bin/sh -c 'i=0; while test \$i -lt 60; do test -c /dev/vport1p1 && exec ${qemu_ga} --method=virtio-serial --path=/dev/vport1p1; i=\$((i + 1)); sleep 1; done; exit 1'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

prepare_enterprise_linux_rootfs() {
  local rootfs="$1" pkg_cmd pkgs
  for dir in proc sys dev dev/pts run tmp sbin; do
    mkdir -p "$rootfs/$dir"
  done
  ensure_rootfs_resolver "$rootfs"

  mount --bind /proc "$rootfs/proc"
  mount --bind /sys "$rootfs/sys"
  mount --bind /dev "$rootfs/dev"

  if [[ -f "$rootfs/usr/bin/dnf" ]]; then
    pkg_cmd="dnf"
  elif [[ -f "$rootfs/usr/bin/microdnf" ]]; then
    pkg_cmd="microdnf"
  elif [[ -f "$rootfs/usr/bin/tdnf" ]]; then
    pkg_cmd="tdnf"
  elif [[ -f "$rootfs/usr/bin/yum" ]]; then
    pkg_cmd="yum"
  else
    die "enterprise Linux rootfs has no dnf, microdnf, tdnf, or yum"
  fi

  pkgs="iproute NetworkManager systemd cloud-init util-linux openssh-server qemu-guest-agent"
  chroot "$rootfs" /bin/bash -c "$pkg_cmd install -y $pkgs"

  install -d -m 700 "$rootfs/etc/NetworkManager/system-connections"
  cat > "$rootfs/etc/NetworkManager/system-connections/microvm-dhcp.nmconnection" <<'EOF'
[connection]
id=microvm-dhcp
type=ethernet
autoconnect=true

[ipv4]
method=auto

[ipv6]
method=auto
EOF
  chmod 600 "$rootfs/etc/NetworkManager/system-connections/microvm-dhcp.nmconnection"

  cat > "$rootfs/etc/systemd/system/microvm-console.service" <<'EOF'
[Unit]
Description=microvm serial console
After=systemd-user-sessions.service

[Service]
ExecStart=-/sbin/agetty --autologin root --noclear ttyS0 linux
Restart=always
RestartSec=0
Type=idle

[Install]
WantedBy=multi-user.target
EOF

  [[ -f "$rootfs/etc/shadow" ]] || die "rootfs has no /etc/shadow"
  sed -i 's|^root:[^:]*:|root::|' "$rootfs/etc/shadow"

  configure_guest_agent "$rootfs"
  chroot "$rootfs" /bin/bash -c "$pkg_cmd clean all"

  systemctl --root="$rootfs" enable NetworkManager.service
  systemctl --root="$rootfs" disable serial-getty@ttyS0.service || true
  systemctl --root="$rootfs" enable microvm-console.service
  systemctl --root="$rootfs" enable sshd.service
  systemctl --root="$rootfs" enable qemu-guest-agent.service
  systemctl --root="$rootfs" unmask systemd-udevd.service systemd-udev-trigger.service
  systemctl --root="$rootfs" enable systemd-udevd.service systemd-udev-trigger.service


  unmount_rootfs
}

OCI_DIR="${WORKDIR}/oci"
BUNDLE_DIR="${WORKDIR}/bundle"
ROOTFS_DIR="${BUNDLE_DIR}/rootfs"
RAW_IMAGE="${WORKDIR}/disk.raw"

skopeo copy "docker://${IMAGE}" "oci:${OCI_DIR}:latest"
umoci unpack --image "${OCI_DIR}:latest" "$BUNDLE_DIR"

is_enterprise_linux_rootfs "$ROOTFS_DIR" \
  || die "boot prep is implemented for enterprise Linux rootfs only"
prepare_enterprise_linux_rootfs "$ROOTFS_DIR"

truncate -s "$SIZE" "$RAW_IMAGE"
mkfs.ext4 -F -L microvm-root -d "$ROOTFS_DIR" "$RAW_IMAGE"
mkdir -p "$(dirname "$OUTPUT")"
qemu-img convert -f raw -O qcow2 "$RAW_IMAGE" "$PARTIAL"
mv -f "$PARTIAL" "$OUTPUT"
PARTIAL=""
