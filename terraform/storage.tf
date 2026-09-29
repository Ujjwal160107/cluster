# S8 (docs/plans/2026-09-27-architecture-review.md §17 S8, step 1): the one authoritative volume
# for class-A data.
#
# STATUS 2026-09-28 (corrected by CLEAN-002 — this comment described a plan, not the state): the
# volume EXISTS, is attached, is mounted at `/srv/data` by the Ansible `data_volume` role (which is
# written and applied — not "not yet written" as this comment used to say), and holds the vcap and
# meghmitra datasets as static hostPath PVs. `k8s/platform/storage/` declares those PVs.
#
# The two legacy CSI volumes (106574315 staging, 106574316 dev) also still exist: retiring them was
# conditional on apps being retired, and that decision was answered "do not retire" (D-3), so they
# stay. Their PVs are `Released`/`Retain` and their underlying data is not managed here.
#
# `automount = false` deliberately — the role mounts by `/dev/disk/by-id/...`, not the
# cloud-init/Hetzner automount mechanism, and it refuses to `mkfs` a populated volume.
#
# ⚠️ `format` is create-time only and the volume now exists: do NOT change it. A change would be an
# attempt to replace the volume, which `prevent_destroy` blocks — a plan error rather than data loss,
# but there is no version of this field that is safe to edit on a live volume.
resource "hcloud_volume" "vps_data" {
  name              = "vps-data"
  size              = 20
  server_id         = hcloud_server.vps.id
  automount         = false
  format            = "ext4"
  delete_protection = true

  lifecycle {
    prevent_destroy = true
  }
}

output "vps_data_volume_id" {
  value = hcloud_volume.vps_data.id
}

output "vps_data_linux_device" {
  value = hcloud_volume.vps_data.linux_device
}
