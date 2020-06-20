# Configure the Microsoft Azure Provider
data "azurerm_subscription" "current" {}
data "azurerm_subscription" "primary" {}
data "azurerm_subscription" "subscription" {}
provider "azurerm" {
  version = "=2.15.0"
  features {}
}

# Generate random number
resource "random_integer" "ri" {
  min = 000
  max = 999
}

locals {
  # Ids for multiple vm.
  base_computer_name = "centos7${random_integer.ri.result}"
}

# Create a resource group if it doesn’t exist
resource "azurerm_resource_group" "terraformrg" {
    name     = "${var.resourcegroup_name}"
    location = "${var.location}"

    tags = {
        environment = "Terraform Deployment"
    }
}

# Create virtual network
resource "azurerm_virtual_network" "terraformvnet" {
    name                = "terraformvnet"
    address_space       = ["10.100.0.0/16"]
    location            = "${var.location}"
    resource_group_name = "${azurerm_resource_group.terraformrg.name}"

    tags = {
        environment = "Terraform Deployment"
    }
}

# Create subnet
resource "azurerm_subnet" "terraformvnetserversubnet" {
    name                 = "serversubnet"
    resource_group_name  = "${azurerm_resource_group.terraformrg.name}"
    virtual_network_name = "${azurerm_virtual_network.terraformvnet.name}"
    address_prefixes     = ["10.100.1.0/24"]
}

# Create public IPs
resource "azurerm_public_ip" "terraformpip" {
    name                         = "${local.base_computer_name}-PIP"
    location                     = "${var.location}"
    resource_group_name          = "${azurerm_resource_group.terraformrg.name}"
    allocation_method            = "Static"

    tags = {
        environment = "Terraform Deployment"
    }
}

# Create Network Security Group and rule
resource "azurerm_network_security_group" "terraformnsg" {
    name                = "terraformnsg"
    location            = "${var.location}"
    resource_group_name = "${azurerm_resource_group.terraformrg.name}"

    security_rule {
        name                       = "SSH"
        priority                   = 1001
        direction                  = "Inbound"
        access                     = "Allow"
        protocol                   = "Tcp"
        source_port_range          = "*"
        destination_port_range     = "22"
        source_address_prefix      = "*"
        destination_address_prefix = "*"
    }

    tags = {
        environment = "Terraform Deployment"
    }
}

resource "azurerm_network_security_rule" "newssh" {
    name                        = "ssh2022"
    priority                    = 1002
    direction                   = "Inbound"
    access                      = "Allow"
    protocol                    = "Tcp"
    source_port_range           = "*"
    destination_port_range      = "2022"
    source_address_prefix       = "*"
    destination_address_prefix  = "*"
    resource_group_name         = "${azurerm_resource_group.terraformrg.name}"
    network_security_group_name = "${azurerm_network_security_group.terraformnsg.name}"
}

# Create network interface
resource "azurerm_network_interface" "terraformnic" {
    name                      = "${local.base_computer_name}-NIC"
    location                  = "${var.location}"
    resource_group_name       = "${azurerm_resource_group.terraformrg.name}"
    # network_security_group_id = "${azurerm_network_security_group.terraformnsg.id}"

    ip_configuration {
        name                          = "myNicConfiguration"
        subnet_id                     = "${azurerm_subnet.terraformvnetserversubnet.id}"
        private_ip_address_allocation = "Dynamic"
        public_ip_address_id          = "${azurerm_public_ip.terraformpip.id}"
    }

    tags = {
        environment = "Terraform Deployment"
    }
}

resource "azurerm_network_interface_security_group_association" "newssh_to_tfnic" {
  network_interface_id      = azurerm_network_interface.terraformnic.id
  network_security_group_id = azurerm_network_security_group.terraformnsg.id
}

# Generate random text for a unique storage account name
resource "random_id" "randomId" {
    keepers = {
        # Generate a new ID only when a new resource group is defined
        resource_group = "${azurerm_resource_group.terraformrg.name}"
    }
    byte_length = 8
}

# Create storage account for boot diagnostics
resource "azurerm_storage_account" "diagstorage99" {
    name                        = "diag${random_id.randomId.hex}"
    resource_group_name         = "${azurerm_resource_group.terraformrg.name}"
    location                    = "${var.location}"
    account_tier                = "Standard"
    account_replication_type    = "LRS"

    tags = {
        environment = "Terraform Deployment"
    }
}

# Create virtual machine
resource "azurerm_virtual_machine" "centos7" {
    name                  = local.base_computer_name
    location              = "${var.location}"
    resource_group_name   = "${azurerm_resource_group.terraformrg.name}"
    network_interface_ids = ["${azurerm_network_interface.terraformnic.id}"]
    vm_size               = "${var.vm_size}"

    storage_os_disk {
        name              = "${local.base_computer_name}-osdisk"
        caching           = "ReadOnly"
        create_option     = "FromImage"
        managed_disk_type = "Premium_LRS"
    }

    storage_image_reference {
        publisher = "OpenLogic"
        offer     = "CentOS"
        sku       = "7.0"
        version   = "latest"
        # id = "${data.azurerm_image.managed_image.id}"
    }

    os_profile {
        computer_name  = local.base_computer_name
        admin_username = "${var.ssh_username}"
        admin_password = "${var.ssh_password}"
    }

    os_profile_linux_config {
        disable_password_authentication = true
        ssh_keys {
            path     = "/home/${var.ssh_username}/.ssh/authorized_keys"
            key_data = file("~/.ssh/id_rsa.pub")
        }
    }

    boot_diagnostics {
        enabled = "true"
        storage_uri = "${azurerm_storage_account.diagstorage99.primary_blob_endpoint}"
    }

    identity {
    type = "SystemAssigned"
    }

    tags = {
        environment = "Terraform Deployment"
    }
}

resource "azurerm_role_assignment" "terraformrg" {
  scope              = "${azurerm_resource_group.terraformrg.id}"
  role_definition_name = "Contributor"
  principal_id       = "${lookup(azurerm_virtual_machine.centos7.identity[0], "principal_id")}"
}

  // copy our example script to the server
output "public_ip_address" {
  value = "${azurerm_public_ip.terraformpip.ip_address}"
}
