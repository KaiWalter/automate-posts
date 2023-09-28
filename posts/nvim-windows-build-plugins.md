## TL;DR

In this post I show or share 

- a PowerShell script to install LLVM / mingw  / make toolchains on Windows to be used by NeoVim plugin build processes
- how to install Microsoft Build Tools with **winget** (that in the end did not qualify for all build cases and was discarded)
- a sample plugin configurations with **Lazy** plugin manager
- an observations I made with plugin managers not working smoothly through corporate proxy configurations

## Motivation

I just want to have equal editing experience on Windows and Linux - not having myself to adapt when flipping back and forth. With an ecosystem like Visual Studio Code that is practically given without the need to care. But that's not how I am wired - I want to understand what's going on. Here imho NeoVim with Lua plugins is easier to digest and understand.

## Background

In a [previous post](https://dev.to/kaiwalter/share-neovim-configuration-between-linux-and-windows-4gh8) I was showing how I was sharing one configuration for NeoVim based on one version of dotfiles in Linux and Windows.

That works pretty well for [Lua](https://www.lua.org/)-only plugins, as long as underlying command line tools like e.g. `ripgrep`  or `lazygit` are also avaible on Windows. As soon as plugins require a tool chain to build those command line tools from source, some more work is required.

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

Yet this setup was not sufficient for **Telescope/fzf**, as only a **clang** but obviously no **gcc** compiler seemed to be available with MS Build Tools. I succeeded when adding a **gcc** into the mix, but was not really happy with the extra "Visual Studio Developer PowerShell" command prompt required.

### LLVM/Clang/LLD based mingw-w64

In this toolchain I found **clang** and **gcc** compilers. Also it allowed me to just add it to the path (see script `NeoVimPluginInstall.ps1` below) of my current shell when directing NeoVim into a plugin installation - without an extra command prompt like above.

That helped me to use the same build process configuration for **Telescope/fzf** on Linux and Windows without any changes:

```
return {
	"nvim-telescope/telescope.nvim",
	branch = "0.1.x",
	dependencies = {
		"nvim-lua/plenary.nvim",
		{
			"nvim-telescope/telescope-fzf-native.nvim",
			build = "make", -- <<===== make initiates build process on Windows and Linux
		},
		"nvim-tree/nvim-web-devicons",
	},
	config = function() 
...
```

> In the case of this plugin I tried to modify the `build` string from `make` to `cmake -S. -Bbuild -DCMAKE_BUILD_TYPE=Release && cmake --build build --config Release && cmake --install build --prefix build` when running on Windows, but even with this small patch I was not able to cleanly succeed with MS Build Tools.

## NeoVim installation script

Since my [previous post](https://dev.to/kaiwalter/share-neovim-configuration-between-linux-and-windows-4gh8) I extended and hardened the installation script a bit. It now additionally installs

- **ripgrep** for Telescope `live_grep` string finder
- **lazygit** for the equally named plugin
- **Gnu make** to drive some of the build processes
- **llvm-mingw64** the [LLVM/Clang/LLD based mingw-w64 toolchain](https://github.com/mstorsjo/llvm-mingw) from above

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
> script `.\getLatestGithubRepo.ps1` downloads the latest binary / installation file from a GitHub's repo release page and is shown below

## Lua configuration

When I started with my NeoVim journey a few months back, I followed the suggestions from the NeoVim main protagonists and looked into some of the NeoVim [distros](https://medium.com/@adaml.poniatowski/exploring-the-top-neovim-distributions-lazyvim-lunarvim-astrovim-and-nvchad-which-one-reigns-3adcdbfa478d) like [LazyVim](https://www.lazyvim.org/),  [LunarVim](https://www.lunarvim.org/), [AstroVim](https://astronvim.com/), and [NVChad](https://nvchad.com/) to make life easier (coming fresh from Visual Studio Code even to make life even bearable). Having no knowledge in the NeoVim plugin ecosystem I struggled and stopped to try to get these distros working in parallel on Linux and Windows. Hence I decided to build a configuration with **Packer** from scratch to find and understand the spots, where it breaks.

While succeeding in getting NeoVim working smoothly with plugins on my own Windows machines, I struggled on my company laptop. Plugin installation with **Packer** was lagging at best sometimes even hanging. Digging deeper I was able to pin the problem to our companies proxy which was interfering in the package downloads.

Anyway as of August'23 it is announced on the [Packer](https://github.com/wbthomason/packer.nvim) repo README, that it is not maintained anymore and suggested to move to another package manager.

[lazy.nvim](https://github.com/folke/lazy.nvim) seemed to be the next best one package manager for me - also **LazyVim** distro which is based on that package manager and which I checked out earlier best related to what I was looking for. Additionally the download problems with our company proxy did not manifest here.

When converting from **Packer** to **Lazy** I wanted to clean up my configuraton file structure and follow some good practise (which is always subjective, I know) and hence I leaned on the [NeoVim configuration of Josean Martinez](https://github.com/josean-dev/dev-environment-files) which he explains in this [video](https://youtu.be/NL8D8EkphUw):

```
~/.config/nvim $ tree -n --charset UTF-16
|-- init.lua
|-- lazy-lock.json
`-- lua
    `-- kws
        |-- init.lua
        |-- lazy.lua
        |-- plugins
        |   |-- colorschema.lua
        |   |-- comment.lua
        |   |-- dap.lua
        |   |-- dressing.lua
        |   |-- harpoon.lua
        |   |-- init.lua
        |   |-- lsp
        |   |   |-- lspconfig.lua
        |   |   |-- mason.lua
        |   |   `-- null-ls.lua
        |   |-- lualine.lua
        |   |-- nvim-cmp.lua
        |   |-- nvim-tree.lua
        |   |-- nvim-treesitter.lua
        |   |-- nvim-treesitter-text-objects.lua
        |   |-- telescope.lua
        |   `-- which-key.lua
        |-- remap.lua
        `-- utils.lua
```

So basically `lazy.lua` just bootstraps the package manager itself and then pulls in the plugin specifications from `plugins` and `plugins/lsp` folders.

## utility scripts

### NeoVimPluginInstall.ps1

While the setup PowerShell script above installs all the tools, I created another script which I use when starting NeoVim with the intention to install or update plugins. I did not want to put these folders on my search path permanently to not pollute the search path too much.

```
$llvmPath = Join-Path $(Get-ChildItem -Path $env:LOCALAPPDATA -Filter "llvm*x86_64" | Select-Object -ExpandProperty FullName) "bin"
$makePath = Join-Path ${env:ProgramFiles(x86)} "GnuWin32" "bin"
$env:Path += ";" + $llvmPath + ";" + $makePath
nvim $args
```

### getLatestGithubRepo.ps1

This script is a generalization of another [post](https://community.ops.io/kaiwalter/install-winget-latest-release-with-powershell-in-one-go-3kka) to find and download a file with a given complete file name or a file pattern from a GitHub repo's latest releases:

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

----

## The End

With this setup I am content for the moment. From here I will add LSP servers, stylers, linters and other plugins I expect to improve my productivity. Working exclusively with NeoVim for my very few coding workloads now for ~4 months gives me enough proficiency to really enjoy editing code in my spare time. If I just could have VIM motions in MS Outlook and MS Word :smirk: I would not need to reconfigure my brain when switching from day job to spare time activity.
