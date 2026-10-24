@echo off
lua "%~dp0GameCompile.lua" %*
exit /b %ERRORLEVEL%
