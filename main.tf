
locals {
  vpc_id           = data.ibm_is_vpc.vpc.id
  name             = "${var.vpc_name}-openvpn"
  attachment_count = var.subnet_count * var.instance_count
  tmp_attachments  = tolist(setproduct([module.openvpn-server.maintenance_security_group_id], var.instance_network_ids))
  attachments      = [for val in local.tmp_attachments: {security_group_id = val[0], network_interface_id = val[1]}]
}

resource null_resource print-vpc_name {
  provisioner "local-exec" {
    command = "echo 'VPC name: ${var.vpc_name}'"
  }
}

# get the information about the existing vpc instance
data ibm_is_vpc vpc {
  depends_on = [null_resource.print-vpc_name]

  name           = var.vpc_name
}

module "openvpn-server" {
  source = "github.com/cloud-native-toolkit/terraform-vsi-bastion.git?ref=v1.6.0"

  resource_group_id    = var.resource_group_id
  region               = var.region
  ibmcloud_api_key     = var.ibmcloud_api_key
  vpc_name             = var.vpc_name
  vpc_subnet_count     = var.subnet_count
  vpc_subnets          = var.subnets
  image_name           = var.image_name
  profile_name         = var.profile_name
  ssh_key_id           = var.ssh_key_id
  kms_key_crn          = var.kms_key_crn
  kms_enabled          = var.kms_enabled
  init_script          = file("${path.module}/scripts/instance-init.sh")
  create_public_ip     = true
  allow_ssh_from       = var.allow_ssh_from
  tags                 = var.tags
  label                = "vpn"
  allow_deprecated_image = var.allow_deprecated_image
  security_group_rules = concat(var.security_group_rules, [
    {
      name      = "openvpn"
      direction = "inbound"
      remote    = "0.0.0.0/0"
      udp = {
        port_min = 1194
        port_max = 1194
      }
    },
    {
      name      = "outbound-http"
      direction = "outbound"
      remote    = "0.0.0.0/0"
      tcp = {
        port_min = 80
        port_max = 80
      }
    },
    {
      name      = "outbound-https"
      direction = "outbound"
      remote    = "0.0.0.0/0"
      tcp = {
        port_min = 443
        port_max = 443
      }
    },
    {
      name      = "outbound-internal-ssh"
      direction = "outbound"
      remote    = "10.0.0.0/8"
      tcp = {
        port_min = 22
        port_max = 22
      }
    }
  ])
  base_security_group  = var.base_security_group
}

resource null_resource print_ips {
  provisioner "local-exec" {
    command = "echo 'Public ips: ${join(",",module.openvpn-server.public_ips)}'"
  }
}
  
  resource null_resource print-float_ip {
  provisioner "local-exec" {
    command = "echo ${module.openvpn-server.public_ips} > ${path.module}/scripts/pubip.txt"
  }
}


resource null_resource setup_openvpn {

  count = var.subnet_count
  depends_on = [module.openvpn-server, null_resource.print_ips]

  connection {
    type        = "ssh"
    user        = "root"
    password    = ""
    private_key = var.ssh_private_key
    host        = module.openvpn-server.public_ips[count.index]
  }

  provisioner "file" {
    source      = "${path.module}/scripts/openvpn-config.sh"
    destination = "/usr/local/bin/openvpn-config.sh"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/pubip.txt"
    destination = "/tmp/pubip.txt"
    }
    
  provisioner "remote-exec" {
    inline     = [
      "chmod +x /usr/local/bin/openvpn-config.sh",
      "openvpn-config.sh"
    ]
  }
}

resource ibm_is_security_group_network_interface_attachment under_maintenance {
  count = local.attachment_count

  security_group    = local.attachments[count.index].security_group_id
  network_interface = local.attachments[count.index].network_interface_id
}
