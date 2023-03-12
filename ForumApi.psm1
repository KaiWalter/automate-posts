function Update-Forum {
    [CmdletBinding()]
    param (
        $headers,
        $baseUrl,
        $title,
        $tags,
        $postBody,
        $published = $false
    )

    $articles = Invoke-RestMethod -Method Get `
        -Uri $($baseUrl + "/me/all?per_page=10000") `
        -Headers $headers `
        -SkipHttpErrorCheck `
        -StatusCodeVariable statusCode

    if ($statusCode -eq 200) {
        $existingArticle = $articles | Where-Object { $_.title -eq $title }
    }
    else {
        Write-Host "GET" $baseUrl $statusCode
        return
    }

    $request = @{
        "article" = @{
            "title"         = $title
            "body_markdown" = $postBody
            "published"     = $published
            "tags"          = $($tags -split ",")
        }
    } | ConvertTo-Json -EscapeHandling EscapeHtml
    
    if ($existingArticle) {
        Invoke-RestMethod -Method Put -Uri $($baseUrl + "/" + $existingArticle.id) `
            -Headers $headers `
            -Body $request `
            -SkipHttpErrorCheck `
            -StatusCodeVariable statusCode

        Write-Host "PUT" $baseUrl $statusCode
    }
    else {
        Invoke-RestMethod -Method Post -Uri $baseUrl `
            -Headers $headers `
            -Body $request `
            -SkipHttpErrorCheck `
            -StatusCodeVariable statusCode

        Write-Host "POST" $baseUrl $statusCode
    }

}
