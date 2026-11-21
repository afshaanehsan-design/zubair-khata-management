# Builds a signed MSIX of the Windows release and puts everything needed to
# install it on another PC into one folder (release-msix/ by default).
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_msix.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/build_msix.ps1 -SkipBuild
#
# The first run creates a self-signed code-signing certificate for
# "CN=Zubair Traders" and keeps its private key in
# release-msix/signing-key-keep-private/. Later runs reuse it, so devices that
# already trust the certificate accept updates without re-importing it.
# Keep that folder safe and never copy it to other PCs.
param(
    [string]$OutputDirectory = '',
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $projectRoot 'release-msix' }
$OutputDirectory = [System.IO.Path]::GetFullPath($OutputDirectory)

$publisher = 'CN=Zubair Traders'
$publisherDisplayName = 'Zubair Traders'
$packageName = 'ZubairTraders.ZubairKhata'
$displayName = 'Zubair Khata'
$description = 'Offline-first bilingual LPG accounts, stock and business management.'
$exeName = 'zubair_khata_management.exe'
$packageFile = 'ZubairKhata.msix'
$certFile = 'ZubairTraders.cer'

# --- Windows SDK tools -------------------------------------------------------
$kits = 'C:\Program Files (x86)\Windows Kits\10\bin'
$sdkBin = Get-ChildItem $kits -Directory |
    Where-Object { $_.Name -match '^10\.' -and (Test-Path (Join-Path $_.FullName 'x64\makeappx.exe')) } |
    Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $sdkBin) { throw 'Windows 10/11 SDK (makeappx.exe, signtool.exe) not found.' }
$makeappx = Join-Path $sdkBin.FullName 'x64\makeappx.exe'
$signtool = Join-Path $sdkBin.FullName 'x64\signtool.exe'
$makepri = Join-Path $sdkBin.FullName 'x64\makepri.exe'
if (-not (Test-Path -LiteralPath $makepri)) { throw "makepri.exe not found in $($sdkBin.FullName)\x64" }

# --- Version from pubspec: 1.2.3+4 -> 1.2.3.4 --------------------------------
$versionLine = Select-String -Path (Join-Path $projectRoot 'pubspec.yaml') -Pattern '^version:\s*(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?' | Select-Object -First 1
if (-not $versionLine) { throw 'No version in pubspec.yaml' }
$g = $versionLine.Matches[0].Groups
$build = if ($g[4].Success) { $g[4].Value } else { '0' }
$version = "$($g[1].Value).$($g[2].Value).$($g[3].Value).$build"

# --- Release build ------------------------------------------------------------
$releaseDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'
if (-not $SkipBuild) {
    Push-Location $projectRoot
    try {
        flutter build windows --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
    } finally { Pop-Location }
}
foreach ($requiredFile in @($exeName, 'flutter_windows.dll', 'data\app.so')) {
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory $requiredFile))) {
        throw 'Build the Windows release first: flutter build windows --release --no-pub'
    }
}

# --- Certificate ----------------------------------------------------------------
$keyDirectory = Join-Path $OutputDirectory 'signing-key-keep-private'
$pfxPath = Join-Path $keyDirectory 'ZubairTraders-signing.pfx'
$passwordPath = Join-Path $keyDirectory 'pfx-password.txt'
New-Item -ItemType Directory -Force $keyDirectory | Out-Null
if (-not (Test-Path -LiteralPath $pfxPath)) {
    Write-Host 'Creating self-signed code-signing certificate...'
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $plainPassword = [Convert]::ToBase64String($bytes)
    $cert = New-SelfSignedCertificate -Type Custom -Subject $publisher `
        -KeyUsage DigitalSignature -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 `
        -FriendlyName 'Zubair Khata MSIX signing' `
        -CertStoreLocation 'Cert:\CurrentUser\My' `
        -NotAfter (Get-Date).AddYears(25) `
        -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $securePassword | Out-Null
    Set-Content -LiteralPath $passwordPath -Value $plainPassword -Encoding ascii -NoNewline
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($cert.Thumbprint)"
}
$plainPassword = (Get-Content -LiteralPath $passwordPath -Raw).Trim()
$pfx = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
    $pfxPath, $plainPassword, [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable)
if ($pfx.Subject -ne $publisher) { throw "Certificate subject '$($pfx.Subject)' is not '$publisher'" }
[System.IO.File]::WriteAllBytes((Join-Path $OutputDirectory $certFile),
    $pfx.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))

# --- Package layout -----------------------------------------------------------------
$layout = Join-Path $projectRoot 'build\msix\layout'
if (Test-Path -LiteralPath $layout) { Remove-Item -LiteralPath $layout -Recurse -Force }
New-Item -ItemType Directory -Force $layout | Out-Null
Copy-Item -Path (Join-Path $releaseDirectory '*') -Destination $layout -Recurse

# Visual C++ runtime, so the app starts on PCs that do not have it installed.
foreach ($dll in @('msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    $source = Join-Path $env:WINDIR "System32\$dll"
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $layout }
}

# Logos, drawn from the one Zubair Khata mark (tool/logo.ps1) at every size
# Windows asks for, so none is a scaled copy. The names carry MRT qualifiers
# and resources.pri (made below) tells Windows which file is which:
#   targetsize-N_altform-unplated   taskbar, Start, Alt+Tab, Explorer (rounded)
#   targetsize-N / scale-N          the same on a coloured plate (full square)
#   Square150x150 / Wide310x150     Start tiles; StoreLogo: the installer
. (Join-Path $PSScriptRoot 'logo.ps1')
$assets = Join-Path $layout 'Assets'
New-Item -ItemType Directory -Force $assets | Out-Null
foreach ($scale in @(100, 125, 150, 200, 400)) {
    $f = $scale / 100
    $px = { param($n) [int][Math]::Round($n * $f, [MidpointRounding]::AwayFromZero) }
    Save-KhataPng -Path (Join-Path $assets "Square44x44Logo.scale-$scale.png") -Width (& $px 44)
    Save-KhataPng -Path (Join-Path $assets "Square150x150Logo.scale-$scale.png") -Width (& $px 150)
    Save-KhataPng -Path (Join-Path $assets "Wide310x150Logo.scale-$scale.png") -Width (& $px 310) -Height (& $px 150)
    Save-KhataPng -Path (Join-Path $assets "StoreLogo.scale-$scale.png") -Width (& $px 50) -Rounded
}
foreach ($size in @(16, 20, 24, 30, 32, 36, 40, 44, 48, 60, 64, 72, 80, 96, 256)) {
    Save-KhataPng -Path (Join-Path $assets "Square44x44Logo.targetsize-$size.png") -Width $size
    Save-KhataPng -Path (Join-Path $assets "Square44x44Logo.targetsize-${size}_altform-unplated.png") -Width $size -Rounded
    Save-KhataPng -Path (Join-Path $assets "Square44x44Logo.targetsize-${size}_altform-lightunplated.png") -Width $size -Rounded
}

# Manifest. File-system and registry write virtualization are switched off
# (unvirtualizedResources), so the khata stays in the real
# %APPDATA%\Zubair Traders\Zubair Khata: the same data as the zip build, and
# uninstalling the app never deletes it.
$manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<Package
  xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  xmlns:desktop6="http://schemas.microsoft.com/appx/manifest/desktop/windows10/6"
  IgnorableNamespaces="uap rescap desktop6">
  <Identity Name="$packageName" Publisher="$publisher" Version="$version" ProcessorArchitecture="x64" />
  <Properties>
    <DisplayName>$displayName</DisplayName>
    <PublisherDisplayName>$publisherDisplayName</PublisherDisplayName>
    <Description>$description</Description>
    <Logo>Assets\StoreLogo.png</Logo>
    <desktop6:FileSystemWriteVirtualization>disabled</desktop6:FileSystemWriteVirtualization>
    <desktop6:RegistryWriteVirtualization>disabled</desktop6:RegistryWriteVirtualization>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="10.0.19041.0" MaxVersionTested="10.0.26100.0" />
  </Dependencies>
  <Resources>
    <Resource Language="en-us" />
  </Resources>
  <Applications>
    <Application Id="ZubairKhata" Executable="$exeName" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="$displayName" Description="$description"
        BackgroundColor="transparent" Square150x150Logo="Assets\Square150x150Logo.png"
        Square44x44Logo="Assets\Square44x44Logo.png">
        <uap:DefaultTile Wide310x150Logo="Assets\Wide310x150Logo.png" />
      </uap:VisualElements>
    </Application>
  </Applications>
  <Capabilities>
    <Capability Name="internetClient" />
    <rescap:Capability Name="runFullTrust" />
    <rescap:Capability Name="unvirtualizedResources" />
  </Capabilities>
</Package>
"@
Set-Content -LiteralPath (Join-Path $layout 'AppxManifest.xml') -Value $manifest -Encoding utf8

# resources.pri: the index of the qualified logo files, named as the manifest
# asks for them (Files/Assets/...). The index starts at the package root,
# because starting at Assets drops "Assets/" from the names; the app opens its
# own files by path, so their being indexed too changes nothing. No
# <packaging> section, so nothing is split into resource packages.
$priConfig = Join-Path $projectRoot 'build\msix\priconfig.xml'
Set-Content -LiteralPath $priConfig -Encoding utf8 -Value @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<resources targetOsVersion="10.0.0" majorVersion="1">
  <index root="\" startIndexAt="\">
    <default>
      <qualifier name="Language" value="en-US"/>
      <qualifier name="Contrast" value="standard"/>
      <qualifier name="Scale" value="100"/>
      <qualifier name="HomeRegion" value="001"/>
      <qualifier name="TargetSize" value="256"/>
      <qualifier name="LayoutDirection" value="LTR"/>
      <qualifier name="Theme" value="dark"/>
      <qualifier name="AlternateForm" value=""/>
      <qualifier name="DXFeatureLevel" value="DX9"/>
      <qualifier name="Configuration" value=""/>
      <qualifier name="DeviceFamily" value="Universal"/>
      <qualifier name="Custom" value=""/>
    </default>
    <indexer-config type="folder" foldernameAsQualifier="true" filenameAsQualifier="true" qualifierDelimiter="."/>
  </index>
</resources>
'@
& $makepri new /pr $layout /cf $priConfig /mn (Join-Path $layout 'AppxManifest.xml') /of (Join-Path $layout 'resources.pri') /o | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'makepri failed' }

# --- Pack and sign ----------------------------------------------------------------
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$packagePath = Join-Path $OutputDirectory $packageFile
if (Test-Path -LiteralPath $packagePath) { Remove-Item -LiteralPath $packagePath }
& $makeappx pack /d $layout /p $packagePath /o
if ($LASTEXITCODE -ne 0) { throw 'makeappx failed' }
& $signtool sign /fd SHA256 /f $pfxPath /p $plainPassword $packagePath
if ($LASTEXITCODE -ne 0) { throw 'signtool failed' }

# --- Installer files ----------------------------------------------------------------
$installPs1 = @"
# Trusts the Zubair Traders certificate on this PC and installs Zubair Khata.
`$ErrorActionPreference = 'Stop'
`$here = Split-Path -Parent `$MyInvocation.MyCommand.Path
`$cer = Join-Path `$here '$certFile'
`$msix = Join-Path `$here '$packageFile'
try {
    `$thumbprint = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 `$cer).Thumbprint
    if (-not (Test-Path "Cert:\LocalMachine\TrustedPeople\`$thumbprint")) {
        # Only this step needs administrator rights; the app itself is
        # installed below for the signed-in user.
        Write-Host 'Trusting the Zubair Traders certificate (administrator prompt)...'
        `$command = "Import-Certificate -FilePath '`$cer' -CertStoreLocation Cert:\LocalMachine\TrustedPeople"
        `$process = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', `$command)
        if (-not (Test-Path "Cert:\LocalMachine\TrustedPeople\`$thumbprint")) { throw 'The certificate was not added to Trusted People.' }
    }
    Write-Host 'Installing Zubair Khata...'
    Add-AppxPackage -Path `$msix -ForceUpdateFromAnyVersion
    Write-Host ''
    Write-Host 'Done. Open Zubair Khata from the Start menu.' -ForegroundColor Green
} catch {
    Write-Host ''
    Write-Host "Install failed: `$(`$_.Exception.Message)" -ForegroundColor Red
}
Read-Host 'Press Enter to close'
"@
Set-Content -LiteralPath (Join-Path $OutputDirectory 'Install.ps1') -Value $installPs1 -Encoding utf8

$installCmd = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0Install.ps1`"`r`n"
Set-Content -LiteralPath (Join-Path $OutputDirectory 'Install.cmd') -Value $installCmd -Encoding ascii -NoNewline

$readme = @"
Zubair Khata $version - Windows installer (MSIX)
=================================================

Copy these files to the other PC (all in one folder):

  $packageFile        the app
  $certFile     the publisher certificate that makes Windows trust it
  Install.cmd            double-click to install
  Install.ps1            used by Install.cmd

Install
-------
1. Double-click Install.cmd and allow the administrator prompt (shown only
   the first time). It adds $certFile to "Trusted People" of the local
   computer, then installs $packageFile for the signed-in Windows user.
2. Open "Zubair Khata" from the Start menu.

Manual install (same result): double-click $certFile > Install Certificate >
Local Machine > "Place all certificates in the following store" > Trusted People.
Then double-click $packageFile and press Install.

Updates: run Install.cmd from a newer folder. Data is kept.

Data stays in %APPDATA%\Zubair Traders\Zubair Khata, the same place as the
zip version, and uninstalling the app does not delete it. Make a backup
from Settings before moving to a new PC.

Requires Windows 10 version 2004 (build 19041) or later, 64-bit.

DO NOT copy the folder "signing-key-keep-private" to other PCs or share it.
It holds the private key: anyone who has it can sign programs that every PC
trusting this certificate will accept. Keep it (backed up) on the build PC so
future versions are signed with the same certificate.
"@
Set-Content -LiteralPath (Join-Path $OutputDirectory 'README.txt') -Value $readme -Encoding utf8

Get-ChildItem -LiteralPath $OutputDirectory -Recurse -File | Select-Object FullName, Length
