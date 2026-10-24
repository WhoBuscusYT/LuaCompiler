# Development tests only. First build the launcher (including static graphics).
param([string]$Root=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$Root=[IO.Path]::GetFullPath($Root)
$build=Join-Path $Root 'native\build\graphics'
$lua=Join-Path $Root 'native\lua-5.4.9\src'
$sdl=Join-Path $Root 'third_party\SDL\include'
$luaLibrary=Join-Path $Root 'native\build\Lua54.lib'
$graphicsResponse=Join-Path $build 'graphics-link.rsp'
if(!(Test-Path -LiteralPath $luaLibrary) -or !(Test-Path -LiteralPath $graphicsResponse)) {
    throw 'Run native/build.ps1 first to build the Lua and graphics static libraries.'
}
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if(!$vs) { throw 'MSVC x64 build tools not found.' }
$vcvars=Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$source=Join-Path $Root 'tests\graphics_host.c'
$cmd=@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl /nologo /O2 /MT /std:c11 /W4 /WX /DSDL_STATIC_LIB /I"$lua" /I"$sdl" "$source" "$luaLibrary" @"$graphicsResponse" /Fe:"$build\graphics-test.exe" /link /SUBSYSTEM:CONSOLE
exit /b %ERRORLEVEL%
"@
[IO.File]::WriteAllText((Join-Path $build 'test-build.cmd'),$cmd,[Text.Encoding]::Default)
Push-Location -LiteralPath $build
try { & cmd.exe /d /c test-build.cmd; if($LASTEXITCODE) { throw 'Graphics development host build failed.' } } finally { Pop-Location }
Write-Output ('Graphics host: '+(Join-Path $build 'graphics-test.exe'))
