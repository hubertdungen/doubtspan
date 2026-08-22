param([string]$Version = "0.1.0-local")
$ErrorActionPreference = "Stop"
$root=$PSScriptRoot
$dist=Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$zip=Join-Path $dist ("DoubtSpan-v{0}.zip" -f $Version)
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
$files=@(
    "DoubtSpan.ps1",
    "DoubtSpan.ini",
    "Run-DoubtSpan.cmd",
    "Fix-Current-DoubtSpan-Window.cmd",
    "Restore-DoubtSpan-Desktop.cmd",
    "README.md",
    "LICENSE",
    "assets"
) | ForEach-Object { Join-Path $root $_ }
Compress-Archive -LiteralPath $files -DestinationPath $zip -CompressionLevel Optimal
$hash=(Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
Write-Output "Package: $zip"
Write-Output "SHA-256: $hash"
