## Motivation

In a [2023 post](https://dev.to/kaiwalter/azure-vm-based-on-cbl-mariner-with-nix-package-manager-243f) I showed how to use Nix package manager in an Azure VM - in that case CBL Mariner / Azure Linux. As I've been intensifying using NixOS on my home systems and with that creating an extensive multi-host NixOS Flakes based configuration repository I wanted to get that native NixOS experience also over on my occasional cloud tinkering VMs.

## Options

### Custom Image

For me the most obvious approach would be to generate a custom image, upload it to the cloud provider and stamp up the VM with that image. I succeeded using [Society for the Blind's nixos-azure-deploy repository](https://github.com/society-for-the-blind/nixos-azure-deploy) with minor modifications. However that approach seemed too resource intensive for me and required Nix running on the initiating (source) system.

### nixos-infect and nixos-anywhere

Early I was pulled towards [nixos-anywhere](https://github.com/nix-community/nixos-anywhere), a set of scripts to install NixOS over SSH on an arbitrary target system having `kexec` support. When struggling I tried my luck with [nixos-inject](https://github.com/elitak/nixos-infect), another way to install NixOS from within an existing target system.

Basically flipping back and forth between the 2 I tried with an approach to deploy an Azure VM (and to cut out cloud platform side effects also AWS EC2 instance) - with Ubuntu or Azure/AWS Linux - and then initiate the **infection** already during `cloud-init`. Going down that rabbit hole for some time, trying to resolve issues around the right boot and disk configuration which made the target system not boot up again properly, I reverted back a bit and succeeded by injecting from an outside, a NixOS based source system with a command line like:

```
nix run github:nix-community/nixos-anywhere -- --flake .#az-nixos --generate-hardware-config nixos-facter ./facter.json root@$FQDN
```

### nixos-anywhere with Azure Container Instances

Nice but not yet where I wanted to be. For boot-strapping I prefer to work with a very limit set of tools/dependencies, aiming for only having shell scripting and Azure CLI, cutting out NixOS or a Nix-installation on none Linux source systems. Already using ACI/Azure Container Instances for other temporary jobs - [as temporary certificate authority](https://dev.to/kaiwalter/creating-a-certificate-authority-for-testing-with-azure-container-instances-5bnp) or [to handle an ACME challenge response](https://dev.to/kaiwalter/handling-an-acme-challenge-response-with-a-temporary-azure-container-instance-3ae0) I thought it to be a proper candidate to bring up a temporary NixOS source system. This post describes all components to achieve that kind of setup based on scripts in this [repository](https://github.com/KaiWalter/nixos-cloud-deploy).

> As the name `nixos-cloud-deploy` may suggest, I want to keep this repository open for other cloud providers to be included. Out of necessity I might add AWS soon.

## VM creation

Script `create-azvm-nixos-anywhere.sh` drives the whole VM creation process. All general parameters to control the process, can be overwritten by command line arguments

| argument                                       | command line argument(s) | purpose                                                                                                                |
| ---------------------------------------------- | ------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| VMNAME=az-nixos                                | -n --vm-name             | sets the name of the VM                                                                                                |
| RESOURCEGROUPNAME=$VMNAME                      | -g --resource-group      | controls the Azure resource group to create and use                                                                    |
| VMUSERNAME=johndoe                             | -u --user-name           | sets the user name (additional to root) to setup on the VM                                                             |
| LOCATION=uksouth                               | -l --location            | controls the Azure region to be used                                                                                   |
| VMKEYNAME=azvm                                 | --vm-key-name            | controls the name of the SSH public key to be used on the VM                                                           |
| GITHUBSSHKEYNAME=github                        | --github-key-name        | controls the name of the GitHub SSH keys to be used to pull the desired Nix configuration repository                   |
| SIZE=Standard_B4ms                             | -s --size                | controls the Azure VM SKU                                                                                              |
| MODE=aci                                       | -m --mode                | controls the source system mode: `aci` using ACI, `nixos` assuming to use the local Nix(OS) configuration              |
| IMAGE=Canonical:ubuntu-24_04-lts:server:latest | -i --image               | controls the initial Azure VM image to be used on the target system to inject NixOS into;<BR/>needs to support `kexec` |
| NIXCHANNEL=nixos-24.05                         | --nix-channel            | controls the NixOS channel to be used for injection and installation                                                   |

### sensitive information / SSH keys

Keys are not passed but pulled into the script:

```
# obtain sensitive information
. ./common.sh
prepare_keystore
VMPUBKEY=$(get_public_key $VMKEYNAME)
```

To make adaptation easier, I centralized keystore access - in my case to 1Password CLI - in a shared script `common.sh`:

```
prepare_keystore () {
  op account get --account my &>/dev/null
  if [ $? -ne 0 ]; then
      eval $(op signin --account my)
  fi
}

get_private_key () {
  echo "$(op read "op://Private/$1/private key?ssh-format=openssh")"
}

get_public_key () {
  echo "$(op read "op://Private/$1/public key")"
}
```

So to adapt it for just using keys on the local file system those functions could (no warranties) like:

```
prepare_keystore () {
  # nothing to do
}

get_private_key () {
  cat ~/.ssh/$1
}

get_public_key () {
  cat ~/.ssh/$1.pub
}
```

From that these keys are injected either in the Nix configuration files to set directly over SSH on the target system. To keep it simple I did not trouble myself with adapting a secret handler like [sops-nix](https://github.com/Mic92/sops-nix).

### Azure resource creation

Creation of VM is handled pretty straight forward with Azure CLI. I added an explicit Storage Account to be able to investigate boot diagnostics, in case the provisioning process failed.

### Injecting NixOS

Before starting injection, the script waits for SSH endpoint to be available on the target VM and cleans up `known_hosts` from entries which might be left from prior attempts.

```
FQDN=`az vm show --show-details -n $VMNAME -g $RESOURCEGROUPNAME --query fqdns -o tsv | cut -d "," -f 1`

wait_for_ssh $FQDN
cleanup_knownhosts $FQDN
```

Again for re-used those 2 functions are defined in `common.sh`:

```
cleanup_knownhosts () {
  case "$OSTYPE" in
    darwin*|bsd*)
      sed_no_backup=( -i "''" )
      ;;
    *)
      sed_no_backup=( -i )
      ;;
  esac

  sed ${sed_no_backup[@]} "s/$1.*//" ~/.ssh/known_hosts
  sed ${sed_no_backup[@]} "/^$/d" ~/.ssh/known_hosts
  sed ${sed_no_backup[@]} "/# ^$/d" ~/.ssh/known_hosts
}

wait_for_ssh () {
  echo "Waiting for SSH to become available..."
  while ! nc -z $1 22; do
      sleep 5
  done
}
```

> The `$OSTYPE` case handles the varying `sed` flavors on MacOS, BSD and Linux regaring in-place replacement.

#### Making root available for SSH

`nixos-anywhere` relies on having root SSH access to the target system. Default Azure VM provisioning generates `authorized_keys` which prevents `root` to be used for connecting. As a remedy the script copies over VM user's SSH key to root.

```
echo "configuring root for seamless SSH access"
ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' $VMUSERNAME@$FQDN sudo cp /home/$VMUSERNAME/.ssh/authorized_keys /root/.ssh/

echo "test SSH with root"
ssh -o 'UserKnownHostsFile=/dev/null' -o 'StrictHostKeyChecking=no' root@$FQDN uname -a
```

Skipping this step would show an error like:

```
test SSH with root
Warning: Permanently added 'az-nixos.uksouth.cloudapp.azure.com' (ED25519) to the list of known hosts.
Please login as the user "johndoe" rather than the user "root".
```

#### initiating inject

For ACI based injection, script `config-azvm-nixos-aci.sh` is invoked, which is described below:

```
./config-azvm-nixos-aci.sh --vm-name $VMNAME \
    --resource-group $RESOURCEGROUPNAME \
    --user-name $VMUSERNAME \
    --location $LOCATION \
    --nix-channel $NIXCHANNEL \
    --vm-key-name $VMKEYNAME
```

For direct injection with Nix, `nixos-anywhere` is invoked directly:

```
TEMPNIX=$(mktemp -d)
trap 'rm -rf -- "$TEMPNIX"' EXIT
cp -r ./nix-config/* $TEMPNIX
sed -e "s|#PLACEHOLDER_PUBKEY|$VMPUBKEY|" \
    -e "s|#PLACEHOLDER_USERNAME|$VMUSERNAME|" \
    -e "s|#PLACEHOLDER_HOSTNAME|$VMNAME|" \
    ./nix-config/configuration.nix > $TEMPNIX/configuration.nix

nix run github:nix-community/nixos-anywhere -- --flake $TEMPNIX#az-nixos --generate-hardware-config nixos-facter $TEMPNIX/facter.json root@$FQDN
```

> VM's SSH key and host/username are replaced in a copy of the configuration files which then will be used by `nixos-anywhere`.

### concluding VM installation

When one of the 2 injection methods succeed, the Azure VM should be ready with NixOS installed and SSH-access available on the desired VM user. From that final steps to finalize the installation are executed:

- set the NixOS channel to be used for the installation
- transfer GitHub SSH keys to pull the repository with the desired NixOS configuration
- transfer the VM's public key to a spot, where it can be picked up by my NixOS configuration definition later
- configure GitHub SSH environment; `dos2unix` was required to bring the SSH key exported from 1Password CLI from CRLF into LF line endings
- pull the configuration repository and switch into the final configuration

```
# finalize NixOS configuration
ssh-keyscan $FQDN >> ~/.ssh/known_hosts

echo "set Nix channel"
ssh $VMUSERNAME@$FQDN "sudo nix-channel --add https://nixos.org/channels/${NIXCHANNEL} nixos && sudo nix-channel --update"

echo "transfer VM and Git keys..."
ssh $VMUSERNAME@$FQDN "mkdir -p ~/.ssh"
get_private_key "$GITHUBSSHKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/github'
get_public_key "$GITHUBSSHKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/github.pub'
get_public_key "$VMKEYNAME" | ssh $VMUSERNAME@$FQDN -T 'cat > ~/.ssh/azvm.pub'

ssh $VMUSERNAME@$FQDN bash -c "'
chmod 700 ~/.ssh
chmod 644 ~/.ssh/*pub
chmod 600 ~/.ssh/github

dos2unix ~/.ssh/github

cat << EOF > ~/.ssh/config
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github

EOF

chmod 644 ~/.ssh/config
ssh-keyscan -H github.com >> ~/.ssh/known_hosts
'"

echo "clone repos..."
ssh $VMUSERNAME@$FQDN -T "git clone -v git@github.com:johndoe/nix-config.git ~/nix-config"
ssh $VMUSERNAME@$FQDN -T "sudo nixos-rebuild switch --flake ~/nix-config#az-vm --impure"
```

## Injection with ACI

Script `config-azvm-nixos-anywhere.sh` is called by the creation script above to bring up an Azure Container Instance with NixOS to drive the injection process. This script could be used standalone on an existing Azure VM.

| argument                  | command line argument(s) | purpose                                                                    |
| ------------------------- | ------------------------ | -------------------------------------------------------------------------- |
| VMNAME=az-nixos           | -n --vm-name             | specifies the name of the VM                                               |
| RESOURCEGROUPNAME=$VMNAME | -g --resource-group      | specifies the Azure resource group to use                                  |
| VMUSERNAME=johndoe        | -u --user-name           | specifies the user name                                                    |
| LOCATION=uksouth          | -l --location            | specifies he Azure region to be used                                       |
| VMKEYNAME=azvm            | --vm-key-name            | specifies the name of the SSH public key to be used on the VM              |
| SHARENAME=nixos-config    | -s --share-name          | specifies the Azure file share name to be used to hold configuration files |
| CONTAINERNAME=$VMNAME     | -c --container-name      | specifies the ACI container name to be used                                |
| NIXCHANNEL=nixos-24.05    | --nix-channel            | controls the NixOS channel to be used for injection and installation       |

### handling sensitive information

Obtaining secrets and setting the configuration is done similar to the creation script. It might look redundant, but for certain cases I wanted this script to have its own lifecycle.

```
# obtain sensitive information
. ./common.sh
prepare_keystore
VMPUBKEY=$(get_public_key $VMKEYNAME)
VMPRIVKEY=$(get_private_key $VMKEYNAME | tr "[:cntrl:]" "|")

# parameters obtain sensitive information
TEMPNIX=$(mktemp -d)
trap 'rm -rf -- "$TEMPNIX"' EXIT
cp -r ./nix-config/* $TEMPNIX
sed -e "s|#PLACEHOLDER_PUBKEY|$VMPUBKEY|" \
  -e "s|#PLACEHOLDER_USERNAME|$VMUSERNAME|" \
  -e "s|#PLACEHOLDER_HOSTNAME|$VMNAME|" \
  ./nix-config/configuration.nix > $TEMPNIX/configuration.nix
```

> Control characters in private key coming from 1Password needed to be replaced by a basic character `|`, so that this key is passed properly into ACI. A lot of time, sometimes hours goes into resolving such tiny issues. That might seem wasted energy for some, but for me, not being on any project or other pressure, this actually is fun and helps me recharge my batteries.

### Uploading configuration files to Azure storage file share

All files, copied to the temporary configuration and then patched for the occasion, are uploaded to the file share:

```
STORAGENAME=$(az storage account list -g $RESOURCEGROUPNAME --query "[?kind=='StorageV2']|[0].name" -o tsv)

AZURE_STORAGE_KEY=`az storage account keys list -n $STORAGENAME -g $RESOURCEGROUPNAME --query "[0].value" -o tsv`
if [[ $(az storage share exists -n $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY -o tsv) == "False" ]]; then
  az storage share create -n $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY
fi

# upload Nix configuration files
for filename in $TEMPNIX/*; do
  echo "uploading ${filename}";
  az storage file upload -s $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY \
    --source $filename
done
```

### Running the container

Finally the ACI container is created with the file share mounted to `/root/work` and relevant parameters passed as `secure-environment-variables`.

Special considerations:

- it turned out, that the process really needs 2GB memory - hence `--memory 2`
- in order to keep the container active, the entrypoint process is sent into a loop with `--command-line "tail -f /dev/null"`
- `nixos-anywhere` still needs some preparation in the container which is accommodated by the script `aci-run.sh` (descibed below)

```
az container create --name $CONTAINERNAME -g $RESOURCEGROUPNAME \
    --image nixpkgs/nix:$NIXCHANNEL \
    --os-type Linux --cpu 1 --memory 2 \
    --azure-file-volume-account-name $STORAGENAME \
    --azure-file-volume-account-key $AZURE_STORAGE_KEY \
    --azure-file-volume-share-name $SHARENAME \
    --azure-file-volume-mount-path "/root/work" \
    --secure-environment-variables NIX_PATH="nixpkgs=channel:$NIXCHANNEL" FQDN="$FQDN" VMKEY="$VMPRIVKEY" \
    --command-line "tail -f /dev/null"

az container exec --name $CONTAINERNAME -g $RESOURCEGROUPNAME --exec-command "sh /root/work/aci-run.sh"

az container stop --name $CONTAINERNAME -g $RESOURCEGROUPNAME
az container delete --name $CONTAINERNAME -g $RESOURCEGROUPNAME -y
az storage share delete -n $SHARENAME --account-name $STORAGENAME --account-key $AZURE_STORAGE_KEY
```

### Process inside container

Script `aci-run.sh` prepares the container for `nixos-anywhere`:

- configuring Nix to allow "new" Nix commands and flakes
- copying configuration files from file share to a local folder as this folder needs to be initialized with Git to work properly
- configuring Git
- convert the basic character `|` passed in VM's private key to proper LF line endings

> The last 3 steps for some may seem straightforward (the proper way to get Nix flakes working somewhere from scratch) or overdone. Again a lot of time went into getting this run smoothly.

```
#!/bin/sh

set -e

echo "configure Nix..."
mkdir -p /etc/nix
cat << EOF >/etc/nix/nix.conf
experimental-features = nix-command flakes
warn-dirty = false
EOF

echo "initialize Nix configuration files..."
mkdir -p /root/nix-config
cp -v /root/work/*nix /root/nix-config/

git config --global init.defaultBranch main
git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"

cd /root/nix-config
git init
git add .
git commit -m "WIP"
nix flake show

echo "set SSH private key to VM..."
mkdir -p /root/.ssh
KEYFILE=/root/.ssh/vmkey
echo $VMKEY | tr "|" "\n" >$KEYFILE
chmod 0600 $KEYFILE

nix run github:nix-community/nixos-anywhere -- --flake /root/nix-config#az-nixos --generate-hardware-config nixos-facter /root/nix-config/facter.json -i $KEYFILE root@$FQDN
```

## Nix configuration files

`nix-config/configuration.nix` is roughly only a copy of existing samples with only minor adjustments (e.g. adding `dos2unix`, `git` and `vim`).

`nix-config/disk-config.nix` also is a copy of a samples adjusted to fit the requirements for an Azure VM's disk layout as good as possible.

The brunt of "hardware" detection is handled by including [Facter](https://github.com/numtide/nixos-facter) in the `nixos-anywhere` configuration process.

## Result

So by just simple running the creation script `./create-azvm-nixos-anywhere.sh` I get a VM configured with my own Nix Flake configuration, no VM image dangling somewhere.

SSHing on the VM and checking, gives me:

```
$ nix-info
system: "x86_64-linux", multi-user?: yes, version: nix-env (Nix) 2.24.10, channels(root): "nixos-24.05", nixpkgs: /etc/nix/path/nixpkgs`
```
