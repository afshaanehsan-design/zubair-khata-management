# Writes the app's icons from the one drawing in tool/logo.ps1:
#   windows/runner/resources/app_icon.ico      window, taskbar and exe icon
#   android/app/src/main/res/mipmap-*/ic_launcher.png
#                                               launcher icon before Android 8
#                                               (8 and later use the adaptive
#                                               icon in mipmap-anydpi-v26)
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/brand.ps1
#
# The MSIX logos are drawn by tool/build_msix.ps1 when it packages.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'logo.ps1')
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

Save-KhataIco -Path (Join-Path $projectRoot 'windows\runner\resources\app_icon.ico')

$res = Join-Path $projectRoot 'android\app\src\main\res'
$densities = [ordered]@{ 'mdpi' = 48; 'hdpi' = 72; 'xhdpi' = 96; 'xxhdpi' = 144; 'xxxhdpi' = 192 }
foreach ($density in $densities.Keys) {
    Save-KhataPng -Path (Join-Path $res "mipmap-$density\ic_launcher.png") -Width $densities[$density] -Rounded
}
