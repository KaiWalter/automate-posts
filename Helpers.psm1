function Get-TagMapping {
    [CmdletBinding()]
    param (
        $tagMapping,
        $tags,
        $forum
    )
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