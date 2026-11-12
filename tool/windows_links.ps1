$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = Join-Path $projectRoot '.flutter-plugins-dependencies'
if (-not (Test-Path -LiteralPath $manifest)) { throw 'Run flutter pub get first.' }
$plugins = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
$linkRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot 'windows/flutter/ephemeral/.plugin_symlinks'))
if (-not $linkRoot.StartsWith($projectRoot + [System.IO.Path]::DirectorySeparatorChar)) { throw 'Invalid workspace link path.' }
New-Item -ItemType Directory -Force -Path $linkRoot | Out-Null
foreach ($plugin in $plugins.plugins.windows) {
    $link = Join-Path $linkRoot $plugin.name
    if (-not (Test-Path -LiteralPath $link)) {
        New-Item -ItemType Junction -Path $link -Target $plugin.path | Out-Null
    }
}
Write-Output 'Plugin links are ready. No Windows settings were changed.'
