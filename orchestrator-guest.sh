#!/bin/bash
# Add the orchestrator guest to a boot-prepped rootfs. Does not pack a qcow2.
# Leaves the serial console as a root autologin. SSH is the sandbox user.

set -euo pipefail

ROOTFS=""
ROOTFS_DIR=""

usage() {
  echo "usage: $0 --rootfs PATH" >&2
  exit 2
}

die() {
  echo "orchestrator-guest: $*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rootfs) ROOTFS="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$ROOTFS" ]] || usage
[[ "$(id -u)" -eq 0 ]] || die "must run as root"
[[ -d "$ROOTFS/etc" ]] || die "rootfs has no /etc: $ROOTFS"
[[ -f "$ROOTFS/etc/cloud/cloud.cfg" ]] || die "rootfs has no cloud-init; run the boot prep first"
grep -q '^sandbox:' "$ROOTFS/etc/passwd" && die "rootfs already has user sandbox"

unmount_rootfs() {
  local rootfs="${ROOTFS_DIR:-}"
  [[ -n "$rootfs" && -d "$rootfs" ]] || return 0
  umount "$rootfs/dev" 2>/dev/null || true
  umount "$rootfs/sys" 2>/dev/null || true
  umount "$rootfs/proc" 2>/dev/null || true
}

trap unmount_rootfs EXIT
ROOTFS_DIR="$ROOTFS"

pkg_cmd() {
  local rootfs="$1"
  if [[ -f "$rootfs/usr/bin/dnf" ]]; then
    echo dnf
  elif [[ -f "$rootfs/usr/bin/microdnf" ]]; then
    echo microdnf
  elif [[ -f "$rootfs/usr/bin/tdnf" ]]; then
    echo tdnf
  elif [[ -f "$rootfs/usr/bin/yum" ]]; then
    echo yum
  else
    die "rootfs has no dnf, microdnf, tdnf, or yum"
  fi
}

set_kv() {
  local file="$1" key="$2" value="$3"
  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
  fi
}

for dir in proc sys dev dev/pts; do
  mkdir -p "$ROOTFS/$dir"
done
if [[ -L "$ROOTFS/etc/resolv.conf" || ! -s "$ROOTFS/etc/resolv.conf" ]]; then
  rm -f "$ROOTFS/etc/resolv.conf"
  if [[ -s /etc/resolv.conf ]]; then
    cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
  else
    echo "nameserver 1.1.1.1" > "$ROOTFS/etc/resolv.conf"
  fi
fi
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev"

cmd=$(pkg_cmd "$ROOTFS")
chroot "$ROOTFS" /bin/bash -c "$cmd install -y git python3 'dnf-command(copr)' xorriso"
# Pinned EPEL 10 build from jdxcode/mise. The repo is not left enabled.
chroot "$ROOTFS" /bin/bash -c "dnf -y copr enable jdxcode/mise"
chroot "$ROOTFS" /bin/bash -c "dnf install -y mise-2026.9.14-1.el10"
chroot "$ROOTFS" /bin/bash -c "dnf -y copr disable jdxcode/mise"
chroot "$ROOTFS" /bin/bash -c "$cmd clean all"
chroot "$ROOTFS" useradd --create-home --home-dir /home/sandbox --shell /bin/bash --user-group sandbox
chroot "$ROOTFS" git config --system --add safe.directory '*'
unmount_rootfs
trap - EXIT

chmod 700 "$ROOTFS/home/sandbox"
rm -f "$ROOTFS"/etc/ssh/ssh_host_*

install -d -m 755 "$ROOTFS/mnt/cache" "$ROOTFS/opt/language" "$ROOTFS/opt/agents" \
  "$ROOTFS/usr/local/libexec" "$ROOTFS/etc/ssh/sshd_config.d" \
  "$ROOTFS/etc/cloud/cloud.cfg.d" \
  "$ROOTFS/etc/systemd/system"

cat > "$ROOTFS/etc/ssh/sshd_config.d/00-sandbox.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers sandbox
AllowTcpForwarding remote
GatewayPorts no
EOF

cfg="$ROOTFS/etc/cloud/cloud.cfg"
if ! grep -Eq '^[[:space:]]*name:[[:space:]]*"?cloud-user"?[[:space:]]*$' "$cfg"; then
  die "cloud.cfg default user is not cloud-user"
fi
sed -i -E 's/^([[:space:]]*name:[[:space:]]*)"?cloud-user"?/\1sandbox/' "$cfg"
sed -i -E '/^[[:space:]]*sudo:/d' "$cfg"
grep -Eq '^[[:space:]]*name:[[:space:]]*sandbox[[:space:]]*$' "$cfg" \
  || die "cloud.cfg default user was not updated"
cat > "$ROOTFS/etc/cloud/cloud.cfg.d/00-sandbox.cfg" <<'EOF'
disable_root: true
ssh_pwauth: false
EOF

cat > "$ROOTFS/usr/local/libexec/orchestrator-mount-cache" <<'EOF'
#!/bin/bash
# The cache disk is writable. Mount read-only only when the device itself is.
# The filesystem label is orch-cache. ext4 labels are 16 bytes.
set -euo pipefail
dev=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  dev=$(blkid -L orch-cache || true)
  [[ -n "$dev" ]] && break
  sleep 1
done
if [[ -z "$dev" ]]; then
  echo "orchestrator-mount-cache: no filesystem labeled orch-cache" >&2
  exit 1
fi
echo "orchestrator-mount-cache: orch-cache on $dev"
mkdir -p /mnt/cache
if ! findmnt -n /mnt/cache >/dev/null 2>&1; then
  opts=rw
  if [[ "$(blockdev --getro "$dev")" == 1 ]]; then
    opts=ro
  fi
  mount -o "$opts" "$dev" /mnt/cache
fi
[[ "$(blockdev --getro "$dev")" == 1 ]] && exit 0
chown sandbox:sandbox /mnt/cache
chmod 755 /mnt/cache
EOF
chmod 755 "$ROOTFS/usr/local/libexec/orchestrator-mount-cache"

cat > "$ROOTFS/etc/systemd/system/orchestrator-cache.service" <<'EOF'
[Unit]
Description=Mount orchestrator cache
After=local-fs.target
Before=sshd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/orchestrator-mount-cache

[Install]
WantedBy=multi-user.target
EOF
systemctl --root="$ROOTFS" enable orchestrator-cache.service

cat > "$ROOTFS/usr/local/libexec/orchestrator-session-env" <<'EOF'
#!/bin/bash
# Publish /etc/environment before sshd. The image file is the base. The
# language ISO may add a dotenv. Cache directories are the /mnt/cache paths
# named on that ISO, outside installs and bin. This script copies files and
# creates those directories. It does not run mise.
set -euo pipefail
base=/usr/lib/orchestrator/environment
[[ -f "$base" ]] || exit 1
tmp=$(mktemp)
cat "$base" > "$tmp"
if [[ -f /opt/language/environment ]]; then
  printf '\n' >> "$tmp"
  cat /opt/language/environment >> "$tmp"
fi
chmod 644 "$tmp"
mv -f "$tmp" /etc/environment
if findmnt -n /mnt/cache >/dev/null 2>&1 && [[ -d /opt/language ]]; then
  while IFS= read -r dir; do
    [[ -z "$dir" || "$dir" == *..* ]] && continue
    mkdir -p -- "$dir"
    chown sandbox:sandbox -- "$dir"
    chmod 755 -- "$dir"
    parent=$(dirname -- "$dir")
    while [[ "$parent" == /mnt/cache/* ]]; do
      chown sandbox:sandbox -- "$parent"
      chmod 755 -- "$parent"
      parent=$(dirname -- "$parent")
    done
  done < <(find /opt/language \
      \( -path /opt/language/installs -o -path /opt/language/bin \) -prune \
      -o -type f -print0 |
    while IFS= read -r -d '' file; do
      grep -h -I -oE '/mnt/cache/[A-Za-z0-9._/-]+' "$file" || true
    done | sort -u)
fi
EOF
chmod 755 "$ROOTFS/usr/local/libexec/orchestrator-session-env"

cat > "$ROOTFS/etc/systemd/system/orchestrator-session-env.service" <<'EOF'
[Unit]
Description=Publish orchestrator session environment
After=local-fs.target orchestrator-cache.service
Before=sshd.service sshd.socket

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/libexec/orchestrator-session-env

[Install]
WantedBy=multi-user.target
EOF
systemctl --root="$ROOTFS" enable orchestrator-session-env.service

fstab_iso() {
  local label="$1" mountpoint="$2"
  if ! grep -q "LABEL=${label} " "$ROOTFS/etc/fstab"; then
    printf '%s\n' "LABEL=${label} ${mountpoint} iso9660 ro,nofail,x-systemd.device-timeout=10 0 0" \
      >> "$ROOTFS/etc/fstab"
  fi
}
fstab_iso orchestrator-language /opt/language
fstab_iso orchestrator-agents /opt/agents

install -d -m 755 "$ROOTFS/usr/lib/orchestrator"
base_env="$ROOTFS/usr/lib/orchestrator/environment"
touch "$base_env"
set_kv "$base_env" PATH "/opt/language/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin"
cp "$base_env" "$ROOTFS/etc/environment"
