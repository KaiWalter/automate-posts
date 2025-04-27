# select dev.to API key
# extract PowerShell environment variable field
# set environment variables

$entry = op item get "dev.to ops.io API key" `
  --account my `
  --fields label=ps `
  --format json | ConvertFrom-Json
Invoke-Expression $entry.value
