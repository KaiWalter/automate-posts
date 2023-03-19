## Motivation

I now work with Visual Studio Code for several years in many different workloads:
- Azure scripting in Azure CLI and PowerShell
- .NET development
- Python development
- Go development
- Bash scripting
- ...

With that I collected a numbers of extensions in Visual Studio Code - before writing this article : 53.

## Prerequisites

![Visual Studio Code profiles that need to be created before running the sample script](../images/vscode-profiles.png)

```PowerShell
param(
    [string] $ProfilePattern = ".*",
    [switch] $Clear,
    [switch] $Install
)

$config = @{
    "Default" = @("humao.rest-client")
    "pwsh"    = @("ms-vscode.powershell")
    "py"      = @("ms-python.python")
    "az"      = @("humao.rest-client", "ms-vscode.azure-account", "ms-vscode.azurecli")
    "dotnet"  = @("humao.rest-client", "ms-dotnettools.csharp")
}

if ($Clear) {
    foreach ($p in ($config.Keys | ? { $_ -match $ProfilePattern })) {
        Write-Host "clear profile" $p
        code --profile $p --list-extensions | % { code --profile $p --uninstall-extension $_ --force }
    }
}

if ($Install) {
    foreach ($p in ($config.Keys | ? { $_ -match $ProfilePattern })) {
        Write-Host "install profile" $p "extensions"
        foreach ($e in $config[$p]) {
            code --profile $p --install-extension $e --force
        }
    }
}
```