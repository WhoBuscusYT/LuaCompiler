# Build only the graphics libraries; the launcher build consumes graphics-link.rsp.
param([switch]$SkipSDL)
$ErrorActionPreference='Stop'
$nativeRoot=$PSScriptRoot
$root=Split-Path -Parent $nativeRoot
$graphicsBuild=Join-Path $nativeRoot 'build\graphics'
[IO.Directory]::CreateDirectory($graphicsBuild) | Out-Null
$vswhere=Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs=& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$vs) { throw 'MSVC C++ build tools are required to rebuild graphics dependencies.' }
$cmake=Join-Path $vs 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
$sdlSource=Join-Path $root 'third_party\SDL'
$sdlBuild=Join-Path $graphicsBuild 'sdl'
if (!$SkipSDL) {
    & $cmake -S $sdlSource -B $sdlBuild -G 'Visual Studio 17 2022' -A x64 -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TESTS=OFF -DSDL_INSTALL=OFF -DSDL_AUDIO=OFF -DSDL_JOYSTICK=OFF -DSDL_HAPTIC=OFF -DSDL_SENSOR=OFF -DSDL_CAMERA=OFF -DSDL_GPU=OFF -DSDL_RENDER=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF -DSDL_VULKAN=ON
    if ($LASTEXITCODE) { throw 'SDL3 configuration failed.' }
    & $cmake --build $sdlBuild --config Release --target SDL3-static --parallel 8
    if ($LASTEXITCODE) { throw 'SDL3 static build failed.' }
}
$moonSource=Join-Path $root 'third_party\moonvulkan\src'
$luaSource=Join-Path $nativeRoot 'lua-5.4.9\src'
$moonBuild=Join-Path $graphicsBuild 'moon'
[IO.Directory]::CreateDirectory($moonBuild) | Out-Null
$files=Get-ChildItem -LiteralPath $moonSource -Filter '*.c'
$argsText="/nologo /O2 /MT /std:c11 /W0 /D_CRT_SECURE_NO_WARNINGS /DMINGW /DVK_USE_PLATFORM_WIN32_KHR /DCOMPAT53_PREFIX=moonvulkan_compat_ /I`"$luaSource`" /I`"$moonSource`" /c`r`n"
$argsText+=($files | ForEach-Object { '"'+$_.FullName+'"' }) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $moonBuild 'compile.rsp'),$argsText,[Text.Encoding]::Default)
$vcvars=Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$objects=($files | ForEach-Object { '"'+(Join-Path $moonBuild ($_.BaseName+'.obj'))+'"' }) -join "`r`n"
[IO.File]::WriteAllText((Join-Path $moonBuild 'library.rsp'),"/nologo /OUT:`"$(Join-Path $graphicsBuild 'MoonVulkan.lib')`"`r`n"+$objects,[Text.Encoding]::Default)
$cmd=@"
@echo off
call "$vcvars" >nul
if errorlevel 1 exit /b 1
cl @compile.rsp
if errorlevel 1 exit /b 1
lib @library.rsp
if errorlevel 1 exit /b 1
cl /nologo /O2 /MT /std:c11 /W4 /WX /D_CRT_SECURE_NO_WARNINGS /DSDL_STATIC_LIB /I"$luaSource" /I"$sdlSource\include" /c "$nativeRoot\graphics.c" /Fo:"$graphicsBuild\graphics.obj"
exit /b %ERRORLEVEL%
"@
[IO.File]::WriteAllText((Join-Path $moonBuild 'compile.cmd'),$cmd,[Text.Encoding]::Default)
Push-Location -LiteralPath $moonBuild
try { & cmd.exe /d /c compile.cmd; if($LASTEXITCODE) { throw 'MoonVulkan or SDL3 Lua binding compilation failed.' } } finally { Pop-Location }
$libraries=@((Join-Path $graphicsBuild 'graphics.obj'),(Join-Path $graphicsBuild 'MoonVulkan.lib'),(Join-Path $sdlBuild 'Release\SDL3-static.lib'))
$link=($libraries | ForEach-Object { '"'+$_+'"' }) -join "`r`n"
$link+="`r`nuser32.lib gdi32.lib winmm.lib imm32.lib ole32.lib oleaut32.lib version.lib setupapi.lib advapi32.lib shell32.lib uuid.lib cfgmgr32.lib`r`n"
[IO.File]::WriteAllText((Join-Path $graphicsBuild 'graphics-link.rsp'),$link,[Text.Encoding]::Default)
Write-Output 'Static MoonVulkan + SDL3 binding ready; consume native/build/graphics/graphics-link.rsp.'
