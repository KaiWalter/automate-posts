## Motivation

In a [2022 post](https://dev.to/kaiwalter/create-a-disposable-azure-vm-based-on-cbl-mariner-2013) I showed how to bring up a **disposable CBL-Mariner VM** using `cloud-init` and (mostly) the **DNF** package manager. As I explained in that post, it takes some fiddling around to find sources for various packages and also to mix installation methods. To achieve a more concise installation approach I tried mixing **CBL Mariner with Nix package manager** in a [later 2023 post](https://dev.to/kaiwalter/azure-vm-based-on-cbl-mariner-with-nix-package-manager-243f).

Since then I have been using [NixOS](https://nixos.org/) on my tinkering computers (x86 & ARM64) at home because I liked this one-file-format-declarative-definition of machines. With some new cloud technology evaluations ahead, for which I usually bring up dedicated disposable VMs, I wanted to transfer some of my NixOS learnings and create a disposable **NixOS Azure VM**. As I did want to create a (_lame, everbody does that_) custom image I was focusing a while on some infection methods (use any installed system and then "infect" with NixOS) [nixos-anywhere](https://github.com/nix-community/nixos-anywhere) and [nixos-infect](https://github.com/elitak/nixos-infect). I did only succeed to a certain point but had to stop because time was running out. One thing I learned in the past 3 decades: pull back in time before you get stuck in a rabbit hole, contain your frustration, swallow your professional pride and move on. Maybe someone reading this already has figured out how to bring up NixOS on an Azure VM in this or another way.

## Ambition

Moving on, I decided to go for the simplest solution in my eyes: **Ubuntu**. Why? When in the weeds of experimenting, in my experience, most on-the-spot tool installations are documented and work usually well with Ubuntu or rather Debian - basically avoiding **yak shaving** when trying to transfer provided installation methods to exactly your environment. After this mental simplification, to still make it interesting, I set this "bar" for me:

- use basic tools like **cloud-init** and scripts - no Ansible, Chef, Puppet, ... - to start VM installation quickly without too many dependencies from my local machine (currently MacOS)
- not to use persisted SSH keys - rather read directly with CLI from **1Password**
- make my regular working environment like **NeoVim, TMUX, ZSH** available on the VM
- pre-install **Node.js, Python, Rust, Docker** with the scripts and methods which bring exactly the desired versions for my dev workloads

This all might not seem very exiting, however, I still had to explore and learn many things (coming from a more or less homogenous NixOS & Home Manager ecosystem) which I want to share here.

## Structure

I will share 4 files I use to drive the installation and then pick out and comment on interesting sections within those files:

- `create.sh` - driving the installation process
- `cloud-init.txt` - basic installation of VM
- `check-creation.sh` - connect to VM and check whether **cloud-init** installation step concluded
- `install-stages.sh` - install all requirements in several stages which build up on each other

Have fun extracting whatever is interesting or useful for you!

> scripts will contain names of primitives - username, SSH keys, repositories. Those are already renamed or obfuscated - so it makes no sense for anybody out there to spend energy in finding those objects out there in the wild.

### create.sh

In general this script

- reads SSH public key to be authorized on VM (file `authorized_keys`) from 1Password
- creates a Resource Group and a Storage Account for Boot Diagnostics (which I used to debug NixOS infection progress and which I wanted to keep)
- create a VM, 1TB OS disk, `cloud-init.txt` for initialization
- sets Auto Shutdown to `22:00 UTC`
- removes probably existing SSH entries from `known_hosts` on my local machine and removes empty lines

```
#! /bin/sh

set -e

VMNAME=${1:-thevm}
USERNAME=${2:-theuser}
PUBKEYNAME=${3:-theVmSshKey}
LOCATION=${4:-uksouth}
STORAGENAME=`echo $VMNAME$RANDOM | tr -cd '[a-z0-9]'`

op account get --account my
if [ $? -ne 0 ]; then
    eval $(op signin --account my)
fi

PUBKEY=`op read "op://Private/$PUBKEYNAME/public key"`

az group create -n $VMNAME -l $LOCATION

az storage account create -n $STORAGENAME -g $VMNAME \
  --sku Standard_LRS \
  --kind StorageV2 \
  --allow-blob-public-access false

az vm create -n $VMNAME -g $VMNAME \
 --image "Canonical:ubuntu-24_04-lts:server:latest" \
 --public-ip-sku Standard \
 --public-ip-address-dns-name $VMNAME \
 --ssh-key-values "$PUBKEY" \
 --admin-username $USERNAME \
 --os-disk-size-gb 1024 \
 --boot-diagnostics-storage $STORAGENAME \
 --size Standard_DS2_v2 \
 --custom-data "$(cat ./cloud-init.txt)"

az vm auto-shutdown -n $VMNAME -g $VMNAME \
  --time "22:00"

sed -i '' "s/$VMNAME.*//" ~/.ssh/known_hosts
sed -i '' '/^$/d' ~/.ssh/known_hosts
```

#### Azure Storage Account Name

Reduce Storage Account name, derived from VM name to alphanumeric characters as other characters like `-` are not allowed. Add a random number to somewhat ensure that the Storage Account name is unique.

```
STORAGENAME=`echo $VMNAME$RANDOM | tr -cd '[a-z0-9]'`
```

#### Get SSH public key from 1Password

This section tests whether 1Password CLI is already signed in, if not does the signin and then reads the public key portion from the secret. `my`is the account (could be more than one) and `Private` is the vault's name.

```
op account get --account my
if [ $? -ne 0 ]; then
    eval $(op signin --account my)
fi

PUBKEY=`op read "op://Private/$PUBKEYNAME/public key"`
```

#### Clean up known_hosts

In case that VM name had been used before and was signed in to with SSH, these statements remove the previous entries and potential resulting empty lines.

> The variance of `sed` works on MacOS, probably with BSD and might need to be adjusted for Linux.

```
sed -i '' "s/$VMNAME.*//" ~/.ssh/known_hosts
sed -i '' '/^$/d' ~/.ssh/known_hosts
```

### cloud-init.txt

This files defines

- installation of a basic set of standard `apt` packages
- installation scripts in various stages which are copied to user's home folder for later installation

```
#cloud-config
package_upgrade: true
packages:
- apt-transport-https
- ca-certificates
- curl
- wget
- less
- lsb-release
- gnupg
- build-essential
- python3
- zsh
- tmux
- jq
- xclip
- dos2unix
- fzf
- ripgrep
write_files:
  - path: /tmp/install-stage1.sh
    content: |
      #!/usr/bin/env bash

      # Azure CLI
      curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

      # Rust
      curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

      # NVM / Node part 1
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash

      # TMUX TPM part 1
      git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

      # Python
      sudo update-alternatives --install /usr/bin/python python /usr/bin/python3 10

      # ZSH oh-my-sh part 1
      sudo chsh -s $(which zsh) $USER
      sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

    permissions: '0755'
  - path: /tmp/install-stage2.sh
    content: |
      #!/usr/bin/env bash
      ssh -T git@github.com

      # clone script folders
      if ! [ -d ~/scripts ]; then git clone git@github.com:theuser/bash-scripts.git ~/scripts; fi
      if ! [ -d ~/.dotfiles.git ]; then git clone git@github.com:theuser/dotfiles.git ~/.dotfiles.git; fi

      # configurations
      [ -e ~/.zshrc ] && rm ~/.zshrc
      [ -d ~/.dotfiles.git ] && ln -s ~/.dotfiles.git/.zshrc ~/.zshrc

      [ -e ~/.tmux.conf ] && rm ~/.tmux.conf
      [ -d ~/.dotfiles.git ] && ln -s ~/.dotfiles.git/.tmux.conf ~/.tmux.conf

      [ -e ~/.configgit ] && rm ~/.configgit
      [ -d ~/.dotfiles.git ] && ln -s ~/.dotfiles.git/.configgit ~/.configgit

      ([ ! -L ~/.config ] && [ -d ~/.dotfiles.git ]) && ln -s ~/.dotfiles.git/.config ~/.config

      # TMUX TPM part 2
      .tmux/plugins/tpm/scripts/install_plugins.sh

      # NeoVim
      [ -e ~/scripts/install-neovim.sh ] && ./scripts/install-neovim.sh

      # NVM / Node part 2
      source .nvm/nvm.sh
      nvm install --lts

    permissions: '0755'
  - path: /tmp/install-stage3.sh
    content: |
      #!/usr/bin/env bash
      ZSH=$HOME/.oh-my-zsh
      [ ! -d $ZSH/custom/plugins/zsh-autocomplete ] && git clone --depth 1 -- https://github.com/marlonrichert/zsh-autocomplete.git $ZSH/custom/plugins/zsh-autocomplete

    permissions: '0755'
runcmd:
- export USER=$(awk -v uid=1000 -F":" '{ if($3==uid){print $1} }' /etc/passwd)

- curl -fsSL https://test.docker.com -o test-docker.sh
- sh test-docker.sh
- rm test-docker.sh
- usermod -aG docker $USER

- mv /tmp/install-stage* /home/$USER/
```

#### Determine user name

This line extracts non-root user name with user id `1000` from `passwd` to reference later in variable `$USER`.

```
- export USER=$(awk -v uid=1000 -F":" '{ if($3==uid){print $1} }' /etc/passwd)
```

#### Install Docker Beta version

```
- curl -fsSL https://test.docker.com -o test-docker.sh
- sh test-docker.sh
- rm test-docker.sh
- usermod -aG docker $USER
```

#### Map configuration files to dotfiles folder

On my disposable VMs I only map selective files and folder from `.dotfiles.git` folder to user's home:

```
# configurations
[ -e ~/.zshrc ] && rm ~/.zshrc
[ -d ~/.dotfiles.git ] && ln -s ~/.dotfiles.git/.zshrc ~/.zshrc

[ -e ~/.tmux.conf ] && rm ~/.tmux.conf
[ -d ~/.dotfiles.git ] && ln -s ~/.dotfiles.git/.tmux.conf ~/.tmux.conf

[ -e ~/.configgit ] && rm ~/.configgit
[ -d ~/.dotfiles.git ] && ln -s ~/.dotfiles.git/.configgit ~/.configgit

([ ! -L ~/.config ] && [ -d ~/.dotfiles.git ]) && ln -s ~/.dotfiles.git/.config ~/.config
```

### check-creation.sh

This is used to SSH into the newly created VM and wait for the cloud init process to finish (or fail):

```
#!/bin/sh

VMNAME=${1:-thevm}
USERNAME=${2:-theuser}
GITHUBSSHKEYNAME=${3:-theGitHubSshKey}
FQDN=`az vm show --show-details -n $VMNAME -g $VMNAME --query fqdns -o tsv | cut -d "," -f 1`
ssh $USERNAME@$FQDN sudo tail -f /var/log/cloud-init-output.log
```

#### Determine VM's FQDN

Azure CLI has an option `--show-details` which returns (among also the provisioning/running state) the VM's FQDNs as a comma separated list.

```
FQDN=`az vm show --show-details -n $VMNAME -g $VMNAME --query fqdns -o tsv | cut -d "," -f 1`
```

### install-stages.sh

This script is called after `create.sh` and `check-creation.sh` which prepares SSH keys for GitHub and then runs the installation stages scripts:

```
#!/bin/sh

VMNAME=${1:-thevm}
USERNAME=${2:-theuser}
GITHUBSSHKEYNAME=${3:-theGitHubSshKey}
FQDN=`az vm show --show-details -n $VMNAME -g $VMNAME --query fqdns -o tsv | cut -d "," -f 1`

op account get --account my
if [ $? -ne 0 ]; then
    eval $(op signin --account my)
fi

op read "op://Private/$GITHUBSSHKEYNAME/private key?ssh-format=openssh" | ssh $USERNAME@$FQDN -T "cat > /home/$USERNAME/.ssh/github"
op read "op://Private/$GITHUBSSHKEYNAME/public key" | ssh $USERNAME@$FQDN -T "cat > /home/$USERNAME/.ssh/github.pub"

ssh $USERNAME@$FQDN bash -c "'
chmod 700 ~/.ssh
chmod 644 ~/.ssh/authorized_keys
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
'"

echo "SSH config finished ... press key"
read -s -n 1

ssh -t $USERNAME@$FQDN ./install-stage1.sh

echo "Stage 1 finished ... press key"
read -s -n 1

ssh -t $USERNAME@$FQDN ./install-stage2.sh

echo "Stage 2 finished ... press key"
read -s -n 1

ssh -t $USERNAME@$FQDN ./install-stage3.sh
```

#### Retrieve and set GitHub SSH keys

These 2 statements extract private and public SSH keys and transfers those with SSH to the VM:

```
op read "op://Private/$GITHUBSSHKEYNAME/private key?ssh-format=openssh" | ssh $USERNAME@$FQDN -T "cat > /home/$USERNAME/.ssh/github"
op read "op://Private/$GITHUBSSHKEYNAME/public key" | ssh $USERNAME@$FQDN -T "cat > /home/$USERNAME/.ssh/github.pub"
```

On the VM line endings need to be converted from CR/LF to LF:

```
dos2unix ~/.ssh/github
```

#### Multiple line SSH commands

This one I had to figure out first and comes in handy when multiple lines have to be send over SSH to a remote machine:

```
ssh $USERNAME@$FQDN bash -c "'
...
cat << EOF > ~/.ssh/config
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/github

EOF
...
'"
```

#### Use SSH with terminal allocated

I ran into a problem ...

```
Host key verification failed.
```

... with this section when just SSHing with `ssh -t $USERNAME@$FQDN ./install-stage2.sh`

```
ssh -T git@github.com

# clone script folders
if ! [ -d ~/scripts ]; then git clone git@github.com:theuser/bash-scripts.git ~/scripts; fi
if ! [ -d ~/.dotfiles.git ]; then git clone git@github.com:theuser/dotfiles.git ~/.dotfiles.git; fi
```

I had to change to `-t` option:

```
ssh -t $USERNAME@$FQDN ./install-stage2.sh
```

### install-neovim.sh

I noticed that when installing NeoVim with the various package managers (DNF, apt, AUR) different configuration postures are put on the systems. Hence I always install with this script to end up with a reproducable configuration.

```
#!/bin/bash

set -e

case $1 in
    nightly)  # Ok
        tag=tags/nightly
        ;;
    *)
        tag=latest
        ;;
esac

latest_nv_linux=$(curl -sL https://api.github.com/repos/neovim/neovim/releases/$tag | jq -r ".assets[].browser_download_url" | grep -E 'nvim-linux64.tar.gz$')
wget $latest_nv_linux -O ~/nvim-linux64.tar.gz
sudo tar xvf ~/nvim-linux64.tar.gz -C /usr/local/bin/
rm ~/nvim-linux64.tar.gz
mkdir -p ~/.local/bin

if [ ! -e ~/.local/bin/nvim ]; then
    sudo ln -s /usr/local/bin/nvim-linux64/bin/nvim ~/.local/bin/nvim
fi
```
