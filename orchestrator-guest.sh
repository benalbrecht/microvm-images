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
chroot "$ROOTFS" /bin/bash -c "$cmd install -y git 'dnf-command(copr)'"
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
  "$ROOTFS/etc/cloud/cloud.cfg.d" "$ROOTFS/etc/clojure" "$ROOTFS/etc/maven" \
  "$ROOTFS/etc/systemd/system"

cat > "$ROOTFS/etc/ssh/sshd_config.d/00-sandbox.conf" <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers sandbox
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
# The hypervisor opens the cache read-only for attempts and writable for a warm.
set -euo pipefail
dev=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  dev=$(blkid -L orchestrator-cache || true)
  [[ -n "$dev" ]] && break
  sleep 1
done
[[ -n "$dev" ]] || exit 0
mkdir -p /mnt/cache
if findmnt -n /mnt/cache >/dev/null 2>&1; then
  exit 0
fi
opts=rw
if [[ "$(blockdev --getro "$dev")" == 1 ]]; then
  opts=ro
fi
mount -o "$opts" "$dev" /mnt/cache
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

fstab_iso() {
  local label="$1" mountpoint="$2"
  if ! grep -q "LABEL=${label} " "$ROOTFS/etc/fstab"; then
    printf '%s\n' "LABEL=${label} ${mountpoint} iso9660 ro,nofail,x-systemd.device-timeout=10 0 0" \
      >> "$ROOTFS/etc/fstab"
  fi
}
fstab_iso orchestrator-language /opt/language
fstab_iso orchestrator-agents /opt/agents

touch "$ROOTFS/etc/environment"
set_kv "$ROOTFS/etc/environment" PATH "/opt/language/bin:/usr/local/bin:/usr/bin:/usr/local/sbin:/usr/sbin"
set_kv "$ROOTFS/etc/environment" GITLIBS /mnt/cache/gitlibs
set_kv "$ROOTFS/etc/environment" CLJ_CONFIG /etc/clojure
set_kv "$ROOTFS/etc/environment" MAVEN_ARGS "-s /etc/maven/settings.xml"

cat > "$ROOTFS/etc/clojure/deps.edn" <<'EOF'
{:mvn/local-repo "/mnt/cache/m2"}
EOF

cat > "$ROOTFS/etc/maven/settings.xml" <<'EOF'
<settings>
  <localRepository>/mnt/cache/m2</localRepository>
</settings>
EOF
