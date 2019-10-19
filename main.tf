terraform {
  required_version = ">= 0.12"
}

provider "libvirt" {
  uri = "qemu:///system"
}

variable "prefix" {
  default = "terraform_example"
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/network.markdown
resource "libvirt_network" "example" {
  name = var.prefix
  mode = "nat"
  domain = "example.test"
  addresses = ["10.17.3.0/24"]
  dhcp {
    enabled = false
  }
}

# create a cloud-init cloud-config.
# NB this creates an iso image that will be used by the NoCloud cloud-init datasource.
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/cloudinit.html.markdown
# see journactl -u cloud-init
# see /run/cloud-init/*.log
# see https://cloudinit.readthedocs.io/en/latest/topics/examples.html#disk-setup
# see https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html#datasource-nocloud
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/v0.6.0/libvirt/cloudinit_def.go#L133-L162
resource "libvirt_cloudinit_disk" "example_cloudinit" {
  name = "${var.prefix}_example_cloudinit.iso"
  user_data = <<EOF
#cloud-config
users:
  - name: vagrant
    passwd: '$6$rounds=4096$NQ.EmIrGxn$rTvGsI3WIsix9TjWaDfKrt9tm3aa7SX7pzB.PSjbwtLbsplk1HsVzIrZbXwQNce6wmeJXhCq9YFJHDx9bXFHH.'
    lock_passwd: false
    ssh-authorized-keys:
      - ${file("~/.ssh/id_rsa.pub")}
disk_setup:
  /dev/sdb:
    table_type: mbr
    layout:
      - [100, 83]
    overwrite: false
fs_setup:
  - label: data
    device: /dev/sdb1
    filesystem: ext4
    overwrite: false
mounts:
  - [/dev/sdb1, /data, ext4, 'defaults,discard,nofail', '0', '2']
runcmd:
  - sed -i '/vagrant insecure public key/d' /home/vagrant/.ssh/authorized_keys
EOF
}

# this uses the vagrant ubuntu image imported from https://github.com/rgl/ubuntu-vagrant.
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/volume.html.markdown
resource "libvirt_volume" "example_root" {
  name = "${var.prefix}_root.img"
  base_volume_name = "ubuntu-18.04-amd64_vagrant_box_image_0.img"
  format = "qcow2"
  size = 66*1024*1024*1024 # 66GiB. this root FS is automatically resized by cloud-initramfs-growroot (included in the rgl/ubuntu-vagrant image).
}

# a data disk.
# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/volume.html.markdown
resource "libvirt_volume" "example_data" {
  name = "${var.prefix}_data.img"
  format = "qcow2"
  size = 6*1024*1024*1024 # 6GiB.
}

# see https://github.com/dmacvicar/terraform-provider-libvirt/blob/master/website/docs/r/domain.html.markdown
resource "libvirt_domain" "example" {
  name = var.prefix
  cpu = {
    mode = "host-passthrough"
  }
  vcpu = 2
  memory = 1024
  qemu_agent = true
  cloudinit = libvirt_cloudinit_disk.example_cloudinit.id
  disk {
    volume_id = libvirt_volume.example_root.id
    scsi = true
  }
  disk {
    volume_id = libvirt_volume.example_data.id
    scsi = true
  }
  network_interface {
    network_id = libvirt_network.example.id
    wait_for_lease = true
    hostname = "example"
    addresses = ["10.17.3.2"]
  }
  provisioner "remote-exec" {
    inline = [
      <<-EOF
      id
      uname -a
      cat /etc/os-release
      echo "machine-id is $(cat /etc/machine-id)"
      lsblk -x KNAME -o KNAME,SIZE,TRAN,SUBSYSTEMS,FSTYPE,UUID,LABEL,MODEL,SERIAL
      mount | grep ^/dev
      df -h
      EOF
    ]
    connection {
      type = "ssh"
      user = "vagrant"
      host = self.network_interface[0].addresses[0]
      private_key = file("~/.ssh/id_rsa")
    }
  }
}

output "ip" {
  value = libvirt_domain.example.network_interface[0].addresses[0]
}