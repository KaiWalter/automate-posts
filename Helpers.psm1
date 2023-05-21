function Get-TagMapping {
    [CmdletBinding()]
    param (
        $tagMapping,
        $tags,
        $forum
    )

    if ($forum -eq "hashnode") {
        $tagMapping.GetEnumerator() | 
        ? { $_.Key -match $tags } | 
        % {
            foreach ($f in $_.Value.GetEnumerator()) {
                if ($f.Key -eq $forum ) {
                    $f.Value
                }
            }
        } | ConvertTo-Json -AsArray
    }
    else {
        $tagMapping.GetEnumerator() | 
        ? { $_.Key -match $tags } | 
        % {
            foreach ($f in $_.Value.GetEnumerator()) {
                if ($f.Key -eq $forum ) {
                    $f.Value
                }
            }
        } | Join-String -Separator ","
    }
}

function Get-PlatformReplacements {
    [CmdletBinding()]
    param (
        $postBody,
        $replacements,
        $forum
    )

    if ($replacements[$forum]) {
        foreach ($sr in $replacements[$forum]) {
            $postBody = $postBody.Replace($sr.search, $sr.replace)
        }
    }

    return $postBody
}
