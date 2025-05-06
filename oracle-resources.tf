terraform {
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "6.21.0"
    }
  }
}

provider "oci" {
  tenancy_ocid = var.tenancy_ocid
  user_ocid    = var.user_ocid
  fingerprint  = var.fingerprint
  private_key  = var.private_key
  region       = var.region
}

data "terraform_remote_state" "platform-cloud-oci" {
  backend = "remote"
  config = {
    organization = "anfcorp"
    workspaces = {
      name = "platform-cloud-oci"
    }
  }
}

data "terraform_remote_state" "cpe-oci-platform" {
  backend = "remote"
  config = {
    organization = "anfcorp"
    workspaces = {
      name = "cpe-oci-platform"
    }
  }
}

locals {
  naming             = "${var.team}-${var.app}-${var.env}"
  additional_context = var.additional_context != "" ? "-${var.additional_context}" : ""

  tags = {
    "anf.cost_center"          = var.cost_center
    "anf.app_owner"            = var.app_owner-tag
    "anf.application"          = var.app
    "anf.region"               = var.location
    "anf.business_criticality" = var.criticality
    "anf.environment"          = var.env
    "rbac.use"                 = "EMPS_Administrators"
  }

  compartment_cluster_id = data.terraform_remote_state.cpe-oci-platform.outputs.compartment_ids["${var.compartment_name_cluster}"]
  vcn_id                 = data.terraform_remote_state.platform-cloud-oci.outputs["${var.vcn_output_name}"]
  subnet_api_id          = data.terraform_remote_state.platform-cloud-oci.outputs.subnet_details["${var.api_subnet_name}"]
  subnet_backend_id      = data.terraform_remote_state.platform-cloud-oci.outputs.subnet_details["${var.backend_subnet_name}"]
  subnet_ilb_id          = data.terraform_remote_state.platform-cloud-oci.outputs.subnet_details["${var.ilb_subnet_name}"]
  subnet_lb_id           = data.terraform_remote_state.platform-cloud-oci.outputs.subnet_details["${var.lb_subnet_name}"]
  subnet_node_id         = data.terraform_remote_state.platform-cloud-oci.outputs.subnet_details["${var.node_subnet_name}"]

  node_pools = {
    default = {
      node_shape                   = var.default_node_shape
      ocpus                        = var.default_node_ocpus
      memory_in_gbs                = var.default_node_memory
      size                         = var.default_node_count
      generate_with_default_values = var.default_node_generate_with_default_values
      kube_reserved_cpu            = var.default_node_kube_reserved_cpu
      kube_reserved_memory         = var.default_node_kube_reserved_memory
      system_reserved_cpu          = var.default_node_system_reserved_cpu
      system_reserved_memory       = var.default_node_system_reserved_memory
    }
  }
}

resource "oci_containerengine_cluster" "oke" {
  name               = "${local.naming}-oke${local.additional_context}"
  compartment_id     = local.compartment_cluster_id
  defined_tags       = local.tags
  vcn_id             = local.vcn_id
  kubernetes_version = var.k8s_version
  type               = var.cluster_type

  cluster_pod_network_options {
    cni_type = "FLANNEL_OVERLAY"
  }

  endpoint_config {
    subnet_id = local.subnet_api_id
  }

  options {
    kubernetes_network_config {
      pods_cidr     = var.pods_cidr
      services_cidr = var.services_cidr
    }
  }

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

module "node_config" {
  for_each = local.node_pools
  source   = "./modules/node_config"

  node_pool_ocpus              = each.value["ocpus"]
  node_pool_memory             = each.value["memory_in_gbs"]
  generate_with_default_values = each.value["generate_with_default_values"]
  kube_reserved_cpu            = each.value["kube_reserved_cpu"]
  kube_reserved_memory         = each.value["kube_reserved_memory"]
  system_reserved_cpu          = each.value["system_reserved_cpu"]
  system_reserved_memory       = each.value["system_reserved_memory"]
}

resource "oci_containerengine_node_pool" "node-pools" {
  for_each = local.node_pools

  name               = "${local.naming}-nodes-${each.key}${local.additional_context}"
  compartment_id     = oci_containerengine_cluster.oke.compartment_id
  defined_tags       = local.tags
  cluster_id         = oci_containerengine_cluster.oke.id
  kubernetes_version = var.k8s_version
  node_shape         = each.value["node_shape"]

  node_config_details {
    placement_configs {
      availability_domain = var.availability_domain
      subnet_id           = local.subnet_node_id
      fault_domains       = var.fault_domain
    }

    defined_tags = local.tags

    size = each.value["size"]

    node_pool_pod_network_option_details {
      cni_type = "FLANNEL_OVERLAY"
    }
  }

  node_metadata = module.node_config["${each.key}"] != null ? { user_data = module.node_config["${each.key}"].cloud_init_base64 } : null

  node_shape_config {
    ocpus         = each.value["ocpus"]
    memory_in_gbs = each.value["memory_in_gbs"]
  }

  node_source_details {
    image_id    = var.image_id
    source_type = "IMAGE"
  }

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_kms_vault" "default_vault" {
  #Required
  compartment_id = local.compartment_cluster_id
  display_name   = "${local.naming}-kms${local.additional_context}"
  vault_type     = var.vault_vault_type

  ##Optional
  defined_tags = local.tags

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_artifacts_container_repository" "oci_repository" {
  compartment_id = local.compartment_cluster_id
  display_name   = "${local.naming}-ocir${local.additional_context}"
  defined_tags   = local.tags
  is_immutable   = false
  is_public      = false

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_mount_target" "oke_fs_mount_target" {
  availability_domain = var.availability_domain
  compartment_id      = local.compartment_cluster_id
  subnet_id           = local.subnet_node_id

  display_name = "${local.naming}-mt${local.additional_context}"
  defined_tags = local.tags

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_file_system" "oke_file_system" {
  availability_domain = var.availability_domain
  compartment_id      = local.compartment_cluster_id
  defined_tags        = local.tags
  display_name        = "${local.naming}-oke-fs${local.additional_context}"

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_export" "oke_fs_export" {
  export_set_id  = oci_file_storage_mount_target.oke_fs_mount_target.export_set_id
  file_system_id = oci_file_storage_file_system.oke_file_system.id
  path           = var.fs_export_path

  export_options {
    source          = "0.0.0.0/0"
    access          = "READ_WRITE"
    identity_squash = "NONE"
  }
}

#adding vm

resource "oci_core_instance" "emps-vm" {
  availability_domain = var.availability_domain
  compartment_id      = local.compartment_cluster_id
  fault_domain        = "FAULT-DOMAIN-2"
  shape               = var.instance_shape
  shape_config {
    ocpus         = 2
    memory_in_gbs = 16
  }
  source_details {
    source_id   = "ocid1.image.oc1.iad.aaaaaaaakp5agw5rxfiq6nede7ousfcdfuflfjgsu7bstmnx737ah4ylmu6q"
    source_type = "image"
  }
  display_name = "emps-vm-${var.env}"
  create_vnic_details {
    assign_public_ip = false
    subnet_id        = local.subnet_backend_id
  }
  metadata = {
    ssh_authorized_keys = file("certs/okekey.pub")
  }
  preserve_boot_volume = false
  defined_tags         = local.tags

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_kms_vault" "kms_vault" {
  for_each = toset(var.environments)
  #Required
  compartment_id = local.compartment_cluster_id
  display_name   = each.key
  vault_type     = var.vault_vault_type

  ##Optional
  defined_tags = local.tags

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_file_system" "price-hub" {
  for_each            = toset(var.environments)
  availability_domain = var.availability_domain
  compartment_id      = local.compartment_cluster_id
  defined_tags        = local.tags
  display_name        = "price-hub-${each.key}-fs"

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_export" "price-hub" {
  for_each       = toset(var.environments)
  export_set_id  = oci_file_storage_mount_target.oke_fs_mount_target.export_set_id
  file_system_id = oci_file_storage_file_system.price-hub[each.key].id
  path           = "/price-hub-${each.key}"

  export_options {
    source          = "0.0.0.0/0"
    access          = "READ_WRITE"
    identity_squash = "NONE"
  }
}

resource "oci_file_storage_file_system" "b2b-hub" {
  for_each            = toset(var.environments)
  availability_domain = var.availability_domain
  compartment_id      = local.compartment_cluster_id
  defined_tags        = local.tags
  display_name        = "b2b-hub-${each.key}-fs"

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_export" "b2b-hub" {
  for_each       = toset(var.environments)
  export_set_id  = oci_file_storage_mount_target.oke_fs_mount_target.export_set_id
  file_system_id = oci_file_storage_file_system.b2b-hub[each.key].id
  path           = "/b2b-hub-${each.key}"

  export_options {
    source          = "0.0.0.0/0"
    access          = "READ_WRITE"
    identity_squash = "NONE"
  }
}

resource "oci_file_storage_file_system" "emps" {
  for_each            = toset(var.environments)
  availability_domain = var.availability_domain
  compartment_id      = local.compartment_cluster_id
  defined_tags        = local.tags
  display_name        = "emps-${each.key}-fs"

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_export" "emps" {
  for_each       = toset(var.environments)
  export_set_id  = oci_file_storage_mount_target.oke_fs_mount_target.export_set_id
  file_system_id = oci_file_storage_file_system.emps[each.key].id
  path           = "/emps-${each.key}"

  export_options {
    source          = "0.0.0.0/0"
    access          = "READ_WRITE"
    identity_squash = "NONE"
  }
}


resource "oci_file_storage_file_system" "ora-ext" {
  for_each            = toset(var.environments)
  availability_domain = var.availability_domain
  compartment_id      = local.compartment_cluster_id
  defined_tags        = local.tags
  display_name        = "ora-ext-${each.key}-fs"

  lifecycle {
    ignore_changes = [
      defined_tags["OPN.OpportunityID"],
      defined_tags["OPN.PartnerID"],
      defined_tags["OPN.Workload"],
      defined_tags["Oracle-Tags.CreatedBy"],
      defined_tags["Oracle-Tags.CreatedOn"]
    ]
  }
}

resource "oci_file_storage_export" "ora-ext" {
  for_each       = toset(var.environments)
  export_set_id  = oci_file_storage_mount_target.oke_fs_mount_target.export_set_id
  file_system_id = oci_file_storage_file_system.ora-ext[each.key].id
  path           = "/ora-ext-${each.key}"

  export_options {
    source          = "0.0.0.0/0"
    access          = "READ_WRITE"
    identity_squash = "NONE"
  }
}
