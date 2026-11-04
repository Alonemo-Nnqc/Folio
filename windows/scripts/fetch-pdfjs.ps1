# Fetches pdf.js (the reader's PDF engine) into src/Folio.App/Assets/pdfjs. Pinned version and checksum.
# Run once before building; the app project also runs it when the folder is missing.
param([string]$Destination = "$PSScriptRoot\..\src\Folio.App\Assets\pdfjs")
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$version = '6.4.299'
$sha256 = '86269b40170eb41740ea05ad2102d71d33de4f122b34eb2f478be0ea7779c415'
if (Test-Path "$Destination\.version") {
    if ((Get-Content "$Destination\.version") -eq $version) { exit 0 }
}
$work = Join-Path ([IO.Path]::GetTempPath()) "folio-pdfjs-$version"
New-Item -ItemType Directory -Force $work | Out-Null
$tgz = Join-Path $work 'pdfjs.tgz'
Invoke-WebRequest "https://registry.npmjs.org/pdfjs-dist/-/pdfjs-dist-$version.tgz" -OutFile $tgz
# .NET directly: under MSBuild, PowerShell's module path may not reach Get-FileHash.
$stream = [System.IO.File]::OpenRead($tgz)
try { $actual = ([System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($stream)) -replace '-', '').ToLowerInvariant() }
finally { $stream.Dispose() }
if ($actual -ne $sha256) { throw "pdfjs-dist checksum mismatch: $actual" }
tar -xzf $tgz -C $work
$pkg = Join-Path $work 'package'
if (Test-Path $Destination) { Remove-Item -Recurse -Force $Destination }
New-Item -ItemType Directory -Force "$Destination\build", "$Destination\web" | Out-Null
Copy-Item "$pkg\build\pdf.min.mjs", "$pkg\build\pdf.worker.min.mjs" "$Destination\build"
Copy-Item "$pkg\web\pdf_viewer.mjs", "$pkg\web\pdf_viewer.css" "$Destination\web"
Copy-Item -Recurse "$pkg\web\images" "$Destination\web\images"
Copy-Item -Recurse "$pkg\cmaps", "$pkg\standard_fonts", "$pkg\wasm" $Destination
Copy-Item "$pkg\LICENSE" "$Destination\LICENSE"
Set-Content "$Destination\.version" $version
Remove-Item -Recurse -Force $work
Write-Host "pdf.js $version -> $Destination"
