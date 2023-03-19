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