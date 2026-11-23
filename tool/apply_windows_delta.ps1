param(
    [Parameter(Mandatory = $true)][string]$Session,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$ExeName,
    [Parameter(Mandatory = $true)][int]$ParentPid,
    [Parameter(Mandatory = $true)][string]$From,
    [Parameter(Mandatory = $true)][string]$To,
    [Parameter(Mandatory = $true)][ValidateSet('full', 'lite')][string]$Variant,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{64}$')][string]$Digest
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-SafeTarget([string]$RelativePath) {
    $parts = $RelativePath.Split('/')
    $path = $Root
    foreach ($part in $parts) {
        if (!$part -or $part -match '[<>:"\\|?*\x00-\x1f]|[. ]$' -or
            $part -match '^(userdata$|\.misatv-update|CON(\.|$)|PRN(\.|$)|AUX(\.|$)|NUL(\.|$)|COM[1-9\u00b9\u00b2\u00b3](\.|$)|LPT[1-9\u00b9\u00b2\u00b3](\.|$))') {
            throw "Unsafe update path: $RelativePath"
        }
        $path = [IO.Path]::Combine($path, $part)
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Update path uses a reparse point: $RelativePath"
        }
    }
    return $path
}

function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '') }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Assert-Base($Entry) {
    $target = Get-SafeTarget $Entry.path
    if ($null -eq $Entry.before) {
        if (Test-Path -LiteralPath $target) { throw "Unexpected existing file: $($Entry.path)" }
    } elseif (!(Test-Path -LiteralPath $target -PathType Leaf) -or
              (Get-Sha256 $target) -ine $Entry.before) {
        throw "Installed file does not match the base release: $($Entry.path)"
    }
}

$stage = $null
$lock = $null
$parent = $null
$restart = $false
$rollbackFailed = $false
$changed = [System.Collections.Generic.List[object]]::new()
$undo = [System.Collections.Generic.List[object]]::new()
try {
    $parent = [Diagnostics.Process]::GetProcessById($ParentPid)
    $Root = (Get-Item -LiteralPath $Root).FullName
    $stage = Join-Path $Root ('.misatv-update-' + [guid]::NewGuid().ToString('N'))
    $lock = [IO.FileStream]::new((Join-Path $Root '.misatv-update.lock'), 'OpenOrCreate', 'ReadWrite', 'None', 4096, 'DeleteOnClose')
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $zipPath = Join-Path $Session 'delta.zip'
    if ((Get-Sha256 $zipPath) -ine $Digest) {
        throw 'Invalid delta archive SHA-256'
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $manifest = $zip.GetEntry('delta.json')
        if (!$manifest -or $manifest.Length -gt 8MB) { throw 'Invalid delta manifest' }
        $reader = [IO.StreamReader]::new($manifest.Open())
        try { $plan = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
        if ($plan.schema -ne 1 -or $plan.from -cne $From -or
            $plan.to -cne $To -or $plan.variant -cne $Variant) { throw 'Delta release mismatch' }
        $expectedRuntime = $Variant -eq 'full'
        if ((Test-Path -LiteralPath (Get-SafeTarget 'runtimes/ready.json') -PathType Leaf) -ne $expectedRuntime) {
            throw 'Installed package type does not match'
        }
        $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $plan.files) {
            if (!$paths.Add($entry.path) -or (!$entry.before -and !$entry.after) -or
                ($null -ne $entry.before -and $entry.before -cnotmatch '^[a-f0-9]{64}$') -or
                ($null -ne $entry.after -and $entry.after -cnotmatch '^[a-f0-9]{64}$')) {
                throw 'Invalid delta file record'
            }
            Assert-Base $entry
            if ($entry.before -ceq $entry.after) { continue }
            $index = $changed.Count
            $payload = Join-Path $stage "new-$index"
            if ($entry.after) {
                $file = $zip.GetEntry("files/$($entry.path)")
                if (!$file -or $file.Length -ne $entry.size) { throw "Missing delta payload: $($entry.path)" }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($file, $payload)
                if ((Get-Sha256 $payload) -ine $entry.after) {
                    throw "Invalid delta payload: $($entry.path)"
                }
            }
            $changed.Add(@{ entry = $entry; payload = $payload; backup = Join-Path $stage "old-$index" })
        }
        if (!$paths.Contains('MisaTV.exe') -or !$paths.Contains('data/app.so') -or
            ($expectedRuntime -and !$paths.Contains('runtimes/ready.json'))) { throw 'Missing base checks' }
    } finally { $zip.Dispose() }

    [IO.File]::WriteAllText((Join-Path $Session 'ready'), '')
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (!(Test-Path -LiteralPath (Join-Path $Session 'commit'))) {
        if ($parent.HasExited -or [DateTime]::UtcNow -ge $deadline -or
            (Test-Path -LiteralPath (Join-Path $Session 'cancel'))) { return }
        Start-Sleep -Milliseconds 150
    }
    if (!$parent.WaitForExit(20000)) { throw 'MisaTV did not exit' }
    $restart = $true

    foreach ($item in $changed) { Assert-Base $item.entry }
    foreach ($item in $changed) {
        $target = Get-SafeTarget $item.entry.path
        $operation = @{ target = $target; backup = $item.backup; moved = $false; installed = $false }
        $undo.Add($operation)
        if ($item.entry.before) {
            [IO.File]::Move($target, $item.backup)
            $operation.moved = $true
        }
        if ($item.entry.after) {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.File]::Move($item.payload, $target)
            $operation.installed = $true
        }
    }
    Start-Process -FilePath (Join-Path $Root $ExeName) -WorkingDirectory $Root
    $restart = $false
} catch {
    if ($parent -and !$parent.HasExited) {
        [IO.File]::WriteAllText((Join-Path $Session 'failed'), $_.Exception.Message)
    }
    for ($index = $undo.Count - 1; $index -ge 0; $index--) {
        $operation = $undo[$index]
        try {
            if ($operation.installed) { [IO.File]::Delete($operation.target) }
            if ($operation.moved) { [IO.File]::Move($operation.backup, $operation.target) }
        } catch { $rollbackFailed = $true }
    }
    if ($rollbackFailed) {
        [IO.File]::WriteAllText((Join-Path $stage 'recovery.txt'), ($_ | Out-String))
    }
} finally {
    if ($stage -and !$rollbackFailed -and [IO.Directory]::Exists($stage)) {
        try { [IO.Directory]::Delete($stage, $true) } catch {}
    }
    if ($lock) { $lock.Dispose() }
    try { [IO.File]::Delete((Join-Path $Session 'delta.zip')) } catch {}
    if ($restart -and !$rollbackFailed) {
        $exe = Join-Path $Root $ExeName
        Start-Process -FilePath $exe -WorkingDirectory $Root -ArgumentList "--misatv-full-update=$To"
    }
}
