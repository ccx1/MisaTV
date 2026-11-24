param(
    [string]$Python = 'python',
    [string]$PythonIndex = 'https://mirrors.aliyun.com/pypi/simple/',
    [string]$CacheDirectory = '',
    [string]$OutputDirectory = '',
    [switch]$Standard
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
if (-not $CacheDirectory) { $CacheDirectory = Join-Path $repo 'build/runtime-downloads' }
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $repo $(if ($Standard) { 'build/windows-runtimes-standard/runtimes' } else { 'assets/windows-runtimes' })
}
$cache = [IO.Path]::GetFullPath($CacheDirectory)
$output = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force -Path $cache, $output | Out-Null
$standardMarker = Join-Path $output 'standard'
if (($Standard -and (Test-Path -LiteralPath (Join-Path $output 'mpv-yaozhi'))) -or
    (!$Standard -and (Test-Path -LiteralPath $standardMarker))) {
    throw 'Use separate output directories for the standard and full runtimes'
}
if ($Standard) { New-Item -ItemType File -Force -Path $standardMarker | Out-Null }
if (Test-Path -LiteralPath (Join-Path $output 'ready.json')) {
    Remove-Item -LiteralPath (Join-Path $output 'ready.json')
}
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-Download([string[]]$Urls, [string]$Name, [string]$Sha256 = '') {
    $target = Join-Path $cache $Name
    if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -gt 1024) {
        if (-not $Sha256 -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $Sha256) { return $target }
    }
    foreach ($url in $Urls) {
        try {
            Write-Host "Downloading $Name"
            & curl.exe --fail --location --continue-at - --retry 1 --connect-timeout 15 --max-time 900 --speed-time 30 --speed-limit 1024 --silent --show-error --output "$target.part" $url
            if ($LASTEXITCODE -ne 0) { throw "curl failed: $url" }
            if ((Get-Item -LiteralPath "$target.part").Length -lt 1024) { throw "Download too small: $Name" }
            if ($Sha256 -and (Get-FileHash -LiteralPath "$target.part" -Algorithm SHA256).Hash -ne $Sha256) {
                Remove-Item -LiteralPath "$target.part"
                throw "Checksum mismatch: $Name"
            }
            Move-Item -LiteralPath "$target.part" -Destination $target -Force
            return $target
        } catch { Write-Warning $_ }
    }
    throw "All downloads failed: $Name"
}

function Get-SourceVersion([string]$Path) {
    $text = Get-Content -LiteralPath (Join-Path $repo $Path) -Raw
    return [regex]::Match($text, "static const version = '([^']+)'").Groups[1].Value
}

function Write-Bundle([string]$Relative, [string[]]$Required) {
    $root = Join-Path $output $Relative
    $files = [ordered]@{}
    foreach ($file in (Get-ChildItem -LiteralPath $root -File -Recurse | Sort-Object FullName)) {
        $name = $file.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($name -in @('bundle.json', '.bundled-runtime')) { continue }
        $files[$name] = $file.Length
    }
    foreach ($name in $Required) {
        if (-not $files.Contains($name) -or $files[$name] -eq 0) { throw "Missing runtime file: $Relative/$name" }
    }
    $content = @{files = $files; required = $Required} | ConvertTo-Json -Depth 5 -Compress
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $revision = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    @{revision = $revision; files = $files; required = $Required} | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $root 'bundle.json') -Encoding utf8
}

function Copy-Maven([string]$Source, [string]$Destination) {
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $text = Get-Content -LiteralPath (Join-Path $repo $Source) -Raw
    $list = [regex]::Match($text, 'static const _(libPaths|jarPaths) = <String>\[(.*?)\];', 'Singleline').Groups[2].Value
    $paths = [regex]::Matches($list, "'([^'\r\n]+\.jar)'") | ForEach-Object { $_.Groups[1].Value }
    if (-not $paths) { throw "No Maven dependencies found in $Source" }
    foreach ($path in $paths) {
        $name = $path.Split('/')[-1]
        $download = Get-Download -Name $name -Urls @("https://maven.aliyun.com/repository/public/$path", "https://repo.maven.apache.org/maven2/$path")
        # A JAR must be a readable ZIP, not a mirror's HTML error page.
        $jar = [IO.Compression.ZipFile]::OpenRead($download)
        $jar.Dispose()
        Copy-Item -LiteralPath $download -Destination (Join-Path $Destination $name) -Force
    }
}

$jvmVersion = Get-SourceVersion 'lib/services/jvm/jvm_runtime.dart'
$armVersion = Get-SourceVersion 'lib/services/jvm/arm_bridge_runtime.dart'
$pyVersion = Get-SourceVersion 'lib/services/py_spider/py_runtime.dart'
$jvm = Join-Path $output "jvm/$jvmVersion"
$arm = Join-Path $output "jvm/native/$armVersion"
$py = Join-Path $output "python/$pyVersion"
$mpv = Join-Path $output 'mpv-yaozhi'
New-Item -ItemType Directory -Force -Path $jvm, $arm, $py | Out-Null

if ($Standard -and -not (Test-Path -LiteralPath (Join-Path $jvm 'jre/bin/java.exe'))) {
    if (!$env:JAVA_HOME) { throw 'JAVA_HOME must point to a Windows x64 JDK 17' }
    $jlink = Join-Path $env:JAVA_HOME 'bin/jlink.exe'
    # 官方 MisaTV 558bc60 的模块清单（GPL-3.0）。
    $modules = 'java.base,java.desktop,java.logging,java.management,java.naming,java.net.http,java.sql,java.xml,jdk.crypto.ec,jdk.charsets,jdk.httpserver,jdk.unsupported,jdk.zipfs'
    $javaVersion = & $jlink --version
    if ($LASTEXITCODE -ne 0 -or $javaVersion -notmatch '^17\.') { throw 'jlink must come from JDK 17' }
    $stage = Join-Path (Split-Path -Parent $output) ('jlink-' + [guid]::NewGuid().ToString('N'))
    & $jlink --no-header-files --no-man-pages --compress=2 --strip-debug --add-modules $modules --output $stage
    if ($LASTEXITCODE -ne 0) { throw 'jlink failed' }
    Move-Item -LiteralPath $stage -Destination (Join-Path $jvm 'jre')
} elseif (-not (Test-Path -LiteralPath (Join-Path $jvm 'jre/bin/java.exe'))) {
    $releases = Invoke-RestMethod 'https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jre&os=windows' -TimeoutSec 60
    $package = @($releases)[0].binary.package
    $zip = Get-Download -Urls @("https://gh-proxy.com/$($package.link)", $package.link, "https://ghfast.top/$($package.link)") -Name $package.name -Sha256 $package.checksum
    $stage = Join-Path $cache ('jre-' + [guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    $java = Get-ChildItem -LiteralPath $stage -Filter java.exe -File -Recurse | Select-Object -First 1
    if (-not $java) { throw 'JRE archive has no java.exe' }
    Move-Item -LiteralPath $java.Directory.Parent.FullName -Destination (Join-Path $jvm 'jre')
}
$dex = Join-Path $jvm 'd2j'
if (-not (Test-Path -LiteralPath (Join-Path $dex 'dex-tools-v2.4.jar'))) {
    $url = 'https://github.com/pxb1988/dex2jar/releases/download/v2.4/dex-tools-v2.4.zip'
    $zip = Get-Download -Urls @("https://gh-proxy.com/$url", $url, "https://ghfast.top/$url") -Name 'dex-tools-v2.4.zip'
    $stage = Join-Path $cache ('dex-' + [guid]::NewGuid().ToString('N'))
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $stage)
    New-Item -ItemType Directory -Force -Path $dex | Out-Null
    Get-ChildItem -LiteralPath $stage -File -Filter '*.jar' -Recurse | Copy-Item -Destination $dex -Force
}
Copy-Maven 'lib/services/jvm/jvm_runtime.dart' (Join-Path $jvm 'libs')
Copy-Maven 'lib/services/jvm/arm_bridge_runtime.dart' $arm
$shims = Join-Path $jvm 'shims'
New-Item -ItemType Directory -Force -Path $shims | Out-Null
Get-ChildItem -LiteralPath (Join-Path $repo 'assets/jvm') -File -Filter '*.jar' | Copy-Item -Destination $shims -Force
# Only public engine dependencies are bundled; never copy shell payloads or userdata.
$jvmRequired = @(Get-ChildItem -LiteralPath $dex, (Join-Path $jvm 'libs'), $shims -File | ForEach-Object { $_.FullName.Substring($jvm.Length + 1).Replace('\', '/') })
$javaRequired = @('jre/bin/java.exe', 'jre/bin/server/jvm.dll', 'jre/lib/modules')
if ($Standard) { $javaRequired += 'jre/legal/java.base/LICENSE' }
Write-Bundle "jvm/$jvmVersion" ($javaRequired + $jvmRequired)
Write-Bundle "jvm/native/$armVersion" @(Get-ChildItem -LiteralPath $arm -File -Filter '*.jar' | ForEach-Object Name)

if (-not (Test-Path -LiteralPath (Join-Path $py 'python.exe'))) {
    $zip = Get-Download -Urls @("https://mirrors.huaweicloud.com/python/$pyVersion/python-$pyVersion-embed-amd64.zip", "https://www.python.org/ftp/python/$pyVersion/python-$pyVersion-embed-amd64.zip") -Name "python-$pyVersion-embed-amd64.zip"
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $py)
}
$ready = @{jvm = $jvmVersion; guard = $armVersion; python = $pyVersion}
Copy-Item -LiteralPath (Join-Path $repo 'THIRD-PARTY-NOTICES.md') -Destination $output -Force
if ($Standard) {
    Write-Bundle "python/$pyVersion" @('python.exe', 'python311.dll', 'python311.zip')
    $ready | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'ready.json') -Encoding utf8
    Write-Host "Standard runtimes ready: $output"
    return
}

$pySource = Get-Content -LiteralPath (Join-Path $repo 'lib/services/py_spider/py_runtime.dart') -Raw
$specs = [regex]::Matches($pySource, "_WheelSpec\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*\[[^\]]*\]\s*,\s*(?:true|false)(?:\s*,\s*'([^']+)')?", 'Singleline')
$requirements = @($specs | ForEach-Object { $name = $_.Groups[1].Value; if ($_.Groups[3].Success) { $name += '==' + $_.Groups[3].Value }; $name })
if ($requirements.Count -lt 16) { throw 'Failed to read Python runtime dependency list' }
$wheels = Join-Path $cache 'wheels'
New-Item -ItemType Directory -Force -Path $wheels | Out-Null
& $Python -m pip download --disable-pip-version-check --index-url $PythonIndex --timeout 20 --retries 1 --only-binary=:all: --platform win_amd64 --python-version 311 --implementation cp --abi cp311 --dest $wheels @requirements
if ($LASTEXITCODE -ne 0) { throw 'Python wheel download failed' }
$site = Join-Path $py 'Lib/site-packages'
New-Item -ItemType Directory -Force -Path $site | Out-Null
foreach ($wheel in (Get-ChildItem -LiteralPath $wheels -Filter '*.whl' -File)) {
    [IO.Compression.ZipFile]::ExtractToDirectory($wheel.FullName, $site, $true)
}
Set-Content -LiteralPath (Join-Path $site '.kniephos-libs-v2') -Value 'bundled' -Encoding utf8
foreach ($spec in $specs) {
    if ($spec.Groups[3].Success) {
        $marker = '.kniephos-wheel-' + $spec.Groups[1].Value + '-' + $spec.Groups[3].Value
        Set-Content -LiteralPath (Join-Path $site $marker) -Value 'bundled' -Encoding utf8
    }
}
Copy-Item -LiteralPath (Join-Path $repo 'assets/python_runner/runner.py') -Destination $py -Force
Copy-Item -LiteralPath (Join-Path $repo 'assets/python_runner/base') -Destination $py -Recurse -Force
$assetsVersion = [regex]::Match($pySource, 'static const assetsVersion = (\d+)').Groups[1].Value
Set-Content -LiteralPath (Join-Path $py "base/.kniephos-assets-v$assetsVersion") -Value 'bundled' -Encoding utf8
# Smoke test every declared import in the embedded interpreter, completely offline.
$imports = @($specs | ForEach-Object { $_.Groups[2].Value })
$code = "import sys, importlib; sys.path.insert(0, r'$site'); [importlib.import_module(n) for n in " + ($imports | ConvertTo-Json -Compress) + ']; print(sys.version)'
& (Join-Path $py 'python.exe') -c $code
if ($LASTEXITCODE -ne 0) { throw 'Embedded Python dependency check failed' }
Write-Bundle "python/$pyVersion" @('python.exe', 'python311.dll', 'python311.zip', 'runner.py', 'base/spider.py', 'Lib/site-packages/requests/__init__.py')

if (-not (Test-Path -LiteralPath (Join-Path $mpv 'meta.json'))) {
    New-Item -ItemType Directory -Force -Path $mpv | Out-Null
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Yaozhil/mpv-Yaozhi/releases/latest' -TimeoutSec 60
    $asset = $release.assets | Where-Object { $_.name -match '\.(7z|zip)$' } | Sort-Object size -Descending | Select-Object -First 1
    if (-not $asset) { throw 'No Yaozhi MPV archive in latest release' }
    $digest = if ($asset.digest -match '^sha256:(.+)$') { $Matches[1] } else { '' }
    $archive = Get-Download -Urls @("https://gh-proxy.com/$($asset.browser_download_url)", $asset.browser_download_url, "https://ghfast.top/$($asset.browser_download_url)") -Name $asset.name -Sha256 $digest
    if ($asset.name.EndsWith('.zip')) { [IO.Compression.ZipFile]::ExtractToDirectory($archive, $mpv) }
    else {
        $seven = Get-Download -Urls @('https://www.7-zip.org/a/7zr.exe') -Name '7zr.exe'
        & $seven x -y "-o$mpv" $archive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'MPV extraction failed' }
    }
    @{tag = $release.tag_name; name = $release.name} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $mpv 'meta.json') -Encoding utf8
}
$mpvExe = Get-ChildItem -LiteralPath $mpv -File -Filter Yaoplayer.exe -Recurse | Where-Object { $_.FullName -notmatch '[\\/]portable_config[\\/]experimental[\\/]' } | Select-Object -First 1
if (-not $mpvExe) { throw 'No Yaoplayer.exe in bundled MPV' }
Write-Bundle 'mpv-yaozhi' @($mpvExe.FullName.Substring($mpv.Length + 1).Replace('\', '/'), 'meta.json')
$ready.mpv = (Get-Content -LiteralPath (Join-Path $mpv 'meta.json') -Raw | ConvertFrom-Json).tag
$ready |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $output 'ready.json') -Encoding utf8
Write-Host "All four runtimes ready: $output"
