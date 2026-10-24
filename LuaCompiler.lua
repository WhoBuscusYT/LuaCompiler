-- VARIABLES
local AppData = assert(os.getenv("LOCALAPPDATA"))
local CompilerPath = AppData .. "\\LuaCompiler"
local URL = "https://raw.githubusercontent.com/WhoBuscusYT/LuaCompiler/main/"

-- FUNCTIONS
local function InstallDirectory()
    local success = os.execute(
        'if not exist "' .. CompilerPath .. '" mkdir "' .. CompilerPath .. '" 2>nul'
    )

    if not success then
        error("[LuaCompiler] Failed to create compiler directory!")
    end
end

function DownloadFile(url, filename)
    local destination = CompilerPath .. "\\" .. filename
    local fullurl = url .. filename

    local command = string.format(
        'curl.exe -L -f -sS -o "%s" "%s"',
        destination,
        fullurl
    )

    local success = os.execute(command)

    if not success then
        error("[LuaCompiler] Failed to download: " .. filename)
    end

    print("[LuaCopmiler] Downloaded: " .. filename)
end

function UpdateFile(url, filename)
    local destination = CompilerPath .. "\\" .. filename
    local success, errorMessage = os.remove(destination)

    if success then
        print("[LuaCompiler] Successfully Deleted " .. filename .. ". Installing new version now.")
        DownloadFile(url, filename)
    else
        error("[LuaCompiler] Failed to delete " .. filename .. ".")
    end
end

local function AddToPath()
    local command = [[powershell.exe -NoProfile -Command "$p = Join-Path $env:LOCALAPPDATA 'LuaCompiler'; $paths = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';'; if ($p -notin $paths) { [Environment]::SetEnvironmentVariable('Path', (($paths + $p) -join ';').Trim(';'), 'User') }"]]

    local success = os.execute(command)

    if success then
        print("[LuaCompiler] Added compiler to user PATH!")
        print("[LuaCompiler] Restart your terminal to use 'luacompiler'.")
    else
        print("[LuaCompiler] Failed to update PATH.")
    end
end

-- FUNCTION CALLING
InstallDirectory()
DownloadFile(URL, "GameCompile.lua")
DownloadFile(URL, "luacompiler.cmd")
DownloadFile(URL, "Updater.lua")
DownloadFile(URL, "Compiler.lua")
DownloadFile(URL, "Bundler.lua")
DownloadFile(URL, "Windows.lua")
DownloadFile(URL, "Builder.lua")
DownloadFile(URL, "Launcher.exe")
DownloadFile(URL, "Launcher.exe.sha256")
DownloadFile(URL, "Runtime.lcb")
DownloadFile(URL, "Runtime.lcb.sha256")
DownloadFile(URL, "THIRD-PARTY-LICENSES.txt")
DownloadFile(URL, "LUA-LICENSE.txt")
DownloadFile(URL, "VERSION")
AddToPath()
