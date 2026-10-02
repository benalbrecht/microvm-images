#!/bin/bash
# Add the orchestrator guest to a boot-prepped rootfs. Does not pack a qcow2.
# Leaves the serial console as a root autologin. SSH is the sandbox user.

set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: $0 --rootfs PATH" >&2
  exit 2
}

die() {
  echo "orchestrator-guest: $*" >&2
  exit 1
}

[[ $# -eq 2 && "$1" == --rootfs && -n "$2" ]] || usage
ROOTFS="$2"
[[ "$(id -u)" -eq 0 ]] || die "must run as root"
[[ -d "$ROOTFS/etc" ]] || die "rootfs has no /etc: $ROOTFS"
[[ -f "$ROOTFS/etc/cloud/cloud.cfg" ]] || die "rootfs has no cloud-init; run the boot prep first"
[[ -x "$ROOTFS/usr/bin/dnf" ]] || die "rootfs is not the pinned AlmaLinux image"
grep -q '^sandbox:' "$ROOTFS/etc/passwd" && die "rootfs already has user sandbox"

unmount_rootfs() {
  for mountpoint in dev sys proc; do
    umount "$ROOTFS/$mountpoint" 2>/dev/null || true
  done
}

# Boot prep already configured DNS; chrooted DNF needs these kernel interfaces.
trap unmount_rootfs EXIT

for dir in proc sys dev; do
  mkdir -p "$ROOTFS/$dir"
done
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"
mount --bind /dev "$ROOTFS/dev"

# Runtime tools support Git-based language caches; Python applies cache maps;
# xorriso builds language ISOs inside the guest.
# nodejs is runtime for various agents, so we install it on the base image
chroot "$ROOTFS" /usr/bin/dnf install -y git python3 'dnf-command(copr)' xorriso nodejs24
# mise comes from this pinned COPR; disable the repo afterward to avoid drift.
chroot "$ROOTFS" /usr/bin/dnf -y copr enable jdxcode/mise
chroot "$ROOTFS" /usr/bin/dnf install -y mise-2026.9.14-1.el10
chroot "$ROOTFS" /usr/bin/dnf -y copr disable jdxcode/mise
chroot "$ROOTFS" /usr/bin/dnf clean all
# The sandbox account runs SSH jobs; Git sees mounted/shared worktrees as safe.
chroot "$ROOTFS" useradd --create-home --home-dir /home/sandbox --shell /bin/bash --user-group sandbox
chroot "$ROOTFS" git config --system --add safe.directory '*'
unmount_rootfs
trap - EXIT

# Keep the home private and let each cloned VM generate its own SSH host keys.
chmod 700 "$ROOTFS/home/sandbox"
rm -f "$ROOTFS"/etc/ssh/ssh_host_*

install -d -m 755 "$ROOTFS/mnt/cache" "$ROOTFS/opt/language" "$ROOTFS/opt/agents" \
  "$ROOTFS/usr/local/libexec" "$ROOTFS/etc/ssh/sshd_config.d" \
  "$ROOTFS/etc/cloud/cloud.cfg.d" \
  "$ROOTFS/etc/systemd/system" \
  "$ROOTFS/etc/systemd/system/sshd.service.d"
chroot "$ROOTFS" chown sandbox:sandbox /opt/language
# The cache-map helper is run from the boot service when an ISO provides a map.
install -m 755 "$SCRIPT_DIR/orchestrator-cache-maps.py" \
  "$ROOTFS/usr/local/libexec/orchestrator-cache-maps"

cat > "$ROOTFS/etc/systemd/system/sshd.service.d/orchestrator-session-env.conf" <<'EOF'
[Unit]
Requires=orchestrator-session-env.service
After=orchestrator-session-env.service
EOF

cat > "$ROOTFS/etc/ssh/sshd_config.d/00-sandbox.conf" <<'EOF'
# SSH is key-only and sandbox-only; remote forwarding is used for guest access.
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
# Cloud-init must not recreate root access or enable password-based SSH.
cat > "$ROOTFS/etc/cloud/cloud.cfg.d/00-sandbox.cfg" <<'EOF'
disable_root: true
ssh_pwauth: false
EOF

cat > "$ROOTFS/usr/local/libexec/orchestrator-mount-cache" <<'EOF'
#!/bin/bash
# Wait briefly for the separately attached cache volume, then mount it for
# package-manager caches. Read-only cold attempts must remain usable as such.
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
# Publish environment and cache links before SSH sessions. The ISO is optional;
# its generated environment and cache map are consumed as data, never executed.
set -euo pipefail
base=/usr/lib/orchestrator/environment
[[ -f "$base" ]] || exit 1
language_environment=/opt/language/environment
tmp=$(mktemp /etc/environment.XXXXXX)
if [[ -f "$language_environment" ]]; then
  # SSH used the base PATH when both assignments were present; keep one PATH.
  if grep -q '^PATH=' "$language_environment"; then
    awk '!/^PATH=/' "$base" > "$tmp"
  else
    cat "$base" > "$tmp"
  fi
  printf '\n' >> "$tmp"
  cat "$language_environment" >> "$tmp"
else
  cat "$base" > "$tmp"
fi
chmod 644 "$tmp"
mv -f "$tmp" /etc/environment
/usr/bin/python3 /usr/local/libexec/orchestrator-cache-maps
EOF
chmod 755 "$ROOTFS/usr/local/libexec/orchestrator-session-env"

cat > "$ROOTFS/etc/systemd/system/orchestrator-session-env.service" <<'EOF'
[Unit]
Description=Publish orchestrator session environment
# Wait for the optional language ISO mount and cache mount before publishing it.
Wants=opt-language.mount
After=local-fs.target orchestrator-cache.service opt-language.mount
Before=sshd.socket

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
# These ISOs are removable inputs; absence must not prevent boot.
fstab_iso orchestrator-language /opt/language
fstab_iso orchestrator-agents /opt/agents

# Keep a minimal base environment; the session service appends ISO values.
install -d -m 755 "$ROOTFS/usr/lib/orchestrator"
base_env="$ROOTFS/usr/lib/orchestrator/environment"
printf '%s\n' 'PATH=/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin' > "$base_env"
install -m 644 "$base_env" "$ROOTFS/etc/environment"
