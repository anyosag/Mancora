# Builds MancoraViewer.exe and mancora.exe, stages them with the Swift and
# Visual C++ runtimes, checks that the staged copy runs on its own, and
# packages:
#   Mancora-<version>-Windows-x64-Setup.exe    (Inno Setup installer)
#   Mancora-<version>-Windows-x64-portable.zip
#
#   pwsh Tools/package/windows/package.ps1 [-Output dist] [-TestInstall]
#
# Needs a Swift 6.2 toolchain, Visual Studio (for rc.exe and the C++
# runtime) and Inno Setup 6 (installed with Chocolatey if missing).
param(
    [string]$Output = "",
    [switch]$TestInstall
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-Checked([scriptblock]$Command) {
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "Command failed (exit code $LASTEXITCODE): $Command" }
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $Output) { $Output = Join-Path $root 'dist' }
New-Item -ItemType Directory -Force $Output | Out-Null
$Output = (Resolve-Path $Output).Path
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$fixture = Join-Path $root 'Tests\Fixtures\tiff\ij-hyperstack-16bit.tif'

Write-Host "==> Compiling the icon resource"
$rc = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\rc.exe" |
    Sort-Object FullName | Select-Object -Last 1
if (-not $rc) { throw 'rc.exe not found; install the Windows SDK.' }
$res = Join-Path $Output 'mancora.res'
Push-Location $root
try { Invoke-Checked { & $rc.FullName /nologo /fo $res 'Tools\package\windows\mancora.rc' } }
finally { Pop-Location }

Write-Host "==> Building Mancora $version"
$viewerPackage = Join-Path $root 'Apps\Windows'
Invoke-Checked { swift build -c release --package-path $viewerPackage -Xlinker $res }
$viewerBin = (swift build -c release --package-path $viewerPackage --show-bin-path).Trim()
Invoke-Checked { swift build -c release --package-path $root --product mancora -Xlinker $res }
$cliBin = (swift build -c release --package-path $root --show-bin-path).Trim()

Write-Host "==> Staging"
$stage = Join-Path $Output 'stage'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $viewerBin 'MancoraViewer.exe') $stage
Copy-Item (Join-Path $cliBin 'mancora.exe') $stage

# The Swift runtime the toolchain put on PATH.
$swiftCore = where.exe swiftCore.dll 2>$null | Select-Object -First 1
if (-not $swiftCore) { throw 'swiftCore.dll not found on PATH.' }
$runtime = Split-Path $swiftCore
Write-Host "Swift runtime: $runtime"
Copy-Item (Join-Path $runtime '*.dll') $stage

# The Visual C++ runtime, deployed next to the executables.
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -property installationPath
$crt = Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC\*\x64\Microsoft.VC14*.CRT') -Directory |
    Sort-Object FullName | Select-Object -Last 1
if (-not $crt) { throw 'Visual C++ redistributable files not found.' }
Write-Host "C++ runtime: $($crt.FullName)"
Copy-Item (Join-Path $crt.FullName '*.dll') $stage

Copy-Item -Recurse (Join-Path $root 'Resources\LUTs') (Join-Path $stage 'LUTs')
Copy-Item (Join-Path $root 'LICENSE.txt'), (Join-Path $root 'THIRD_PARTY_NOTICES.md') $stage

Write-Host "==> Checking that the staged files run without the toolchain"
$savedPath = $env:PATH
$env:PATH = "$env:SystemRoot\System32;$env:SystemRoot"
try {
    Invoke-Checked { & (Join-Path $stage 'mancora.exe') --version }
    Invoke-Checked { & (Join-Path $stage 'mancora.exe') info $fixture }
    $viewer = Start-Process -FilePath (Join-Path $stage 'MancoraViewer.exe') `
        -ArgumentList '--smoke-test', "`"$fixture`"" -Wait -PassThru
    if ($viewer.ExitCode -ne 0) { throw "MancoraViewer smoke test failed (exit code $($viewer.ExitCode))" }
} finally {
    $env:PATH = $savedPath
}

Write-Host "==> Creating the portable zip"
$zip = Join-Path $Output "Mancora-$version-Windows-x64-portable.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip

Write-Host "==> Creating the installer"
$iscc = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
if (-not (Test-Path $iscc)) {
    Invoke-Checked { choco install innosetup -y --no-progress }
}
Invoke-Checked {
    & $iscc "/DVersion=$version" "/DStage=$stage" "/DRepo=$root" "/DOutput=$Output" `
        (Join-Path $root 'Tools\package\windows\Mancora.iss')
}
$setup = Join-Path $Output "Mancora-$version-Windows-x64-Setup.exe"

if ($TestInstall) {
    Write-Host "==> Installing and uninstalling silently"
    $installDir = Join-Path ([IO.Path]::GetTempPath()) 'MancoraInstallTest'
    $install = Start-Process -FilePath $setup -Wait -PassThru -ArgumentList `
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=addtopath', "/DIR=`"$installDir`""
    if ($install.ExitCode -ne 0) { throw "Installer failed (exit code $($install.ExitCode))" }
    Invoke-Checked { & (Join-Path $installDir 'mancora.exe') --version }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -notlike "*$installDir*") { throw 'The installer did not add Mancora to PATH.' }
    $uninstall = Start-Process -FilePath (Join-Path $installDir 'unins000.exe') -Wait -PassThru `
        -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART'
    if ($uninstall.ExitCode -ne 0) { throw "Uninstaller failed (exit code $($uninstall.ExitCode))" }
}

Write-Host "==> $setup"
Write-Host "==> $zip"
