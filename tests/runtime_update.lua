-- Usage: lua tests/runtime_update.lua ABSOLUTE_COMPILER_ROOT ABSOLUTE_NEW_SCRATCH
-- Every installed/release component is copied; the real installation is read-only.
local Root,Scratch=assert(arg[1]),assert(arg[2])
local function Module(Name) return assert(loadfile(Root..'/'..Name))() end
local Windows,Bundler,Updater=Module('Windows.lua'),Module('Bundler.lua'),Module('Updater.lua')
local Checks=0
local function Check(Value,Message)
    assert(Value,Message); Checks=Checks+1
end
local function Read(Path)
    local File=io.open(Path,'rb'); if not File then return nil end
    local Bytes=assert(File:read('*a')); assert(File:close()); return Bytes
end
local function Write(Path,Bytes)
    local File=assert(io.open(Path,'wb')); assert(File:write(Bytes)); assert(File:close())
end
Windows.Run('New-Item -ItemType Directory -Path '..Windows.Literal(Scratch)..' -ErrorAction Stop | Out-Null')
local Installed,Remote=Scratch..'/installed',Scratch..'/remote'
Windows.MakeDirectory(Installed); Windows.MakeDirectory(Remote)
local Base={}
for _,Name in ipairs(Updater.Files) do Base[Name]=assert(Read(Root..'/'..Name)) end
local NewVersion=Base.VERSION:match('^%s*(.-)%s*$')=='9.9.9.9' and '9.9.9.8' or '9.9.9.9'
local function RestoreInstalled()
    for _,Name in ipairs(Updater.Files) do Write(Installed..'/'..Name,Base[Name]) end
end
local function RestoreRemote()
    for _,Name in ipairs(Updater.Files) do Write(Remote..'/'..Name,Base[Name]) end
    Write(Remote..'/VERSION',NewVersion..'\n')
end
local function Manifest()
    Write(Remote..'/Runtime.lcb.sha256',Windows.Hash(Remote..'/Runtime.lcb')..'\n')
    local Lines={}
    for _,Name in ipairs(Updater.Files) do Lines[#Lines+1]=Windows.Hash(Remote..'/'..Name)..'  '..Name end
    Write(Remote..'/SHA256SUMS',table.concat(Lines,'\n')..'\n')
end
local function Unchanged(Expected,Label)
    for _,Name in ipairs(Updater.Files) do
        Check(Read(Installed..'/'..Name)==Expected[Name],Label..': '..Name)
    end
end
local Downloads,Replacements=0,{}
local function Fetch(Name,Destination)
    Downloads=Downloads+1
    local Bytes=Read(Remote..'/'..Name)
    if not Bytes then return false,'Missing test release component: '..Name,'failed' end
    Write(Destination,Bytes); return true
end
local function Update(Download)
    Downloads,Replacements=0,{}
    return Updater.UpdateCheck{Directory=Installed,Fetch=Download or Fetch,Rename=function(Source,Destination)
        local Name=assert(Source:match('([^/\\]+)$'))
        Replacements[#Replacements+1]=Name
        Check(Read(Installed..'/VERSION')==Base.VERSION,'VERSION changed before final installation commit')
        Windows.Publish(Source,Destination); return true
    end}
end
RestoreInstalled(); RestoreRemote()
Check(Updater.ValidateInstallation(Installed),'Copied baseline installation is invalid')
local Result=Update(function()
    Downloads=Downloads+1
    return false,'Intentional offline test','offline'
end)
Check(Result.Status=='offline' and Result.Usable,'Valid installation is unusable offline')
Check(Downloads==1 and #Replacements==0,'Offline check performed unexpected work')
Unchanged(Base,'Offline check changed installed bytes')

-- All release checksums agree with these invalid archives. Structural validation
-- must reject them before any installation replacement is attempted.
for _,Case in ipairs({
    {Name='bad magic',Bytes='NOT_LCB1_RUNTIME_CONTENT'},
    {Name='truncated content',Bytes='LCB1'..string.pack('<I4I4I4I8',1,1,1,100)..'x'},
}) do
    RestoreRemote(); Write(Remote..'/Runtime.lcb',Case.Bytes); Manifest()
    Check(Read(Remote..'/Runtime.lcb.sha256'):match('%x+')==Windows.Hash(Remote..'/Runtime.lcb'),
        'Invalid release sidecar is not self-consistent')
    Result=Update()
    Check(Result.Status=='failed' and Result.Usable,'Malformed runtime was accepted: '..Case.Name)
    Check(#Replacements==0,'Malformed runtime touched installation: '..Case.Name)
    Check(Result.Message:lower():find('runtime',1,true),'Runtime rejection did not identify runtime component')
    Unchanged(Base,'Malformed runtime changed installed bytes ('..Case.Name..')')
end

RestoreRemote()
local Entries,Filtered,Found=Bundler.ReadBundle(Base['Runtime.lcb']),{},false
for _,Entry in ipairs(Entries) do
    if Entry.RelativePath=='lc/game.lua' then Found=true else Filtered[#Filtered+1]=Entry end
end
Check(Found,'Baseline archive lacks lc/game.lua')
Bundler.WriteBundle(Filtered,Remote..'/Runtime.lcb'); Manifest()
Result=Update()
Check(Result.Status=='failed' and Result.Usable,'Incomplete runtime was accepted')
Check(#Replacements==0,'Incomplete runtime touched installation')
Check(Result.Message:find('Incomplete framework runtime',1,true),'Missing runtime module was not identified')
Unchanged(Base,'Incomplete runtime changed installed bytes')

local Damaged={}
for Name,Bytes in pairs(Base) do Damaged[Name]=Bytes end
Damaged['Runtime.lcb']='LOCAL_RUNTIME_CORRUPTION'
Write(Installed..'/Runtime.lcb',Damaged['Runtime.lcb'])
Result=Update(function() return false,'Intentional offline test','offline' end)
Check(Result.Status=='offline' and not Result.Usable,'Corrupt local runtime allowed an offline build')
Check(#Replacements==0,'Offline corrupt-runtime check attempted installation')
Unchanged(Damaged,'Offline corruption check rewrote installation')

RestoreInstalled(); RestoreRemote(); Manifest()
Result=Update()
Check(Result.Status=='updated' and Result.Usable and Result.Version==NewVersion,'Valid runtime release did not install')
Check(#Replacements==#Updater.Files and Replacements[#Replacements]=='VERSION','VERSION was not committed last')
for _,Name in ipairs(Updater.Files) do
    Check(Read(Installed..'/'..Name)==Read(Remote..'/'..Name),'Successful update differs from release: '..Name)
end
Check(Updater.ValidateInstallation(Installed),'Successful runtime installation fails validation')
Result=Update()
Check(Result.Status=='current' and Result.Usable and Downloads==1 and #Replacements==0,
    'Current runtime installation was needlessly downloaded or replaced')
local Report=assert(io.open(Scratch..'/runtime-update-results.txt','wb'))
assert(Report:write('RUNTIME_UPDATE_TESTS_OK '..Checks..'\nAll installation and release files were isolated under '..Scratch..'\n'))
assert(Report:close())
print('RUNTIME_UPDATE_TESTS_OK '..Checks)
print('Isolated files and report: '..Scratch)
