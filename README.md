# microvm-images

Bootable qcow2 images for [Proxmox microVMs](https://github.com/rcarmo/pve-microvm). GitHub Actions builds the image and publishes the qcow2 on a release. The virtual disk size is the `SIZE` in `image.env`. The compressed file size is only the release download.

The current pin is `docker.io/almalinux/10-init:10.2-20260902`. The release tag is `almalinux-<version>-<commit count>` on `main`.

Copy the qcow2 to a Proxmox directory storage that has the `import` content type, then create the guest. That create allocates the zvol:

```bash
pvesh create /nodes/pve/qemu \
  --vmid 123 --name my-microvm --machine microvm --memory 256 \
  --serial0 socket --vga serial0 \
  --scsi0 local-zfs:0,import-from=local:import/almalinux-10.qcow2
```

Build locally, as root:

```bash
set -a
source image.env
set +a
./oci-to-qcow2.sh --image "$IMAGE" --size "$SIZE" --output "$FILENAME"
```

The rootfs prep follows the enterprise-Linux path in [pve-microvm-template](https://github.com/rcarmo/pve-microvm/blob/main/tools/pve-microvm-template): NetworkManager DHCP, a serial console on `ttyS0`, OpenSSH, and the QEMU guest agent.
