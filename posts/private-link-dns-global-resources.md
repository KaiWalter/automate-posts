Azure [private link / endpoints](https://docs.microsoft.com/en-us/azure/private-link/private-endpoint-overview) allow you to connect resources to your private virtual network and with that - when removing public access - shield resources from being accessed or even attacked from the internet. For most of enterprise mission critical systems I help designing and implementing in the cloud, this kind of locked down environment is a hard requirement.

Private link as a way of restricting access to resources only for a defined range of virtual networks is an additional offering for [service endpoints](https://docs.microsoft.com/en-us/azure/virtual-network/virtual-network-service-endpoints-overview) which I used so far in projects till spring 2020. This [post](https://sameeraman.wordpress.com/2019/10/30/azure-private-link-vs-azure-service-endpoints/) by [Sameera Perera](https://twitter.com/sameera_man) shows the basic differences between these 2 offerings.

When bringing up a new environment I learned that even some resources like Azure Container Registry have a better support for private linking then for service endpoints. Hence I started looking into this other offering to check whether I can achieve a similar or even better behavior.

## TL;DR

1. linking multiple private DNS zones to a virtual network is possible if none or not more than 1 DNS zone has auto registration enabled

2. (as observed) most resource types do not autoregister into the private DNS zone linked to a virtual network anyway -> manual creation of private DNS recordsets is required

3. the private DNS zone name is also the resource name and so (if required) the same private DNS zone name can only be created once in a resource group

---

## target setup<a name="target-setup"></a>

The application is deployed in multiple regions (more than 2) across the globe to allow for a certain degree of autonomous operation or even take over operation if a region is down.

![Cloud network infrastructure this post is based on](https://dev-to-uploads.s3.amazonaws.com/i/gp5351oeyoegwm1h6xit.jpg)

### global resources

Resources that are globally deployed or replicated hold state or configuration data that is relevant throughout all regions:

- Front Door
- API Management
- Cosmos DB (with multi master write)
- Container Registry

### regional resources

Resources that are deployed in individual regions, hold region specific data, process regional data and should be only accessible from within the region:

- Application Gateway to handle ingress from Front Door
- API Management (Gateway)
- AKS cluster
- Storage
- SQL Server
- ServiceBus
- KeyVault

## considerations

### Front Door / Application Gateway

... are just used to control global ingress into regions and have no attachment to this private link / DNS scenario.

### API Management

... can be deployed globally and is linked into `frontend` virtual networks in each region with a dedicated IP address. API Management currently has no affiliation with private link and hence also no way to sensibly bring regional gateway name resolution into private DNS zones. As API gateways are only addressed internally from containers I [feed IP adress / FQDN pairs into K8S `hostaliases`](https://kubernetes.io/docs/concepts/services-networking/add-entries-to-pod-etc-hosts-with-host-aliases/).

### AKS

... setup is based on this [post](https://medium.com/@denniszielke/fully-private-aks-clusters-without-any-public-ips-finally-7f5688411184) courtesy of [Dennis Zielke](https://twitter.com/denzielke).

## challenges

### multiple private DNS zones linked to a virtual network

Creating a single resource and private linking it to a virtual network is pretty straight forward and has docs dedicated to each of these resources e.g. [for Cosmos DB](https://docs.microsoft.com/en-us/azure/cosmos-db/how-to-configure-private-endpoints). To achieve DNS name resolution - without standing up an own custom DNS server or fiddling around with `hosts.` files (which btw would not work e.g. for API Management) - private DNS zones can be used. But: each resource type needs a [dedicated private DNS zone](https://docs.microsoft.com/en-us/azure/private-link/private-endpoint-dns
) to be created and maintained.

In my scenario I created required private DNS zones with in the ARM template used to create the network configuration, immediately linking these zones to the `frontend` and `backend` virtual networks.

```json
...
        "privateZoneNames": {
            "type": "array",
            "defaultValue": [
                "privatelink.database.windows.net",
                "privatelink.vaultcore.azure.net",
                "privatelink.blob.core.windows.net",
                "privatelink.servicebus.windows.net"
            ]
        },
...
        // private DNS zones
        {
            "type": "Microsoft.Network/privateDnsZones",
            "apiVersion": "2018-09-01",
            "name": "[parameters('privateZoneNames')[copyIndex()]]",
            "location": "global",
            "copy": {
                "name": "zonecopy",
                "count": "[length(parameters('privateZoneNames'))]"
            }
        },
        {
            "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
            "apiVersion": "2018-09-01",
            "name": "[concat(parameters('privateZoneNames')[copyIndex()], '/', replace(parameters('privateZoneNames')[copyIndex()],'privatelink.',''),'-',parameters('vnetNameBackend'),'-link')]",
            "location": "global",
            "dependsOn": [
                "[resourceId('Microsoft.Network/privateDnsZones', parameters('privateZoneNames')[copyIndex()])]",
                "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetNameBackend'))]"
            ],
            "properties": {
                "registrationEnabled": false,
                "virtualNetwork": {
                    "id": "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetNameBackend'))]"
                }
            },
            "copy": {
                "name": "zonebackendlinkcopy",
                "count": "[length(parameters('privateZoneNames'))]"
            }
        },
        {
            "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
            "apiVersion": "2018-09-01",
            "name": "[concat(parameters('privateZoneNames')[copyIndex()], '/', replace(parameters('privateZoneNames')[copyIndex()],'privatelink.',''),'-',parameters('vnetNameFrontend'),'-link')]",
            "location": "global",
            "dependsOn": [
                "[resourceId('Microsoft.Network/privateDnsZones', parameters('privateZoneNames')[copyIndex()])]",
                "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetNameFrontend'))]"
            ],
            "properties": {
                "registrationEnabled": false,
                "virtualNetwork": {
                    "id": "[resourceId('Microsoft.Network/virtualNetworks', parameters('vnetNameFrontend'))]"
                }
            },
            "copy": {
                "name": "zonefrontendlinkcopy",
                "count": "[length(parameters('privateZoneNames'))]"
            }
        },
...
```

> Only the DNS zones for the 4 regional resource types are created here for the overall network. Creation of DNS zones for the global resources is covered later.

When creating private endpoints for multiple resources and with that linking multiple private DNS zones to the same virtual network, **auto registration cannot be enabled** on more than one private DNS zone.

> Auto registration for me seems to make sense for automatically registering VMs in other type of scenarios - not so much when handling Azure PaaS resources.

However when auto registration is disabled, you have to create DNS recordsets manually or to script the creation - not saying when it is enabled that resources - at least based on my observations - would necessarily register automatically.

Creating these private DNS recordsets can be achieved by looping through the FQDN entries registered for the created endpoint. These entries look like this e.g. for Azure SQL:

```json
CustomDnsConfigs           : [
                               {
                                 "Fqdn": "my-sqlsvr.database.windows.net",
                                 "IpAddresses": [
                                    "10.2.6.42"
                                 ]
                               }
                             ]
```

This entry needs to be created in a private DNS zone `privatelink.database.windows.net` but without the public domain name `database.windows.net` - hence this domain name suffix needs to be removed before:

```powershell
   $resourceGroup = "resourcegroupfordnszone"
   $globalDnsSuffx = ".database.windows.net"
   $dnsZoneName = "privatelink.database.windows.net"
...
   # get custom DNS entries for endpoint just created
   (Get-AzPrivateEndpoint -Name $privateEndpoint.Name).CustomDnsConfigs | % {
      $recordSetName = $_.Fqdn -replace $globalDnsSuffx, ""
      # remove existing record
      if (Get-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroup -ZoneName $dnsZoneName `
            -Name $recordSetName -RecordType A -ErrorAction SilentlyContinue) {
         Remove-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroup -ZoneName $dnsZoneName `
            -Name $recordSetName -RecordType A
      }
      # create new record
      New-AzPrivateDnsRecordSet -ResourceGroupName $resourceGroup -ZoneName $dnsZoneName `
         -Name $recordSetName `
         -PrivateDnsRecord (New-AzPrivateDnsRecordConfig -IPv4Address $_.IpAddresses[0]) `
         -RecordType A -Ttl 3600
   }
```

### handling DNS entries for global resources with mutliple IP addresses

Creating the DNS entries for the regional resources was possible because the resource names (SQL, KeyVault, Storage, ...) had the region somewhere in the resource name anyway (e.g. fancy-sql-westus, fancy-sql-eastus) and with that providing unique name to IP address mappings.

For global resources there is one name (e.g. fancy-cosmos-global, fancy-cr-global) with an IP address / a set of IP addresses for each private link endpoint created in the regional virtual networks.

For CosmosDB it would result in a list like this:

```text
fancy-cosmos-global                   {10.1.6.17,10.2.6.15}
fancy-cosmos-global.eastus.data       {10.1.6.16,10.2.6.14}
fancy-cosmos-global.westus.data       {10.1.6.15,10.2.6.13}
```

No way for a consuming resources in `backend` or `frontend` network trying to resolve `fancy-cosmos-global.documents.azure.com` or in fact `fancy-cosmos-global.privatelink.documents.azure.com`.

> In my first attempts I failed with the assumption or expectation that somehow the source network would be considered here in the private DNS resolution.

To work around this, one would only need to create a dedicated private DNS zone for each region and feed the entries/IP addresses relevant for this region, but ... as private DNS zone name is also the resource name within a resource group, you can only have one private DNS zone (for a given resource type) in one resource group (until that stage I only had one resource group holding all the network resources including private DNS zones).

Hence I created additional resource groups for private links, endpoints and DNS zones specifically for a region but keep the common resource group for all the private DNS zones where this is not required.

For that I use a similar ARM template to create private DNS zones and link those to the virtual networks:

```json
{
    "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "vnetNameFrontend": {
            "type": "string",
            "defaultValue": "frontend",
            "metadata": {
                "description": "VNet frontend name"
            }
        },
        "vnetNameBackend": {
            "type": "string",
            "defaultValue": "backend",
            "metadata": {
                "description": "VNet backend name"
            }
        },
        "networkResourceGroup": {
            "type": "string",
            "defaultValue": "network",
            "metadata": {
                "description": "network resource group name"
            }
        },
        "privateZoneNames": {
            "type": "array",
            "defaultValue": [
                "privatelink.documents.azure.com",
                "privatelink.azurecr.io"
            ]
        }
    },
    "variables": {
    },
    "resources": [
        // private DNS zones
        {
            "type": "Microsoft.Network/privateDnsZones",
            "apiVersion": "2018-09-01",
            "name": "[parameters('privateZoneNames')[copyIndex()]]",
            "location": "global",
            "copy": {
                "name": "zonecopy",
                "count": "[length(parameters('privateZoneNames'))]"
            }
        },
        {
            "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
            "apiVersion": "2018-09-01",
            "name": "[concat(parameters('privateZoneNames')[copyIndex()], '/', replace(parameters('privateZoneNames')[copyIndex()],'privatelink.',''),'-',parameters('vnetNameBackend'),'-link')]",
            "location": "global",
            "dependsOn": [
                "[resourceId('Microsoft.Network/privateDnsZones', parameters('privateZoneNames')[copyIndex()])]"
            ],
            "properties": {
                "registrationEnabled": false,
                "virtualNetwork": {
                    "id": "[resourceId(parameters('networkResourceGroup'), 'Microsoft.Network/virtualNetworks', parameters('vnetNameBackend'))]"
                }
            },
            "copy": {
                "name": "zoneclusterlinkcopy",
                "count": "[length(parameters('privateZoneNames'))]"
            }
        },
        {
            "type": "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
            "apiVersion": "2018-09-01",
            "name": "[concat(parameters('privateZoneNames')[copyIndex()], '/', replace(parameters('privateZoneNames')[copyIndex()],'privatelink.',''),'-',parameters('vnetNameFrontend'),'-link')]",
            "location": "global",
            "dependsOn": [
                "[resourceId('Microsoft.Network/privateDnsZones', parameters('privateZoneNames')[copyIndex()])]"
            ],
            "properties": {
                "registrationEnabled": false,
                "virtualNetwork": {
                    "id": "[resourceId(parameters('networkResourceGroup'), 'Microsoft.Network/virtualNetworks', parameters('vnetNameFrontend'))]"
                }
            },
            "copy": {
                "name": "zonebackendlinkcopy",
                "count": "[length(parameters('privateZoneNames'))]"
            }
        }
    ]
}
```

### putting it all together

I placed the create endpoint & maintain DNS entries in a common function (PowerShell module) as it was called for several resources.

```PowerShell
function Update-PrivateLink {
   param (
      [string]$locationCode,
      [string]$resourceName,
      [string]$resourceId,
      [string]$groupId
   )

   # mapping from https://docs.microsoft.com/en-us/azure/private-link/private-endpoint-dns
   # list of groupIds / sub resources https://docs.microsoft.com/en-us/azure/private-link/private-endpoint-overview#private-link-resource

   # place DNS entries for global resources in location specific resource group private DNS zone to allow dedicated assignment to local VNETs
   $dnsZoneResourceGroupName = "network-common"
   $linkPrefix = $resourceName
   switch ($groupId) {
      # global resources have regional resource groups for private DNS zones -----------
      "registry" {
         $globalDnsSuffx = ".azurecr.io"
         $dnsZoneName = "privatelink.azurecr.io"
         $dnsZoneResourceGroupName = "network-" + $locationCode
         $linkPrefix = $resourceName + "-" + $locationCode
      }
      "Sql" {
         $globalDnsSuffx = ".documents.azure.com"
         $dnsZoneName = "privatelink.documents.azure.com"
         $dnsZoneResourceGroupName = "network-" + $locationCode
         $linkPrefix = $resourceName + "-" + $locationCode
      }
      # regional resources are handled with the common network resource group -----------
      "blob" {
         $globalDnsSuffx = ".blob.core.windows.net"
         $dnsZoneName = "privatelink.blob.core.windows.net"
      }
      "namespace" {
         $globalDnsSuffx = ".servicebus.windows.net"
         $dnsZoneName = "privatelink.servicebus.windows.net"
      }
      "sqlServer" {
         $globalDnsSuffx = ".database.windows.net"
         $dnsZoneName = "privatelink.database.windows.net"
      }
      "vault" {
         $globalDnsSuffx = "(.vaultcore.azure.net|.vault.azure.net)"
         $dnsZoneName = "privatelink.vaultcore.azure.net"
      }
      Default {
         throw $("no DNS name mapping defined for groupId:" + $groupId)
      }
   }

   subnetId = "{subnet-id-from-another-magic-function}"

   $subnet = Get-AzVirtualNetworkSubnetConfig `
      -ResourceId $subnetId `
      -ErrorAction Stop

   Write-Host "update private endpoint+DNS for" $resourceName $groupId "to" $subnet.Id

   $privateLink = New-AzPrivateLinkServiceConnection -Name $($linkPrefix + "-link") `
      -PrivateLinkServiceId $resourceId `
      -GroupId $groupId

   $privateEndpoint = New-AzPrivateEndpoint -ResourceGroupName $dnsZoneResourceGroupName `
      -Name $($linkPrefix + "-endpoint") `
      -Location $location.name `
      -Subnet $subnet `
      -PrivateLinkServiceConnection $privateLink `
      -Force

   (Get-AzPrivateEndpoint -Name $privateEndpoint.Name).CustomDnsConfigs | % {
      $recordSetName = $_.Fqdn -replace $globalDnsSuffx, ""
      if (Get-AzPrivateDnsRecordSet -ResourceGroupName $dnsZoneResourceGroupName -ZoneName $dnsZoneName `
            -Name $recordSetName -RecordType A -ErrorAction SilentlyContinue) {
         Remove-AzPrivateDnsRecordSet -ResourceGroupName $dnsZoneResourceGroupName -ZoneName $dnsZoneName `
            -Name $recordSetName -RecordType A
      }
      New-AzPrivateDnsRecordSet -ResourceGroupName $dnsZoneResourceGroupName -ZoneName $dnsZoneName `
         -Name $recordSetName `
         -PrivateDnsRecord (New-AzPrivateDnsRecordConfig -IPv4Address $_.IpAddresses[0]) `
         -RecordType A -Ttl 3600
   }
}
```

This function is called after creation of each of the resource types.

The source of `resourceId` to be passed to the function varies by resource type. It can be `.Id` or `.ResourceId`.

`groupId` passed in is based on this [list](https://docs.microsoft.com/en-us/azure/private-link/private-endpoint-overview#private-link-resource) and refers to the private link service `-GroupId`.

### Storage

```PowerShell
   $storage = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageName -ErrorAction SilentlyContinue
   if ($storage) {
      Update-PrivateLink -locationCode $locationCode `
         -resourceName $storageName -resourceId $storage.Id `
         -groupId "blob"
   }
```

### SQL

```PowerShell
   $sqlServer = Get-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $sqlServerName -ErrorAction SilentlyContinue
   if ($sqlServer) {
      Update-PrivateLink -locationCode $locationCode `
         -resourceName $sqlServerName -resourceId $sqlServer.ResourceId `
         -groupId "sqlServer"

       # can only be set after private endpoint is created
      Set-AzSqlServer -ResourceGroupName $resourceGroupName -ServerName $sqlServerName -PublicNetworkAccess "Disabled"
   }
```

> SQL server resource public network access needs to be enabled when creating the resource and no private endpoints yet defined. It can be switched to disabled after the endpoint creation.

### ServiceBus

```PowerShell
   $sbNamespace = Get-AzServiceBusNamespace -Name $serviceBusNamespaceName -ResourceGroupName $resourceGroupName
   if ($sbNamespace) {
      Update-PrivateLink -locationCode $locationCode `
      -resourceName $($sbNamespace.Name+"-sb") -resourceId $sbNamespace.Id `
      -groupId "namespace"
   }
```

### KeyVault

```PowerShell
   $kv = Get-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroupName -ErrorAction SilentlyContinue
   if ($kv) {
      Update-PrivateLink -locationCode $locationCode `
         -resourceName $keyVaultName -resourceId $kv.ResourceId `
         -groupId "vault"
   }
```

### CosmosDB

For CosmosDB I iterate through an array with all the relevant global locations (which I used before to setup multi master write regions) so that endpoint and DNS entries are created for and in each region.

```PowerShell
   $cosmosDb = Get-AzCosmosDBAccount -ResourceGroupName $resourceGroupName -Name $accountName
   if ($cosmosDb) {
      foreach ($instanceLocationCode in $instanceLocationCodes) {
         Update-PrivateLink -locationCode $instanceLocationCode `
            -resourceName $accountName -resourceId $cosmosDb.Id `
            -groupId "Sql"
      }
   }
```

### Container Registry

Same goes for the 2nd global resource.

```PowerShell
   $acr = Get-AzContainerRegistry -ResourceGroupName $resourceGroupName -Name $acrName
   if ($acr) {
      foreach ($instanceLocationCode in $instanceLocationCodes) {
         Update-PrivateLink -locationCode $instanceLocationCode `
            -resourceName $acrName -resourceId $acr.Id `
            -groupId "registry"
         }
      }
   }
```

> limitation: ACR build does not work out-of-the-box when placed behind a firewall or as in this case in a closed down network - except when using ACR private build agents; as I did not want to have 2 types of build agents to maintain I choose regular Azure DevOps build agents (several Docker containers running on the jump VMs) to build Docker images

## conclusion

Service endpoints are easier to setup and handle. Private link requires more planning and a higher sophistication in infrastructure automation but with that allows really fine grain control on network access paths.

Currently I have a _mix_ of imperative and declarative infrastructure code which I basically do not prefer. This is tributed to the flexible way we want to spin up regions and instances of the infrastructure. Maybe in some other iteration we refactor and reintegrate in the one way or the other.

Let me know whether this makes sense to you and whether it helped you out in your work.

## credits

Thanks to [my good buddy Matthias](https://dev.to/matttrakker) for reviewing.
