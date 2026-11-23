param([string]$Jdk = $env:JAVA_HOME)
$ErrorActionPreference = 'Stop'

if (-not $Jdk) { throw 'Pass -Jdk with the path to JDK 17 or set JAVA_HOME.' }
$javac = Join-Path $Jdk 'bin/javac.exe'
$java = Join-Path $Jdk 'bin/java.exe'
$jar = Join-Path $Jdk 'bin/jar.exe'
foreach ($exe in @($javac, $java, $jar)) {
    if (-not (Test-Path -LiteralPath $exe)) { throw "Missing JDK tool: $exe" }
}

$repo = Split-Path -Parent $PSScriptRoot
$build = Join-Path $repo ('build/jvm-stubs/' + [guid]::NewGuid().ToString('N'))
$classes = Join-Path $build 'classes'
$tests = Join-Path $build 'tests'
New-Item -ItemType Directory -Path $classes, $tests -Force | Out-Null
$stubs = Join-Path $repo 'assets/jvm/stubs.jar'
$output = Join-Path $build 'stubs.jar'
Copy-Item -LiteralPath $stubs -Destination $output
$sources = @('android/content/ContextWrapper.java', 'android/app/Application.java') |
    ForEach-Object { Join-Path $repo ('assets/jvm/src/stubs/' + $_) }

& $javac --release 17 -encoding UTF-8 -cp $stubs -d $classes @sources
if ($LASTEXITCODE -ne 0) { throw 'Stub compilation failed.' }
& $jar uf $output -C $classes .
if ($LASTEXITCODE -ne 0) { throw 'JAR update failed.' }
& $javac --release 17 -encoding UTF-8 -cp $output -d $tests (Join-Path $repo 'test/jvm/ContextWrapperTest.java')
if ($LASTEXITCODE -ne 0) { throw 'Compatibility test compilation failed.' }
& $java -cp "$tests;$output" ContextWrapperTest
if ($LASTEXITCODE -ne 0) { throw 'Compatibility test failed.' }

Copy-Item -LiteralPath $output -Destination $stubs -Force
Write-Host 'Updated assets/jvm/stubs.jar (Java 17).'
