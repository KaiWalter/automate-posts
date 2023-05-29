## Motivation

As posted on [techhub.social](https://techhub.social/@ancientITguy/110440880551590800) I am currently to stretch myself again and move out of the VS Code comfortzone into NeoVim ecosystem. That also entails that I want to use NeoVim on both : Linux and Windows.

On Linux I already create a basic NeoVim configuration which I now want to share with Windows - also to see where I hit limits of that idea. On Linux I use [**Dotfiles**](https://wiki.archlinux.org/title/Dotfiles) to contain and share configurations for Bash, Zsh, Sway, Tmux, NeoVim, ... So how can I leverage Neovim's **Dotfiles** and link it to the appropriate folder on Windows?

## Background

On Windows NeoVim gets its configuration from `%userprofile%\AppData\Local\nvim` and keeps its data in `%userprofile%\AppData\Local\nvim-data`. Hence the `.config/nvim` folder from my Dotfiles needs to be linked to the said configuration folder and a plugin like [**Packer.nvim**](https://github.com/wbthomason/packer.nvim#quickstart) needs to be cloned in a sub-folder in the data folder.

## Script

```PowerShell
# install NeoVim with WinGet, if not already present on system
if (!$(Get-Command nvim -ErrorAction SilentlyContinue)) {
    winget install Neovim.Neovim
}

# clone my Dotfiles repo
$dotFilesRoot = Join-Path $HOME "dotfiles"

if (!(Test-Path $dotFilesRoot -PathType Container)) {
    git clone git@github.com:KaiWalter/dotfiles.git $dotFilesRoot
}

# link NeoVim configuration
$localConfiguration = Join-Path $env:LOCALAPPDATA "nvim"
$dotfilesConfiguration = Join-Path $dotFilesRoot ".config" "nvim"

if (!(Test-Path $localConfiguration -PathType Container)) { 
    Start-Process -FilePath "pwsh" -ArgumentList "-c New-Item -Path $localConfiguration -ItemType SymbolicLink -Value $dotfilesConfiguration".Split(" ") -Verb runas
}

# clone Packer.nvim, if not already present on system
$localPacker = Join-Path $env:LOCALAPPDATA "nvim-data" "site" "pack" "packer" "start" "packer.nvim"

if (!(Test-Path $localPacker -PathType Container)) { 
    git clone https://github.com/wbthomason/packer.nvim $localPacker
}
```

> ATTENTION: `git@github.com:KaiWalter/dotfiles.git` is my private Dotfiles repo - if you want to replicate my approach you would need to run from your own version

After running the script and starting NeoVim a `:PackerSync` is required to install all the plugins.

## My Dotfiles on Linux

There are plenty of posts with various flavors on how to go about setting up Dotfiles. I could not get myself to suggest a particular one, so... when I setup a new Linux system, I use these commands to clone it locally:

```shell
if [ ! -d ~/.dotfiles.git ]; then git clone --bare git@github.com:KaiWalter/dotfiles.git ~/.dotfiles.git; fi
echo ".dotfiles.git" >> ~/.gitignore
git --git-dir=$HOME/.dotfiles.git/ --work-tree=$HOME/ checkout
```

which brings in an `alias` `dotfiles` in `.zshrc` or `.bashrc` to be used when interacting with the particular repository later.

```shell
if [ -d ~/.dotfiles.git ]; then
    alias dotfiles="/usr/bin/git --git-dir=$HOME/.dotfiles.git/ --work-tree=$HOME/"
fi
```
