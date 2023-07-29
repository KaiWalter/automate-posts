## Motivation

In a previous [post](https://dev.to/kaiwalter/create-a-disposable-azure-vm-based-on-cbl-mariner-2013) I was showing how to bring up a disposable CBL-Mariner* VM using cloud-init and (mostly) the dnf package manager. As I explained in that post, it takes some fiddling around to find sources for various packages and also to mix installation methods.

> \* when reviewing I found that I had a small typo in the post - "CBM-Mariner" - I guess my subconscious mind partially still lives in the 8-bit era

When I was coming across [Nix package manager](https://nixos.org/manual/nix/stable/package-management/basic-package-mgmt.html) a few days back - while again distro hopping for my home experimental machine - I thought to combine both and maybe make package installation simpler and more versatile for CBL-Mariner - with its intended small repository to keep attack surface low.

> This approach, to bring in **Nix** over `cloud-init`, should work with a vast amount of distros and should not be limited to CBL-Mariner only!

## create.sh - Creation script

In this post I want to use a **Bash** script and **Azure CLI** to drive VM installation:

```shell
#!/bin/bash

set -e

user=admin
name=my-cblnix
location=westeurope
keyfile=~/.ssh/cblnix

az deployment sub create -f ./rg.bicep \
  -l $location \
  -p computerName=$name \
  resourceGroupName=$name \
  location=$location \
  adminUsername=$user \
  adminPasswordOrKey="$(cat $keyfile.pub)" \
  customData="$(cat ./cloud-init-cbl-nix.txt)" \
  vmSize=Standard_D2s_v3 \
  vmImagePublisher=MicrosoftCBLMariner \
  vmImageOffer=cbl-mariner \
  vmImageSku=cbl-mariner-2

fqdn=$(az network public-ip show -g $name -n $name-ip --query 'dnsSettings.fqdn' -o tsv)
echo "ssh -i $keyfile $user@$fqdn"

ssh-keygen -R $fqdn
```

Key elements and assumptions:

- Azure CLI using a set of Bicep templates (shown below) to deploy a Resource Group and a Virtual Machine with the same name
- it is assumed that public SSH key file has the same and is in the same location than the private SSH key file, just with a `.pub` extension
- after VM creation FQDN is determined and printed
- `ssh-keygen` is used to clean up potentially existing entries in SSH's `known_hosts`

## cloud-init.txt

As in the previous post a `cloud-init.txt` is required to bootstrap the basic installation of the VM - but now in a much cleaner shape:

```text
#cloud-config
write_files:
  - path: /tmp/install-nix.sh
    content: |
      #!/bin/bash
      sh <(curl -L https://nixos.org/nix/install) --daemon --yes
    permissions: '0755'
  - path: /tmp/base-setup.nix
    content: |
        with import <nixpkgs> {}; [
          less
          curl
          git
          gh
          azure-cli
          kubectl
          nodejs_18
          rustup
          go
          dotnet-sdk_7
          zsh
          oh-my-zsh
        ]
    permissions: '0644'
runcmd:
- export USER=$(awk -v uid=1000 -F":" '{ if($3==uid){print $1} }' /etc/passwd)

- sudo -H -u $USER bash -c '/tmp/install-nix.sh'

- /nix/var/nix/profiles/default/bin/nix-env -if /tmp/base-setup.nix

- - sudo -H -u $USER bash -c '/nix/var/nix/profiles/default/bin/rustup default stable'
```

Gotchas:

- daemon installation of Nix package manager needs to be executed in the context of the VM main user
- after daemon installation `nix-env` and all installed binaries reside in `/nix/var/nix/profiles/default/bin` folder but as shell has not been restarted links to those binaries are not available to the session and have to be started from that location

> do not forget to `sudo tail /var/log/cloud-init-output.log -f` to check or observe the finalization of the installation which will take some time after the VM is deployed

## rg.bicep

To achieve VM installation including its Resource Group, installation is framed with this **Bicep** template:

```
targetScope = 'subscription' // Resource group must be deployed under 'subscription' scope

param location string
param resourceGroupName string
param computerName string
param vmSize string = 'Standard_DS1_v2'
param adminUsername string = 'admin'
@secure()
param adminPasswordOrKey string
param customData string

param vmImagePublisher string
param vmImageOffer string
param vmImageSku string

resource rg 'Microsoft.Resources/resourceGroups@2021-01-01' = {
  name: resourceGroupName
  location: location
}

module vm 'vm.bicep' = {
  name: 'vm'
  scope: rg
  params: {
    location: location
    computerName: computerName
    vmSize: vmSize
    vmImagePublisher: vmImagePublisher
    vmImageOffer: vmImageOffer
    vmImageSku: vmImageSku
    adminUsername: adminUsername
    adminPasswordOrKey: adminPasswordOrKey
    customData: customData
  }
}
```

## vm.bicep

Then VM is deployed with another **Bicep** in the scope of the Resource Group:

```
param location string = resourceGroup().location
param computerName string
param vmSize string = 'Standard_D2s_v3'

param adminUsername string = 'admin'
@secure()
param adminPasswordOrKey string
param customData string = 'echo customData'

var authenticationType = 'sshPublicKey'
param vmImagePublisher string
param vmImageOffer string
param vmImageSku string

var vnetAddressPrefix = '192.168.43.0/27'

var vmPublicIPAddressName = '${computerName}-ip'
var vmVnetName = '${computerName}-vnet'
var vmNsgName = '${computerName}-nsg'
var vmNicName = '${computerName}-nic'
var vmDiagnosticStorageAccountName = '${replace(computerName, '-', '')}${uniqueString(resourceGroup().id)}'

var shutdownTime = '2200'
var shutdownTimeZone = 'W. Europe Standard Time'

var linuxConfiguration = {
  disablePasswordAuthentication: true
  ssh: {
    publicKeys: [
      {
        path: '/home/${adminUsername}/.ssh/authorized_keys'
        keyData: adminPasswordOrKey
      }
    ]
  }
}

var resourceTags = {
  vmName: computerName
}

resource vmNsg 'Microsoft.Network/networkSecurityGroups@2022-01-01' = {
  name: vmNsgName
  location: location
  tags: resourceTags
  properties: {
    securityRules: [
      {
        name: 'in-SSH'
        properties: {
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
          access: 'Allow'
          priority: 1000
          direction: 'Inbound'
        }
      }
    ]
  }
}

resource vmVnet 'Microsoft.Network/virtualNetworks@2022-01-01' = {
  name: vmVnetName
  location: location
  tags: resourceTags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
  }
}

resource vmSubnet 'Microsoft.Network/virtualNetworks/subnets@2022-01-01' = {
  name: 'vm'
  parent: vmVnet
  properties: {
    addressPrefix: vnetAddressPrefix
    networkSecurityGroup: {
      id: vmNsg.id
    }
  }
}

resource vmDiagnosticStorage 'Microsoft.Storage/storageAccounts@2019-06-01' = {
  name: vmDiagnosticStorageAccountName
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'Storage'
  tags: resourceTags
  properties: {}
}

resource vmPublicIP 'Microsoft.Network/publicIPAddresses@2019-11-01' = {
  name: vmPublicIPAddressName
  location: location
  tags: resourceTags
  properties: {
    publicIPAllocationMethod: 'Dynamic'
    dnsSettings: {
      domainNameLabel: computerName
    }
  }
}

resource vmNic 'Microsoft.Network/networkInterfaces@2022-01-01' = {
  name: vmNicName
  location: location
  tags: resourceTags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: vmPublicIP.id
          }
          subnet: {
            id: vmSubnet.id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2022-03-01' = {
  name: computerName
  location: location
  tags: resourceTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    priority: 'Spot'
    evictionPolicy: 'Deallocate'
    billingProfile: {
      maxPrice: -1
    }
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: vmImagePublisher
        offer: vmImageOffer
        sku: vmImageSku
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 1024
      }
    }
    osProfile: {
      computerName: computerName
      adminUsername: adminUsername
      adminPassword: adminPasswordOrKey
      customData: base64(customData)
      linuxConfiguration: ((authenticationType == 'password') ? null : linuxConfiguration)
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNic.id
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: vmDiagnosticStorage.properties.primaryEndpoints.blob
      }
    }
  }
}

resource vmShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${computerName}'
  location: location
  tags: resourceTags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: shutdownTime
    }
    timeZoneId: shutdownTimeZone
    notificationSettings: {
      status: 'Disabled'
    }
    targetResourceId: vm.id
  }
}
```

Key elements and assumptions:

- VM is installed with its own virtual network - in case VM would need to be integrated in an existing VNET, that part would need adaption
- a Network Security Group is created and added to the Subnet which opens SSH-port 22 - for non-experimental use it is advised to place the VM behind a Bastion service, use Just-In-Time access or protect otherwise
- automatic VM shutdown is achieved with a `DevTestLab/schedules` resource, be aware that such a resource is not available everywhere e.g. missing in Azure China; additionally time zone and point of time are hard-wired currently, please adapt to your own needs

## What is missing?

In the limited time I had I was not able to figure out, how **Docker** service is completely installed and configured with **Nix**. So watch out for potential updates here.

## Conclusion

With this configuration I have a slim distribution combined with a powerful package management environment available to add and remove packages in a clean way - exactly what I need for experimental and development workloads.

I assume that **Nix** offers far more capabilities than just installing packages - which I will continue to explore to have an alternative for the relatively clunky and sensitive `cloud-init` installation approach.

## P.S.

If you want start posting articles "at scale" and want to see how I post on <https://dev.to>, <https://ops.io> and <https://hashnode.com> in one go, check out my [repo + script](https://github.com/KaiWalter/automate-posts/blob/main/createPosts.ps1). It is not really elegant, has a bulky usability, it is PowerShell, but it does the trick - hence it is "me".