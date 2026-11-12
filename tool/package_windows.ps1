$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$releaseDirectory = Join-Path $projectRoot 'build/windows/x64/runner/Release'
$archivePath = Join-Path $projectRoot 'build/Zubair-Khata-1.0.0-Windows-x64.zip'
foreach ($requiredFile in @('zubair_khata_management.exe', 'flutter_windows.dll', 'data/app.so')) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory $requiredFile))) {
        throw 'Build the Windows release before packaging: flutter build windows --release --no-pub'
    }
}
if (Test-Path -LiteralPath $archivePath) {
    Remove-Item -LiteralPath $archivePath
}
[System.IO.Compression.ZipFile]::CreateFromDirectory(
    $releaseDirectory, $archivePath,
    [System.IO.Compression.CompressionLevel]::Fastest, $false
)
Get-Item -LiteralPath $archivePath | Select-Object FullName, Length
