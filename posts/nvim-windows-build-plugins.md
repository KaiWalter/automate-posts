## TL;DR

In this post I show or share 

- a PowerShell script to install LLVM / mingw  / make toolchains on Windows to be used by plugin build processes
- how to install Microsoft Build Tools with `winget` (that in the end did not qualify for all build cases and was discarded)
- some sample plugin configurations with **Lazy** plugin manager
- some observations I made with plugin managers not working smoothly through corporate proxy configurations

## Background

In a [previous post](https://dev.to/kaiwalter/share-neovim-configuration-between-linux-and-windows-4gh8) I was showing how I was sharing one configuration for NeoVim based on one version of dotfiles in Linux and Windows.

That works pretty well for [Lua](https://www.lua.org/)-only plugins, as long as underlying command line tools like e.g. `ripgrep`  or `lazygit` are also avaible on Windows. As soon as plugins require a tool chain to build those command line tools from source it gets tricky having the same NeoVim configuration facilitating Linux and Windows.

## Selecting the right build tool chain

### MS Build Tools and Gnu Make

With this combination I was able to get **Treesitter** installed and built on Windows. It requires an installation like ...

```
# install make
$makePath = Join-Path ${env:ProgramFiles(x86)} "GnuWin32" "bin"
if(!(Test-Path $makePath -PathType Container)) {
  winget install GnuWin32.Make
}

# install MS Build Tools
$msbtProgramFolder = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio" "2022" "BuildTools"
if(!(Test-Path $msbtProgramFolder -PathType Container)) {
    winget install Microsoft.VisualStudio.2022.BuildTools
    winget install --id Microsoft.VisualStudio.2022.BuildTools --override $("--passive --config " + (Join-Path $PSScriptRoot "BuildTools.vsconfig"))
}
```

... with an accompaning __BuildTools.vsconfig__ to define components to be installed ...

```
{
  "version": "1.0",
  "components": [
    "Microsoft.VisualStudio.Component.Roslyn.Compiler",
    "Microsoft.Component.MSBuild",
    "Microsoft.VisualStudio.Component.CoreBuildTools",
    "Microsoft.VisualStudio.Workload.MSBuildTools",
    "Microsoft.VisualStudio.Component.Windows10SDK",
    "Microsoft.VisualStudio.Component.VC.CoreBuildTools",
    "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
    "Microsoft.VisualStudio.Component.VC.Redist.14.Latest",
    "Microsoft.VisualStudio.Component.Windows11SDK.22000",
    "Microsoft.VisualStudio.Component.TextTemplating",
    "Microsoft.VisualStudio.Component.VC.CoreIde",
    "Microsoft.VisualStudio.ComponentGroup.NativeDesktop.Core",
    "Microsoft.VisualStudio.Workload.VCTools",
    "Microsoft.VisualStudio.Component.VC.14.35.17.5.ATL.Spectre",
    "Microsoft.VisualStudio.Component.VC.14.35.17.5.MFC.Spectre",
    "Microsoft.VisualStudio.Component.VC.14.36.17.6.ATL.Spectre",
    "Microsoft.VisualStudio.Component.VC.14.36.17.6.MFC.Spectre"
  ]
}
```

... and that, on plugin-installation, NeoVim is started from "Visual Studio Developer PowerShell" command prompt while adding Gnu Make to the path:

```
$makePath = Join-Path ${env:ProgramFiles(x86)} "GnuWin32" "bin"
$env:Path += ";" + $makePath
nvim
```

Yet this setup was not sufficient for **Telescope/fzf**, as only a **clang** but no **gcc** compiler seemed to be available. I succeeded when adding a **gcc** into the mix but was not really happy with the extra "Visual Studio Developer PowerShell" command prompt required.

### LLVM/Clang/LLD based mingw-w64

In this toolchain I found **clang** and **gcc** compilers. Also it allowed me to just add it to the path (see script `NeoVimPluginInstall.ps1` below) of my current shell when directing NeoVim into a plugin installation - without an extra command prompt like above.

That allowed me to use build process configuration for **Telescope/fzf** on Linux and Windows without any changes:

```
return {
	"nvim-telescope/telescope.nvim",
	branch = "0.1.x",
	dependencies = {
		"nvim-lua/plenary.nvim",
		{
			"nvim-telescope/telescope-fzf-native.nvim",
			build = "make",
		},
		"nvim-tree/nvim-web-devicons",
	},
	config = function() 
...
```

## NeoVim installation script

Since my [previous post](https://dev.to/kaiwalter/share-neovim-configuration-between-linux-and-windows-4gh8) I extended and hardened the installation script a bit. It now additionally installs

- **ripgrep** for Telescope `live_grep` string finder
- **lazygit** for the equally named plugin
- **Gnu make** to drive some of the build processes
- **llvm-mingw64** a [LLVM/Clang/LLD based mingw-w64 toolchain](https://github.com/mstorsjo/llvm-mingw)

```
[CmdletBinding()]
param (
    [Parameter()]
    [switch]
    $ResetState
)

# install NeoVim with WinGet, if not already present on system
if (!$(Get-Command nvim -ErrorAction SilentlyContinue)) {
    winget install Neovim.Neovim
}

# install ripgrep
if (!$(Get-Command rg -ErrorAction SilentlyContinue)) {
  winget install BurntSushi.ripgrep.MSVC
}

# install lazygit
if (!$(Get-Command lazygit -ErrorAction SilentlyContinue)) {
  winget install JesseDuffield.lazygit
}

# install make
$makePath = Join-Path ${env:ProgramFiles(x86)} "GnuWin32" "bin"
if(!(Test-Path $makePath -PathType Container)) {
  winget install GnuWin32.Make
}

$llvmFolder = Get-ChildItem -Path $env:LOCALAPPDATA -Filter "llvm*x86_64" | Select-Object -ExpandProperty FullName
if(!$llvmFolder -or !(Test-Path $llvmFolder -PathType Container)) {
  $downloadFile = "llvm-mingw.zip"
  . .\getLatestGithubRepo.ps1 -Repository "mstorsjo/llvm-mingw" -DownloadFilePattern "llvm-mingw-.*-msvcrt-x86_64.zip" -DownloadFile $downloadFile
  Expand-Archive -Path $(Join-Path $env:TEMP $downloadFile) -DestinationPath $env:LOCALAPPDATA
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

# reset local state if required
$localState = Join-Path $env:LOCALAPPDATA "nvim-data"

if($ResetState) {
    if(Test-Path $localState -PathType Container) {
        Remove-Item $localState -Recurse -Force
        New-Item $localState -ItemType Directory
    }
}
```

> ATTENTION: `git@github.com:KaiWalter/dotfiles.git` is my private Dotfiles repo - if you want to replicate my approach you would need to work from your own version;
> script `.\getLatestGithubRepo.ps1` is shown below

## Lua configuration

While succeeding in getting NeoVim working smoothly with plugins on my own Windows machines, I struggled on my company laptop. Plugin installation with **Packer** was lagging at best sometimes even hanging. As of August'23 it is announced on the [Packer](https://github.com/wbthomason/packer.nvim) repo README, that it is not maintained anymore and suggested to move to another package manager.

When started with NeoVim a few months back I followed the suggestion from the NeoVim main protagonists and looked into some of the NeoVim distros like [LazyVim](https://www.lazyvim.org/) , LunarVim, AstroVim, and NVChad to make like easier (coming fresh from Visual Studio Code even to make life bearable).
https://github.com/folke/lazy.nvim

https://github.com/josean-dev/dev-environment-files

## utility scripts

### NeoVimPluginInstall.ps1

Script used when starting up NeoVim adding tool chain paths to search path, so that build tools can be found:

```
$llvmPath = Join-Path $(Get-ChildItem -Path $env:LOCALAPPDATA -Filter "llvm*x86_64" | Select-Object -ExpandProperty FullName) "bin"
$makePath = Join-Path ${env:ProgramFiles(x86)} "GnuWin32" "bin"
$env:Path += ";" + $llvmPath + ";" + $makePath
nvim $args
```

### getLatestGithubRepo.ps1

Script to find and download a given file pattern from a GitHub repo's latest releases:

```
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 1)]
    [string] $Repository,
    [Parameter(Position = 2)]
    [string] $DownloadFile,
    [string] $DownloadFilePattern = "NOT_TO_BE_FOUND"
)

$latestRelease = Invoke-RestMethod -Method Get -Uri https://api.github.com/repos/$Repository/releases/latest -StatusCodeVariable sc

if ($sc -eq 200) {
    Write-Host $latestRelease.tag_name $latestRelease.published_at
    foreach ($asset in $latestRelease.assets) {
        Write-Host $asset.name $asset.size
        if($asset.name -eq $DownloadFile -or $asset.name -match $DownloadFilePattern) {
            $target = Join-Path $env:TEMP $DownloadFile
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target
            Write-Host "downloaded" $asset.browser_download_url "to" $target
        }
    }
}
```
