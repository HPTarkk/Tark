function Resolve-ReleaseServer {
    param([string]$RepoRoot, [string]$Server, [bool]$ServerSpecified)

    if (-not $ServerSpecified -and [string]::IsNullOrWhiteSpace($Server)) {
        $path = Join-Path $RepoRoot '.SERVER'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $Server = [IO.File]::ReadAllText($path)
        }
    }
    if ([string]::IsNullOrWhiteSpace($Server)) {
        throw 'Set the release server with -Server, TARK_SERVER, or a user@host line in .SERVER at the repository root.'
    }
    $Server = $Server.Trim()
    if ($Server -notmatch '^[A-Za-z0-9._-]+@[A-Za-z0-9.:_-]+$') {
        throw 'The release server does not look like user@host. Check -Server, TARK_SERVER, or .SERVER.'
    }
    return $Server
}
