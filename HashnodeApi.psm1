#https://dev.to/codybontecou/post-to-dev-hashnode-and-medium-using-their-apis-54k4

function Update-HashNode {
  [CmdletBinding()]
  param (
    $headers,
    $baseUrl,
    $title,
    $coverImageUrl,
    $canonicalUrl,
    $tags,
    $postBody,
    $hashnodePublicationId,
    $hashnodeUsername
  )

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
    -Headers $headers `
    -SkipHttpErrorCheck `
    -StatusCodeVariable statusCode

  if ($statusCode -eq 200) {
    $existingArticle = $articles.data.user.publication.posts | Where-Object { $_.title -eq $title }
  }
  else {
    Write-Host "POST" $baseUrl $statusCode
    $articles.errors | ConvertTo-Json
    return
  }

  if ($existingArticle) {
    $postRequest = 'mutation createStory($postId: String!, $input: UpdateStoryInput!) { updateStory(postId: $postId, input: $input) { code success message } }'
    $postRequestBody = @{
      query     = $postRequest
      variables = @{
        input  = @{
          title               = $title
          contentMarkdown     = $postBody
          coverImageURL       = $coverImageUrl
          tags                = $($tags | ConvertFrom-Json)
          isPartOfPublication = @{
            publicationId = $hashnodePublicationId     
          }
        }
        postId = $existingArticle._id
      }
    } | ConvertTo-Json -Depth 5 -Compress

  }
  else {
    $postRequest = 'mutation createStory($input: CreateStoryInput!) { createStory(input: $input) { code success message } }'

    $postRequestBody = @{
      query     = $postRequest
      variables = @{
        input = @{
          title               = $title
          contentMarkdown     = $postBody
          tags                = $($tags | ConvertFrom-Json)
          isPartOfPublication = @{
            publicationId = $hashnodePublicationId     
          }
        }
      }
    } | ConvertTo-Json -Depth 5 -Compress
  }

  $postResponse = Invoke-RestMethod -Method Post `
    -Uri $baseUrl `
    -Body $postRequestBody `
    -Headers $headers `
    -SkipHttpErrorCheck `
    -StatusCodeVariable statusCode
    
  if ($postResponse.errors) {
    Write-Host "POST" $postRequest $statusCode
    $postResponse.errors | ConvertTo-Json
  }
  else {
    Write-Host "POST" $postRequest $statusCode
    $postResponse | ConvertTo-Json
  }
}