
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.12.0"
    }
  }
}

provider "azurerm" {
   features {}
}

data "azurerm_client_config" "current" {
}

data "azurerm_subscription" "current" {
}

data "terraform_remote_state" "pdns_workspace" {
  backend = "remote"
  config  = {
    organization = "anfcorp"               
    workspaces   = {
      name       = "platform-privatedns" 
    }
  }
}

data "terraform_remote_state" "gr_workspace" {
  backend = "remote"
  config  = {
    organization = "anfcorp"               
    workspaces   = {
      name       = "${var.gr_workspace}"
    }
  }
}

locals {
  naming  = "${var.app_owner}-${var.app}"
  acr_name = var.acr_name != "" ?  var.acr_name : "anf${var.app}${var.env}acr"
  tags = {
    anf-app_owner  = "${var.app_owner}"
    anf-application = "${var.app}"
    anf-region = "${var.location}"
    anf-environment = "${var.env}"
    anf-provisioned_by = "terraform"
    anf-cost_center = "${var.cost_center}"
    anf-business_criticality = "${var.business_criticality}"
    anf-department_code = "${var.anf-department_code}"
}
}

resource "azurerm_resource_group" "kube" {
  name     = "${local.naming}-${var.env}-rg-aks"
  location = var.location
  tags     = local.tags
}

resource "azurerm_resource_group" "main" {
  name     = "${local.naming}-${var.env}-rg"
  location = var.location
  tags     = local.tags
}

resource "azurerm_user_assigned_identity" "aks-identity" {
  resource_group_name = azurerm_resource_group.kube.name
  location            = var.location
  name                = "${local.naming}-${var.env}-mi-aks"
  tags                = local.tags
}



module  "privateaks" {
  source                  = "app.terraform.io/anfcorp/aks/azurerm"
  version                 = "0.0.11"
  naming                  = "${local.naming}-${var.env}"
  location                = var.location
  resource_group          = azurerm_resource_group.kube.name
  aks_identity            = [azurerm_user_assigned_identity.aks-identity.id]
  k8s_version             = var.k8s_version
  private_dns_zone_id     = data.terraform_remote_state.pdns_workspace.outputs.eus2_aks_dns_zone
  defaultpool_nodes_count = var.k8s_defaultpool_nodes_count
  vm_size                 = var.k8s_defaultpool_vm_size
  subnet_id               = data.terraform_remote_state.gr_workspace.outputs.subnet_id[0]
  routetable_scope        = data.terraform_remote_state.gr_workspace.outputs.subnet_id[0]
  vnet_scope              = data.terraform_remote_state.gr_workspace.outputs.spoke_vnet_id[0]
  admin_group_ids         = values(var.admin_groups)
  aad_enabled             = var.aad_enabled
  zones                   = var.zones
  only_critical_addons_enabled = var.only_critical_addons_enabled
  
  tags       = local.tags
  depends_on = [azurerm_role_assignment.pdns-contributor]
}

resource "azurerm_role_assignment" "net-contributor" {
  role_definition_name = "Network Contributor"
  scope                = data.terraform_remote_state.gr_workspace.outputs.spoke_vnet_id[0]
  principal_id         = azurerm_user_assigned_identity.aks-identity.principal_id
  depends_on = [azurerm_user_assigned_identity.aks-identity]
}

resource "azurerm_role_assignment" "routetable-contributor" {
  role_definition_name = "Network Contributor"
  scope                = data.terraform_remote_state.gr_workspace.outputs.rt_id[1]
  principal_id         = azurerm_user_assigned_identity.aks-identity.principal_id
  depends_on = [azurerm_user_assigned_identity.aks-identity]
}

resource "azurerm_role_assignment" "pdns-contributor" {
  role_definition_name = "Private DNS Zone Contributor"
  scope                = data.terraform_remote_state.pdns_workspace.outputs.eus2_aks_dns_zone
  principal_id         = azurerm_user_assigned_identity.aks-identity.principal_id
  depends_on = [azurerm_user_assigned_identity.aks-identity]
}

resource "azurerm_role_assignment" "aks-cluster-user" {
  for_each = var.app_team_groups
    role_definition_name = "Azure Kubernetes Service Cluster User Role"
    scope                = azurerm_resource_group.kube.id
    principal_id         = each.value
}

resource "azurerm_role_assignment" "aks-rbac-reader" {
  for_each = var.app_team_groups
    role_definition_name = "Azure Kubernetes Service RBAC Reader"
    scope                = azurerm_resource_group.kube.id
    principal_id         = each.value
}

resource "azurerm_role_assignment" "aks-cluster-user-admins" {
  for_each = var.admin_groups
    role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
    scope                = azurerm_resource_group.kube.id
    principal_id         = each.value
}

resource "azurerm_role_assignment" "aks-cluster-user-rbac-admins" {
  for_each = var.admin_groups
    role_definition_name = "Azure Kubernetes Service RBAC Cluster Admin"
    scope                = azurerm_resource_group.kube.id
    principal_id         = each.value
}

module "aks_acr" {
   count = var.create_acr ? 1 : 0
   source  = "app.terraform.io/anfcorp/azure-container-registry/azurerm"
   version = "0.0.7"
   acr_name             = local.acr_name
   resource_group       = azurerm_resource_group.kube.name
   location             = var.location
   replication_location = var.paired_location
   subnet_id            = data.terraform_remote_state.gr_workspace.outputs.subnet_id[1]
   psc_name             = "${local.naming}-${var.env}-acr_psc"
   admin_enabled        = false
   tags                 = local.tags
}

resource "azurerm_role_assignment" "aks-acrpull" {
  role_definition_name = "AcrPull"
  scope                = var.create_acr ? module.aks_acr[0].acr_id : var.existing_acr_id
  principal_id         = module.privateaks.kube_ident
  depends_on           = [module.privateaks, module.aks_acr]
  skip_service_principal_aad_check = true
}

resource "azurerm_role_assignment" "aks-app-acrpull" {
  role_definition_name = "AcrPush"
  scope                = var.create_acr ? module.aks_acr[0].acr_id : var.existing_acr_id
  principal_id         = var.app_team_id
  depends_on           = [module.aks_acr]
}

resource "azurerm_kubernetes_cluster_node_pool" "application" {
  name                  = "app"
  kubernetes_cluster_id = module.privateaks.id
  vm_size               = var.k8s_apppool_vm_size
  node_count            = var.k8s_apppool_nodes_count
  tags                  = local.tags
  zones                 = var.zones
  orchestrator_version  = var.k8s_version
  vnet_subnet_id        = data.terraform_remote_state.gr_workspace.outputs.subnet_id[0]
  lifecycle {
    create_before_destroy = true
  }
}

 



resource "azurerm_storage_account" "fpa-storage-account" {
  name                     = "anf${var.app}${var.env}st01"
  resource_group_name      = azurerm_resource_group.main.name
  location                 = azurerm_resource_group.main.location
  account_tier                = "Standard"
  account_replication_type    = "GRS"
  account_kind                = "StorageV2"
  network_rules {
    default_action = "Deny"
    ip_rules       = concat(["65.210.129.0/24","8.25.72.0/24","8.21.99.0/24","208.255.29.0/24","207.87.192.0/24","209.31.93.0/24","207.238.212.32/27","207.158.142.0/24","125.215.169.0/27","58.246.138.88/29","80.69.5.40/29","80.69.5.200/30","80.69.5.204/30","52.230.60.128/28","52.139.246.200/29","149.173.186.6","149.173.184.24"])
    bypass         = ["Logging", "Metrics", "AzureServices"]
  }
  tags = local.tags

  lifecycle {
    ignore_changes = all
    
  }
}



resource "azurerm_private_endpoint" "fpa-storage-pe" {
  name                = "${local.naming}-${var.env}-pe-sa"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = data.terraform_remote_state.gr_workspace.outputs.subnet_id[1]

  private_service_connection {
    name                           = "${local.naming}-${var.env}-pe-sa"
    private_connection_resource_id = azurerm_storage_account.fpa-storage-account.id
    subresource_names              = ["file"]
    is_manual_connection           = false
  }

  tags = local.tags

  lifecycle {
      ignore_changes = [private_dns_zone_group]
  }

}

resource "azurerm_role_assignment" "storage-account-contributor" {
    role_definition_name = "Storage Account Contributor"
    scope                = azurerm_resource_group.main.id
    principal_id         = var.app_team_id
}

// Keyvaults
module "keyvault" {
  for_each = toset(var.namespace_envs)
  source  = "app.terraform.io/anfcorp/keyvault-module/azurerm"
  version = "=1.1.1"
  app                 = var.app
  resource_group_name = azurerm_resource_group.main.name
  location            = var.location
  policy = []
  subnet_id           = data.terraform_remote_state.gr_workspace.outputs.subnet_id[1]
  additionalcontext   = var.additionalcontext
  tenant_id           = data.azurerm_client_config.current.tenant_id
  pe_name             = "${local.naming}-${each.key}"
  kv_name             = "${local.naming}-${each.key}"
  psc_name            = "${local.naming}-${each.key}"

  tags = local.tags
}

resource "azurerm_key_vault_access_policy" "main" {
  for_each = toset(var.namespace_envs)
  key_vault_id = module.keyvault[each.key].kv_id
  tenant_id = data.azurerm_client_config.current.tenant_id
  object_id = var.app_team_id

  certificate_permissions = [
    "Backup", "Create", "Delete", "DeleteIssuers", "Get", "GetIssuers", "Import", "List", "ListIssuers", "ManageContacts", "ManageIssuers", "Purge", "Recover", "Restore", "SetIssuers", "Update"
  ]

  key_permissions = [
    "Backup", "Create", "Decrypt", "Delete", "Encrypt", "Get", "Import", "List", "Purge", "Recover", "Restore", "Sign", "UnwrapKey", "Update", "Verify", "WrapKey"
  ]

  secret_permissions = [
    "Backup", "Delete", "Get", "List", "Purge", "Recover", "Restore", "Set"
  ]

  storage_permissions = [
    "Backup", "Delete", "DeleteSAS", "Get", "GetSAS", "List", "ListSAS", "Purge", "Recover", "RegenerateKey", "Restore", "Set", "SetSAS", "Update"
  ]
}


resource "azurerm_role_assignment" "kv-app-contributor" {
  for_each = toset(var.namespace_envs)
  role_definition_name = "Key Vault Administrator"
  scope                = module.keyvault[each.key].kv_id
  principal_id         = var.app_team_id
  depends_on           = [module.keyvault]
}
