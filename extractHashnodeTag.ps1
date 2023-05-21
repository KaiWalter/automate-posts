$ErrorActionPreference = "Stop"

# ----- INIT
# assume that API keys have been set as environment variables
$hashnodeHeaders = @{"Authorization" = $env:HASHNODETOKEN; "content-type" = "application/json" }
$hashnodePublicationId = $env:HASHNODEPUBLICATIONID
$hashnodeUsername = $env:HASHNODEUSERNAME

$baseUrl = "https://api.hashnode.com"

$query = 'query GetUserArticles($page: Int!) { user(username: "' + $hashnodeUsername + '") { publication { posts(page: $page) { _id title slug } } } }'

$queryBody = @{
  query     = $query
  variables = @{
    page = 0
  }
} | ConvertTo-Json

$articles = Invoke-RestMethod -Method Post `
  -Uri $baseUrl `
  -Body $queryBody `
  -Headers $hashnodeHeaders `
  -SkipHttpErrorCheck `
  -StatusCodeVariable statusCode

if ($statusCode -eq 200) {
    $articles | ConvertTo-Json -Depth 10 | code -
}