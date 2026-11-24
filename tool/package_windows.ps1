param(
    [string]$ReleaseDirectory = 'build/windows/x64/runner/Release',
    [string]$StandardRuntimes = 'build/windows-runtimes-standard/runtimes',
    [string]$OutputDirectory = '.'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$release = Get-Item -LiteralPath $ReleaseDirectory
$standard = Get-Item -LiteralPath $StandardRuntimes
if ($standard.Name -ne 'runtimes') { throw 'Standard runtime directory must be named runtimes' }
$application = @(Get-ChildItem -LiteralPath $release.FullName |
    Where-Object Name -notin 'userdata', 'runtimes')
$required = @('MisaTV.exe', 'apply_windows_delta.ps1', 'data/app.so',
    'data/flutter_assets/AssetManifest.bin', 'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

foreach ($variant in 'lite', 'standard', 'full') {
    $inputs = $application.FullName
    $expected = $required
    if ($variant -ne 'lite') {
        $runtime = if ($variant -eq 'standard') { $standard.FullName } else { Join-Path $release.FullName 'runtimes' }
        $inputs += $runtime
        $manifest = Get-Content -LiteralPath (Join-Path $runtime 'ready.json') -Raw | ConvertFrom-Json
        $expected += @('runtimes/ready.json', "runtimes/jvm/$($manifest.jvm)/bundle.json",
            "runtimes/jvm/$($manifest.jvm)/jre/bin/java.exe", "runtimes/jvm/native/$($manifest.guard)/bundle.json",
            "runtimes/python/$($manifest.python)/bundle.json", "runtimes/python/$($manifest.python)/python.exe")
        if ($variant -eq 'standard') {
            $expected += @('runtimes/standard', "runtimes/jvm/$($manifest.jvm)/jre/legal/java.base/LICENSE")
        } else {
            $expected += @('runtimes/mpv-yaozhi/bundle.json',
                "runtimes/python/$($manifest.python)/Lib/site-packages/requests/__init__.py")
        }
    }
    $suffix = if ($variant -eq 'full') { '' } else { "-$variant" }
    $zip = Join-Path $OutputDirectory "MisaTV-windows-x64$suffix.zip"
    Compress-Archive -LiteralPath $inputs -DestinationPath $zip -CompressionLevel Optimal -Force
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $zip).Path)
    try {
        $entries = $archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') }
        if ($entries -match '(^|/)userdata(/|$)' -or
            ($variant -eq 'lite' -and $entries -match '^runtimes/') -or
            ($variant -eq 'standard' -and $entries -match '^runtimes/(mpv-yaozhi/|python/[^/]+/Lib/site-packages/)') -or
            ($variant -eq 'full' -and 'runtimes/standard' -in $entries)) {
            throw "Unexpected file in $variant package"
        }
        foreach ($path in $expected) {
            if ($path -notin $entries) { throw "Missing $path in $variant package" }
        }
        Write-Host "$zip ($((Get-Item -LiteralPath $zip).Length) bytes)"
    } finally {
        $archive.Dispose()
    }
}
