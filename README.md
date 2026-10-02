# microvm-images

Bootable qcow2 images for [Proxmox microVMs](https://github.com/rcarmo/pve-microvm). GitHub Actions builds the image and publishes the qcow2 on a release. The virtual disk size is the `SIZE` in `image.env`. The compressed file size is only the release download.

The current pin is `docker.io/almalinux/10-init:10.2-20261002`. The release tag is `almalinux-<version>-<commit count>` on `main`.

Copy the qcow2 to a Proxmox directory storage that has the `import` content type, then create the guest. That create allocates the zvol:

```bash
pvesh create /nodes/pve/qemu \
  --vmid 123 --name my-microvm --machine microvm --memory 256 \
  --serial0 socket --vga serial0 \
  --scsi0 local-zfs:0,import-from=local:import/almalinux-10.qcow2
```

The release contains the root qcow2 and `orchestrator-cache.qcow2`, an empty ext4 image labeled `orch-cache`. `oci-to-rootfs.sh` makes the rootfs bootable, `orchestrator-guest.sh` adds the sandbox user and the cache and tools mounts, and `rootfs-to-qcow2.sh` packs the root. `cache-qcow2.sh` packs the cache image. Build locally, as root:

```bash
set -a
source image.env
set +a
rootfs=$(mktemp -d)/rootfs
./oci-to-rootfs.sh --image "$IMAGE" --rootfs "$rootfs"
./orchestrator-guest.sh --rootfs "$rootfs"
./rootfs-to-qcow2.sh --rootfs "$rootfs" --size "$SIZE" --output "$FILENAME"
./cache-qcow2.sh --size "$CACHE_SIZE" --output "$CACHE_FILENAME"
```

`oci-to-qcow2.sh` is the bootable image without the orchestrator guest: the same rootfs prep and one pack.

The boot prep follows the enterprise-Linux path in [pve-microvm-template](https://github.com/rcarmo/pve-microvm/blob/main/tools/pve-microvm-template): NetworkManager DHCP, a serial console on `ttyS0` that autologins as root, OpenSSH, cloud-init, and the QEMU guest agent. The guest script leaves that console in place. SSH allows the `sandbox` user and refuses root. `mise` is installed from the `jdxcode/mise` EPEL 10 COPR at `mise-2026.9.14-1.el10`, and that repo is disabled afterward. `xorriso` packs the language ISO. The cache filesystem label is `orch-cache`, mounted at `/mnt/cache`. The language ISO volume label is `orchestrator-language`, optionally mounted at `/opt/language`; without an ISO, that base-image directory is writable by `sandbox` for language-ISO build jobs. The agents ISO volume label is `orchestrator-agents`, mounted at `/opt/agents`. A missing ISO does not fail boot. The session-environment oneshot waits for the optional language mount attempt, writes `/etc/environment` from `/usr/lib/orchestrator/environment`, and appends `/opt/language/environment` when present. If that file contains `PATH`, the base `PATH` assignment is removed first so SSH receives the ISO-generated value rather than a duplicate. It also applies `/opt/language/caches.json` when present, creating cache directories under `/mnt/cache` and linking corresponding paths under `/home/sandbox`.
