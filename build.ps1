<#
    Builds the installable plugin zip and repo.xml on Windows.
    Works in Windows PowerShell 5.1 and PowerShell 7.

    Usage (from the project folder):
        powershell -ExecutionPolicy Bypass -File build.ps1 `
            -BaseUrl  https://github.com/<user>/<repo>/releases/download/v0.1.7 `
            -Homepage https://github.com/<user>/<repo>

    -BaseUrl   where the zip will be downloadable (the GitHub release URL)
    -Homepage  optional project page shown in LMS's plugin list

    The zip holds the contents of JukeboxMoods\ at its root, with forward
    slashes in the paths (LMS on Linux, e.g. piCorePlayer, needs them; the
    built-in Compress-Archive in older PowerShell uses backslashes).
#>
param(
    [Parameter(Mandatory = $true)][string]$BaseUrl,
    [string]$Homepage = ''
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

[xml]$manifest = Get-Content -Raw 'JukeboxMoods\install.xml'
$version = $manifest.extension.version
$zipName = "JukeboxMoods-$version.zip"
$zipPath = Join-Path $PSScriptRoot $zipName
$BaseUrl = $BaseUrl.TrimEnd('/')
if (Test-Path $zipPath) { Remove-Item $zipPath }

# build the zip with forward-slash entry names
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$src = (Resolve-Path 'JukeboxMoods').Path
$archive = [System.IO.Compression.ZipFile]::Open($zipPath, 'Create')
try {
    Get-ChildItem -Path $src -Recurse -File | Where-Object { $_.Name -ne '.DS_Store' } | ForEach-Object {
        $entry = $_.FullName.Substring($src.Length + 1) -replace '\\', '/'
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry) | Out-Null
    }
}
finally {
    $archive.Dispose()
}

$sha  = (Get-FileHash -Algorithm SHA1 $zipPath).Hash.ToLower()
$link = ''
if ($Homepage) { $link = "`r`n`t`t`t<link>$Homepage</link>" }

$xml = @"
<?xml version="1.0"?>
<extensions>
	<details>
		<title lang="EN">Jukebox Moods</title>
	</details>
	<plugins>
		<plugin name="JukeboxMoods" version="$version" minTarget="8.0" maxTarget="*">
			<title lang="EN">Jukebox Moods</title>
			<desc lang="EN">Keeps the music playing when the queue runs out, using tag-based moods you can switch on the fly. Works with Don't Stop The Music. Inspired by Silverjuke.</desc>
			<category>playlists</category>
			<creator>Dennis Swanepoel</creator>$link
			<url>$BaseUrl/$zipName</url>
			<sha>$sha</sha>
		</plugin>
	</plugins>
</extensions>
"@

# UTF-8 without a byte-order mark
[System.IO.File]::WriteAllText((Join-Path $PSScriptRoot 'repo.xml'), $xml, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Built $zipName (sha1 $sha) and repo.xml pointing at $BaseUrl/$zipName"
