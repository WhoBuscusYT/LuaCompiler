local Directory = (debug.getinfo(1,'S').source:match('^@(.+[\\/])') or './')
local Windows = assert(loadfile(Directory .. 'Windows.lua'))()
local Bundler = assert(loadfile(Directory .. 'Bundler.lua'))()
local Updater = {}
Updater.Files = {'Windows.lua','Bundler.lua','Builder.lua','Compiler.lua','GameCompile.lua','Updater.lua','luacompiler.cmd','Launcher.exe','Launcher.exe.sha256','LUA-LICENSE.txt','Runtime.lcb','Runtime.lcb.sha256','THIRD-PARTY-LICENSES.txt','VERSION'}
local URL = 'https://raw.githubusercontent.com/WhoBuscusYT/LuaCompiler/main/'
local function Read(Path)
    local File, Message = io.open(Path,'rb')
    if not File then return nil, Message end
    local Bytes, Error = File:read('*a'); File:close(); return Bytes, Error
end
local function Write(Path, Bytes)
    local File = assert(io.open(Path,'wb'))
    local Ok, Error = File:write(Bytes)
    local Closed, CloseError = File:close()
    assert(Ok and Closed, Error or CloseError)
end
local function Version(Bytes)
    return Bytes and Bytes:match('^%s*(%d+%.%d+%.%d+%.%d+)%s*$')
end
function Updater.ValidateInstallation(Root)
    local V = Version(Read(Root .. '/VERSION'))
    if not V then return false, 'Missing or invalid VERSION' end
    for _, Name in ipairs(Updater.Files) do
        local Bytes = Read(Root .. '/' .. Name)
        if not Bytes or #Bytes == 0 then return false, 'Missing component: ' .. Name end
        if Name:match('%.lua$') then
            local Chunk, Error = load(Bytes, '@' .. Root .. '/' .. Name, 't')
            if not Chunk then return false, 'Invalid component ' .. Name .. ': ' .. Error end
        end
    end
    local RuntimeChecked,RuntimeError=pcall(function()
        local RuntimeDigest=(Read(Root..'/Runtime.lcb.sha256') or ''):match('^%s*(%x+)%s*$')
        assert(RuntimeDigest and #RuntimeDigest==64 and Windows.Hash(Root..'/Runtime.lcb')==RuntimeDigest:lower(), 'Runtime checksum mismatch')
        local RuntimeEntries=Bundler.ReadBundle(assert(Read(Root..'/Runtime.lcb')))
        local Present={}
        for _,Entry in ipairs(RuntimeEntries) do
            Present[Entry.RelativePath]=true
            if Entry.RelativePath:match('%.lua$') then
                assert(load(Entry.Content,'@runtime/'..Entry.RelativePath,'t'))
            end
        end
        assert(Present['lc/ui.lua'] and Present['lc/game.lua'] and Present['lc/backends/vulkan.lua'], 'Incomplete framework runtime')
    end)
    if not RuntimeChecked then return false, tostring(RuntimeError) end
    local Template=Read(Root .. '/Launcher.exe')
    local Digest=(Read(Root .. '/Launcher.exe.sha256') or ''):match('^%s*(%x+)%s*$')
    if not Digest or #Digest~=64 or #Template<256 or Template:sub(1,2)~='MZ' then
        return false, 'Invalid launcher or checksum'
    end
    local PE=string.unpack('<I4',Template,61)
    if PE>#Template-96 or Template:sub(PE+1,PE+4)~='PE\0\0'
        or string.unpack('<I2',Template,PE+5)~=0x8664
        or string.unpack('<I2',Template,PE+25)~=0x20b
        or string.unpack('<I2',Template,PE+93)~=3 then
        return false, 'Invalid x64 console launcher'
    end
    local Hashed,Hash=pcall(Windows.Hash,Root .. '/Launcher.exe')
    if not Hashed or Hash~=Digest:lower() then return false, 'Launcher checksum mismatch' end
    local Probed,Probe=pcall(Windows.Run,'& '..Windows.Literal(Windows.FullPath(Root .. '/Launcher.exe'))
        .. ' --luacompiler-probe; if($LASTEXITCODE -ne 0) { exit 1 }')
    if not Probed or Probe~='LuaCompiler launcher 1 Lua 5.4' then return false, 'Launcher probe failed' end
    local Capable,Capabilities=pcall(Windows.Run,'& '..Windows.Literal(Windows.FullPath(Root..'/Launcher.exe'))
        ..' --luacompiler-capabilities; if($LASTEXITCODE -ne 0) { exit 1 }')
    if not Capable or Capabilities~='LuaCompiler runtime 1 console gui vulkan2d vulkan3d' then
        return false, 'Launcher does not support the installed framework'
    end
    return true, V
end
local function Fetch(Name, Destination, BaseURL)
    -- Arguments are encoded as byte lists; shell metacharacters cannot escape them.
    local Ok, Code = pcall(Windows.Run, '& curl.exe --fail --location --silent --show-error --connect-timeout 5 --max-time 20 --output '
        .. Windows.Literal(Destination) .. ' ' .. Windows.Literal((BaseURL or URL) .. Name)
        .. "; $code=$LASTEXITCODE; if($null -eq $code) { throw 'curl unavailable' }; [Console]::Write($code)")
    if not Ok then return false, tostring(Code), 'failed' end
    Code=tonumber(Code)
    if Code==0 then return true end
    local Offline=Code==5 or Code==6 or Code==7 or Code==28
    return false, 'Download failed for ' .. Name .. ' (curl exit ' .. tostring(Code) .. ')', Offline and 'offline' or 'failed'

end
function Updater.UpdateCheck(Options)
    Options = Options or {}
    local Root = Options.Directory or Directory
    local Download = Options.Fetch or function(Name,Destination) return Fetch(Name,Destination,Options.URL) end
    local Rename = Options.Rename or function(Source,Destination)
        Windows.Publish(Source,Destination)
        return true
    end
    local Restore = Options.Restore or Windows.Publish
    local Stage = Root .. '/.update-stage'
    local function Result(Status, Message)
        local Valid, LocalVersion = Updater.ValidateInstallation(Root)
        return {Status=Status, Message=Message, Usable=Valid, Version=Valid and LocalVersion or nil}
    end
    -- Exclusive directory creation prevents simultaneous updates. On interruption,
    -- keep backups and refuse further updates until the transaction is recovered.
    local Locked = pcall(Windows.Run, 'New-Item -ItemType Directory -Path ' .. Windows.Literal(Stage) .. ' -ErrorAction Stop | Out-Null')
    if not Locked then
        local R=Result('failed', 'Update staging directory exists or cannot be created; inspect .update-stage backups before retrying')
        local Checked, Exists=pcall(Windows.Run, 'if(Test-Path -LiteralPath ' .. Windows.Literal(Stage) .. ") { 'yes' } else { 'no' }")
        R.Usable=R.Usable and Checked and Exists=='no'
        return R
    end
    local function Cleanup()
        for _, Name in ipairs(Updater.Files) do
            os.remove(Stage .. '/' .. Name); os.remove(Stage .. '/' .. Name .. '.backup'); os.remove(Stage .. '/' .. Name .. '.restore')
        end
        os.remove(Stage .. '/SHA256SUMS'); os.remove(Stage .. '/journal')
        pcall(Windows.Run, 'Remove-Item -LiteralPath ' .. Windows.Literal(Stage) .. ' -ErrorAction Stop')
    end
    local Backups, Changed = {}, {}
    local PublicVersion
    local Phase = 'version'
    local Ok, Error = pcall(function()
        local Available, Message, Failure = Download('VERSION', Stage .. '/VERSION')
        if not Available then
            if Failure=='failed' then Phase='download' end
            error(Message or 'Cannot reach update server')
        end
        Phase='validate-version'
        PublicVersion = assert(Version(Read(Stage .. '/VERSION')), 'Invalid remote VERSION')
        local Valid, LocalVersion = Updater.ValidateInstallation(Root)
        if Valid and LocalVersion == PublicVersion then Phase='current'; return end
        Phase='download'
        assert(Download('SHA256SUMS',Stage .. '/SHA256SUMS'), 'Cannot download SHA256SUMS')
        local Hashes = {}
        for Line in assert(Read(Stage .. '/SHA256SUMS')):gmatch('[^\r\n]+') do
            local Hash, Name = Line:match('^(%x+)%s+%*?([%w_.-]+)$')
            assert(Hash and #Hash == 64 and not Hashes[Name], 'Invalid checksum manifest')
            Hashes[Name]=Hash:lower()
        end
        for _, Name in ipairs(Updater.Files) do
            assert(Hashes[Name], 'Missing checksum: ' .. Name)
            if Name ~= 'VERSION' then assert(Download(Name,Stage .. '/' .. Name), 'Download failed: ' .. Name) end
            assert(Windows.Hash(Stage .. '/' .. Name) == Hashes[Name], 'Checksum mismatch: ' .. Name)
        end
        assert(Updater.ValidateInstallation(Stage))
        -- Keep complete original bytes before changing any installed file.
        local Journal = {}
        for _, Name in ipairs(Updater.Files) do
            Backups[Name]=Read(Root .. '/' .. Name) or false
            if Backups[Name] then Write(Stage .. '/' .. Name .. '.backup',Backups[Name]) end
            Journal[#Journal+1]=Name .. (Backups[Name] and ' present' or ' absent')
        end
        Write(Stage .. '/journal',table.concat(Journal,'\n'))
        Phase='install'
        for _, Name in ipairs(Updater.Files) do
            Changed[#Changed+1]=Name
            assert(Rename(Stage .. '/' .. Name,Root .. '/' .. Name))
        end
        local Valid, InstalledVersion = Updater.ValidateInstallation(Root)
        assert(Valid and InstalledVersion == PublicVersion, 'Installation validation failed')
        Phase='updated'
    end)
    if not Ok then
        local Recovered = true
        for I=#Changed,1,-1 do
            local Name=Changed[I]
            local Restored = pcall(function()
                if Backups[Name] then
                    Write(Stage .. '/' .. Name .. '.restore',Backups[Name])
                    Restore(Stage .. '/' .. Name .. '.restore',Root .. '/' .. Name)
                else
                    if Read(Root .. '/' .. Name) then assert(os.remove(Root .. '/' .. Name)) end
                end
            end)
            Recovered = Recovered and Restored
        end
        if Recovered then Cleanup() end
        local R=Result(Phase == 'version' and not PublicVersion and 'offline' or 'failed',
            tostring(Error) .. (Recovered and '' or '; rollback incomplete; backups retained in .update-stage'))
        if not Recovered then R.Usable=false end
        return R
    end
    Cleanup()
    return Result(Phase, Phase == 'current' and 'Compiler is up to date' or 'Update installed and verified')
end
-- Call only after stopping all compiler processes using this installation.
-- Backups stay intact until every restoration succeeds, so recovery is retryable.
function Updater.Recover(Root)
    Root=Root or Directory
    local Stage=Root .. '/.update-stage'
    local Ok, Error=pcall(function()
        local Journal=Read(Stage .. '/journal')
        if Journal then
            local Entries={}
            for Name,State in Journal:gmatch('([%w_.-]+) ([%a]+)') do
                assert(not Entries[Name] and (State=='present' or State=='absent'),'Invalid recovery journal')
                Entries[Name]=State
            end
            for _,Name in ipairs(Updater.Files) do
                assert(Entries[Name],'Incomplete recovery journal')
                if Entries[Name]=='present' then
                    assert(Read(Stage .. '/' .. Name .. '.backup'),'Missing recovery backup')
                end
            end
            for _,Name in ipairs(Updater.Files) do
                if Entries[Name]=='present' then
                    Write(Stage .. '/' .. Name .. '.restore',assert(Read(Stage .. '/' .. Name .. '.backup')))
                    Windows.Publish(Stage .. '/' .. Name .. '.restore',Root .. '/' .. Name)
                elseif Read(Root .. '/' .. Name) then assert(os.remove(Root .. '/' .. Name)) end
            end
        end
        for _,Name in ipairs(Updater.Files) do
            os.remove(Stage .. '/' .. Name)
            os.remove(Stage .. '/' .. Name .. '.backup')
            os.remove(Stage .. '/' .. Name .. '.restore')
        end
        os.remove(Stage .. '/SHA256SUMS'); os.remove(Stage .. '/journal')
        Windows.Run('Remove-Item -LiteralPath ' .. Windows.Literal(Stage) .. ' -ErrorAction Stop')
    end)
    return Ok, Error
end
return Updater
