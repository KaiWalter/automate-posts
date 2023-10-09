#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Create posts on dev.to and ops.io
.DESCRIPTION
    Based on content and metadata this script will create posts on dev.to and ops.io.
#>

[CmdletBinding()]
param (
  [Parameter(Mandatory = $true,
    ValueFromPipeline = $true,
    HelpMessage = 'Lowercase, alphabetic name of post')]
  [ValidatePattern('^[a-z\-]+$')]
  [string]$PostName,
  [string]$GitHubBlobRoot = "https://raw.githubusercontent.com/KaiWalter/automate-posts/main/"
)

$ErrorActionPreference = "Stop"

Import-Module ./Helpers.psm1
Import-Module ./ForumApi.psm1
Import-Module ./HashnodeApi.psm1

# ----- INIT
# assume that API keys have been set as environment variables
$devtoHeaders = @{"api-key" = $env:DEVTOAPIKEY; "content-type" = "application/json" }
$opsioHeaders = @{"api-key" = $env:OPSIOAPIKEY; "content-type" = "application/json" }
$hashnodeHeaders = @{"Authorization" = $env:HASHNODETOKEN; "content-type" = "application/json" }
$hashnodePublicationId = $env:HASHNODEPUBLICATIONID
$hashnodeUsername = $env:HASHNODEUSERNAME
$tagMapping = Get-Content ./tagMapping.json | ConvertFrom-Json -AsHashtable

# ----- CONTENT
$postDefinition = Get-Content $(Join-Path "." "posts" $($PostName + ".json") -Resolve) | ConvertFrom-Json -Depth 10 -AsHashtable

$title = $postDefinition.title
$selectedTags = "(" + $($postDefinition.tags -replace ",\s+", "|") + ")"

if ($postDefinition.banner100x42)
{
  if (!(Test-Path $postDefinition.banner100x42))
  {
    Write-Host "Banner image not found: $($postDefinition.banner100x42)"
    return
  }
}

if ($postDefinition.content)
{
  if (!(Test-Path $postDefinition.content))
  {
    Write-Host "Content file not found: $($postDefinition.content)"
    return
  }
}

$coverImageUrl = $GitHubBlobRoot + $postDefinition.banner100x42

$postContent = Get-Content $postDefinition.content -Raw
$postContent = $postContent.Replace("../images/", $($GitHubBlobRoot + "images/"))

# ----- platform dependent replacements
$postDevToContent = Get-PlatformReplacements -postBody $postContent -replacements $postDefinition.replacements -forum "devto"
$postOpsIoContent = Get-PlatformReplacements -postBody $postContent -replacements $postDefinition.replacements -forum "opsio"
$postHashnodeContent = Get-PlatformReplacements -postBody $postContent -replacements $postDefinition.replacements -forum "hashnode"

# ----- POST

$tags = Get-TagMapping -tagMapping $tagMapping -tags $selectedTags -forum "devto"
$devtoResponse = Update-Forum  -baseUrl "https://dev.to/api/articles"`
  -postBody $postDevToContent `
  -title $title `
  -coverImageUrl $coverImageUrl `
  -tags $tags `
  -published $postDefinition.published `
  -headers $devtoHeaders

$tags = Get-TagMapping -tagMapping $tagMapping -tags $selectedTags -forum "opsio"
$opsioResponse = Update-Forum -baseUrl "https://community.ops.io/api/articles"`
  -postBody $postOpsIoContent `
  -title $title `
  -coverImageUrl $coverImageUrl `
  -tags $tags `
  -published $postDefinition.published `
  -headers $opsioHeaders

# if ($postDefinition.published) {
#
#     $tags = Get-TagMapping -tagMapping $tagMapping -tags $selectedTags -forum "hashnode"
#     Update-HashNode -baseUrl "https://api.hashnode.com"`
#         -postBody $postHashnodeContent `
#         -title $title `
#         -subtitle $description `
#         -coverImageUrl $coverImageUrl `
#         -tags $tags `
#         -headers $hashnodeHeaders `
#         -hashnodePublicationId $hashnodePublicationId `
#         -hashnodeUsername $hashnodeUsername
#         
# }
