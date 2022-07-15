# Follow the steps below to generate couchbase-data-api ami
# 1. cp .env.example .env
# 2. Update .env with appropriate values
# 3. source .env
# 4. AWS_PROFILE=<AMI Profile Name> packer build couchbase-data-api.pkr.hcl

variable "region" {
  type = string
}

variable "product_name" {
  type = string
}

variable "product_version" {
  type = string
}

variable "product_bld_num" {
  type = string
}

variable "ami_name" {
  type = string
}

variable "product_platform" {
  type = string
}

variable "product_arch" {
  type = string
}

locals {
  process-exporter_version = "v0.7.5"
  process-exporter_package = "process-exporter_0.7.5_linux_arm64"
  node_exporter_version = "v1.1.2"
  node_exporter_package = "node_exporter-1.1.2.linux-arm64"

  ## The dp service that is being put on the image.
  dp_service = "dp-serverless"

  ## The user to use for starting the service
  service_user = "dataapi"
}

source "amazon-ebs" "cc" {
  ami_name      = "${var.ami_name}"
  instance_type = "t4g.micro"
  region        = "${var.region}"
  // No permission to create SG on stage, have to use an existing SG
  //security_group_id = "sg-082125705b63f8216"
  source_ami_filter {
    filters = {
      name                = "amzn2-ami-hvm-2.0.*-arm64-gp2"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }
  tags = {
    service     = "${var.product_name}"
  }
  snapshot_tags = {
    service     = "${var.product_name}"
  }
  ssh_username = "ec2-user"
}

# a build block invokes sources and runs provisioning steps on them.
build {
  sources = ["source.amazon-ebs.cc"]

  provisioner "file" {
    destination = "/tmp/"
    source      = "${local.dp_service}.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${local.dp_service}.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${var.product_name}.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "${var.product_name}_${var.product_version}-${var.product_bld_num}-${var.product_platform}.${var.product_arch}.tar.gz"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "node-exporter.service"
  }

  provisioner "file" {
    destination = "/tmp/"
    source      = "process-exporter.service"
  }
  provisioner "file" {
    destination = "/tmp/journald.conf"
    source = "journald.conf"
  }

  provisioner "file" {
   destination = "/tmp/iptables-firewall.sh"
   source = "iptables-firewall.sh"
  }

  provisioner "file" {
   destination = "/tmp/dp-firewall.service"
   source = "dp-firewall.service"
  }

  provisioner "shell" {
    inline = [
      "sleep 10",
      "sudo mv /tmp/journald.conf /etc/systemd/journald.conf",
      "sudo chown root:root /etc/systemd/journald.conf",
      "sudo chmod 755 /etc/systemd/journald.conf",
      // Create user
      "sudo useradd -d /home/${local.service_user} -m ${local.service_user}",
      "sudo chown -R ${local.service_user}:${local.service_user} /home/${local.service_user}",
      "sudo mv /tmp/${var.product_name}.service /lib/systemd/system/${var.product_name}.service",
      "sudo tar -xzf /tmp/${var.product_name}_${var.product_version}-${var.product_bld_num}-${var.product_platform}.${var.product_arch}.tar.gz -C /home/${local.service_user}",
      "sudo chown -R ${local.service_user}:${local.service_user} /home/${local.service_user}",
      "sudo chmod +x /home/${local.service_user}/rest-server",
      "sudo systemctl enable ${var.product_name}.service",
      "sudo rm /tmp/${var.product_name}_${var.product_version}-${var.product_bld_num}-${var.product_platform}.${var.product_arch}.tar.gz",
      // Install and start node exporter
      "sudo wget https://github.com/prometheus/node_exporter/releases/download/${local.node_exporter_version}/${local.node_exporter_package}.tar.gz -P /tmp/",
      "sudo tar xvfz /tmp/${local.node_exporter_package}.tar.gz -C /tmp",
      "sudo rm /tmp/${local.node_exporter_package}.tar.gz",
      "sudo mv /tmp/${local.node_exporter_package}/node_exporter /home/ec2-user/node_exporter",
      "sudo chown ec2-user:ec2-user /home/ec2-user/node_exporter",
      "sudo mv /tmp/node-exporter.service /lib/systemd/system/node-exporter.service",
      "sudo systemctl enable node-exporter.service",
      // Install and enable process exporter
      "sudo wget https://github.com/ncabatoff/process-exporter/releases/download/${local.process-exporter_version}/${local.process-exporter_package}.rpm -P /tmp/",
      "sudo rpm --install /tmp/${local.process-exporter_package}.rpm",
      "sudo rm /tmp/${local.process-exporter_package}.rpm",
      "sudo mv /tmp/process-exporter.service /lib/systemd/system/process-exporter.service",
      "sudo systemctl enable process-exporter.service",
      // Install and enable dp_service
      "sudo mv /tmp/${local.dp_service}.service /lib/systemd/system/${local.dp_service}.service",
      "sudo mv /tmp/${local.dp_service}.gz /home/ec2-user",
      "sudo gunzip /home/ec2-user/${local.dp_service}.gz",
      "sudo chmod +x /home/ec2-user/${local.dp_service}",
      "sudo systemctl enable ${local.dp_service}.service",
      // Install firewall service
      "sudo mv /tmp/dp-firewall.service /lib/systemd/system/dp-firewall.service",
      "sudo mv /tmp/iptables-firewall.sh /home/ec2-user",
      "sudo chmod +x /home/ec2-user/iptables-firewall.sh",
      "sudo chown root:root /home/ec2-user/iptables-firewall.sh",
      "sudo systemctl start dp-firewall.service",
      "sudo systemctl enable dp-firewall.service"
    ]
  }
}
