# Rebuild the redistributable x64 launcher; normal project builds need no C compiler.
param([switch]$SkipGraphics)
$ErrorActionPreference='Stop'
$nativeRoot=$PSScriptRoot
$compilerRoot=Split-Path -Parent $nativeRoot
$buildRoot=Join-Path $nativeRoot 'build'
[IO.Directory]::CreateDirectory($buildRoot) | Out-Null
# Embed trusted Lua policy in every launcher, including plain console builds
# whose project bundle deliberately does not contain the framework runtime.
$bootstrapBytes=[IO.File]::ReadAllBytes((Join-Path $nativeRoot 'bootstrap.lua'))
if ($bootstrapBytes.Length -eq 0) { throw 'Native Lua bootstrap is empty.' }
$bootstrapLines=for($i=0;$i -lt $bootstrapBytes.Length;$i+=32) { ($bootstrapBytes[$i..([Math]::Min($i+31,$bootstrapBytes.Length-1))] -join ',')+',' }
$bootstrapHeader="/* Generated from native/bootstrap.lua; do not edit. */`nstatic const unsigned char lc_bootstrap[] = {`n"+($bootstrapLines -join "`n")+"0};`n"
[IO.File]::WriteAllText((Join-Path $buildRoot 'bootstrap.h'),$bootstrapHeader,[Text.Encoding]::ASCII)
if (!$SkipGraphics) { & (Join-Path $nativeRoot 'graphics-build.ps1') }
$graphicsLink=Join-Path $buildRoot 'graphics\graphics-link.rsp'
if (!(Test-Path -LiteralPath $graphicsLink)) { throw 'Build graphics dependencies before using -SkipGraphics.' }
$licenseBytes=[IO.File]::ReadAllBytes((Join-Path $compilerRoot 'THIRD-PARTY-LICENSES.txt'))
$licenseLines=for($i=0;$i -lt $licenseBytes.Length;$i+=32) { ($licenseBytes[$i..([Math]::Min($i+31,$licenseBytes.Length-1))] -join ',')+',' }
$licenseHeader="static const char lc_third_party_licenses[] = {`n"+($licenseLines -join "`n")+"0};`n"
[IO.File]::WriteAllText((Join-Path $buildRoot 'third_party_licenses.h'),$licenseHeader,[Text.Encoding]::ASCII)
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio C++ Build Tools are required to rebuild the launcher.' }
$vsRoot=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'No x64 MSVC toolchain found.' }
$vcvars=Join-Path $vsRoot 'VC\Auxiliary\Build\vcvars64.bat'
$luaSource=Join-Path $nativeRoot 'lua-5.4.9\src'
$luaFiles=Get-ChildItem -LiteralPath $luaSource -Filter '*.c' | Where-Object { $_.Name -notin @('lua.c','luac.c') }
$sourceArguments=($luaFiles | ForEach-Object { '"'+$_.FullName+'"' }) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $buildRoot 'lua.rsp'), "/nologo /O2 /MT /std:c11 /D_CRT_SECURE_NO_WARNINGS /W3 /c`r`n$sourceArguments`r`n", [Text.Encoding]::Default)
$objects=($luaFiles | ForEach-Object { '"'+(Join-Path $buildRoot ($_.BaseName+'.obj'))+'"' }) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $buildRoot 'lib.rsp'), '/nologo /OUT:"Lua54.lib"'+"`r`n"+$objects+"`r`n",[Text.Encoding]::Default)
$command=@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl @lua.rsp
if errorlevel 1 exit /b 1
lib @lib.rsp
if errorlevel 1 exit /b 1
cl /nologo /O2 /MT /std:c11 /W4 /WX /D_CRT_SECURE_NO_WARNINGS /DLC_DESKTOP /I"$luaSource" /I"$buildRoot" "$nativeRoot\launcher.c" "$nativeRoot\ui.c" Lua54.lib bcrypt.lib shell32.lib user32.lib gdi32.lib @"$graphicsLink" /Fe:"Launcher.pending.exe" /link /SUBSYSTEM:CONSOLE /MACHINE:X64 /DYNAMICBASE /NXCOMPAT
if errorlevel 1 exit /b 1
Launcher.pending.exe --luacompiler-probe
exit /b %ERRORLEVEL%
"@
[IO.File]::WriteAllText((Join-Path $buildRoot 'compile.cmd'),$command,[Text.Encoding]::Default)
Push-Location -LiteralPath $buildRoot
try { & cmd.exe /d /c compile.cmd; if ($LASTEXITCODE -ne 0) { throw 'Native launcher compilation or probe failed.' } } finally { Pop-Location }
$pending=Join-Path $buildRoot 'Launcher.pending.exe'
$template=Join-Path $compilerRoot 'Launcher.exe'
# Preserve the previous template until compilation and a successful probe finish.
Copy-Item -LiteralPath $pending -Destination $template -Force
$f=[IO.File]::OpenRead($template)
try { $sha=[Security.Cryptography.SHA256]::Create(); try { $hash=[BitConverter]::ToString($sha.ComputeHash($f)).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() } } finally { $f.Dispose() }
[IO.File]::WriteAllText($template+'.sha256',$hash+"`n",[Text.Encoding]::ASCII)
Write-Output "Built static x64 Lua 5.4 launcher: $template"

