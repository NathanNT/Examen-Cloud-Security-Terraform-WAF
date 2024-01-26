provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "myRG" {
  name     = "myRG_KCR_NTL_PCH"
  location = "East US"
}

resource "azurerm_virtual_network" "myVNet" {
  name                = "myVNet_KCR_NTL_PCH"
  address_space       = ["10.21.0.0/16"]
  location            = azurerm_resource_group.myRG.location
  resource_group_name = azurerm_resource_group.myRG.name
}

resource "azurerm_subnet" "myAGSubnet" {
  name                 = "myAGSubnet"
  resource_group_name  = azurerm_resource_group.myRG.name
  virtual_network_name = azurerm_virtual_network.myVNet.name
  address_prefixes     = ["10.21.0.0/24"]
}

resource "azurerm_subnet" "myBackendSubnet" {
  name                 = "myBackendSubnet"
  resource_group_name  = azurerm_resource_group.myRG.name
  virtual_network_name = azurerm_virtual_network.myVNet.name
  address_prefixes     = ["10.21.1.0/24"]
}

resource "azurerm_public_ip" "myAGPublicIPAddress" {
  name                = "myAGPublicIPAddress"
  location            = azurerm_resource_group.myRG.location
  resource_group_name = azurerm_resource_group.myRG.name
  allocation_method   = "Static"
  sku                 = "Standard"
}


resource "azurerm_linux_virtual_machine" "myVM" {
  count               = 2
  name                = "myVM${count.index + 1}KCRNTLPCH"
  resource_group_name = azurerm_resource_group.myRG.name
  location            = azurerm_resource_group.myRG.location
  size                = "Standard_DS1_v2"
  disable_password_authentication = false
  admin_username      = "kcrntlpch"
  admin_password      = "kfej2499OD!é&"
  network_interface_ids = [element(azurerm_network_interface.myVM_nic.*.id, count.index)]
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }
  source_image_reference {
    offer                 = "0001-com-ubuntu-server-focal"
    publisher             = "Canonical"
    sku                   = "20_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(<<EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install -y nginx
  EOF
  )
}

resource "azurerm_network_interface" "myVM_nic" {
  count               = 2
  name                = "myVM${count.index + 1}NIC"
  location            = azurerm_resource_group.myRG.location
  resource_group_name = azurerm_resource_group.myRG.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.myBackendSubnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

output "vm_private_ips" {
  value = azurerm_network_interface.myVM_nic.*.ip_configuration.0.private_ip_address
}

# Création passerelle d'application
resource "azurerm_application_gateway" "myAppGateway" {
  name                = "myAppGateway"
  resource_group_name = azurerm_resource_group.myRG.name
  location            = azurerm_resource_group.myRG.location

  # Précision du type de passerelle en WAF 
  sku {
    name     = "WAF_v2"
    tier     = "WAF_v2"
    capacity = 2
  }

  gateway_ip_configuration {
    name      = "myGatewayConfig"
    subnet_id = azurerm_subnet.myAGSubnet.id
  }

  frontend_ip_configuration {
    name                 = "myFrontendIPConfig"
    public_ip_address_id = azurerm_public_ip.myAGPublicIPAddress.id
  }

  frontend_port {
    name = "httpPort"
    port = 80
  }

  backend_address_pool {
    name = "myBackendAddressPool"
    ip_addresses = azurerm_network_interface.myVM_nic.*.ip_configuration.0.private_ip_address
  }

  backend_http_settings {
    name                  = "httpSettings"
    cookie_based_affinity = "Disabled"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 20
  }

  http_listener {
    name                           = "listener"
    frontend_ip_configuration_name = "myFrontendIPConfig"
    frontend_port_name             = "httpPort"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "rule1"
    rule_type                  = "Basic"
    http_listener_name         = "listener"
    backend_address_pool_name  = "myBackendAddressPool"
    backend_http_settings_name = "httpSettings"
    priority                   = 100
  }
  # Configuration du WAF
  waf_configuration {
    enabled           = true
    firewall_mode     = "Prevention"
    rule_set_type     = "OWASP"
    rule_set_version  = "3.2"
    disabled_rule_group {
        rule_group_name = "REQUEST-930-APPLICATION-ATTACK-LFI"
        rules           = ["930100", "930110"]
    }
  }
}


resource "azurerm_storage_account" "storage" {
  name                     = "kcrntlpcstorage"
  resource_group_name      = azurerm_resource_group.myRG.name
  location                 = azurerm_resource_group.myRG.location
  account_tier             = "Standard"
  account_replication_type = "GRS"

  tags = {
    environment = "Terraform Demo"
  }
}

resource "azurerm_log_analytics_workspace" "law" {
  name                = "KCRNTLPCHWorkspace"
  location            = azurerm_resource_group.myRG.location
  resource_group_name = azurerm_resource_group.myRG.name
  sku                 = "PerGB2018"
}


data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "example" {
  name                       = "KCRNTLPCHkeyvault"
  location                   = azurerm_resource_group.myRG.location
  resource_group_name        = azurerm_resource_group.myRG.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  soft_delete_retention_days = 7
  sku_name                   = "standard"
}


resource "azurerm_monitor_diagnostic_setting" "diagnostics" {
  name                       = "KCRNTLPCHDiagnostics"
  target_resource_id         = azurerm_key_vault.example.id
  storage_account_id         = azurerm_storage_account.storage.id

  log {
    category_group = "allLogs"
    enabled  = true

    retention_policy {
      enabled = false
    }
  }

  metric {
    category = "AllMetrics"
    enabled  = true

    retention_policy {
      enabled = false
    }
  }
}