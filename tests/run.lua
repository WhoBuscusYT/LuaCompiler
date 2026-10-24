-- Usage: lua tests/run.lua ABSOLUTE_COMPILER_ROOT ABSOLUTE_NEW_SCRATCH_ROOT
local Root, Scratch=assert(arg[1]),assert(arg[2])
local function Module(Name) return assert(loadfile(Root .. '/' .. Name))() end
local Windows, Bundler, Compiler, Updater=Module('Windows.lua'),Module('Bundler.lua'),Module('Compiler.lua'),Module('Updater.lua')
local Checks=0
local function Check(Value,Message) assert(Value,Message); Checks=Checks+1 end
local function Reject(Fn) Check(not pcall(Fn),'Expected error') end
local function Read(Path)
    local F=io.open(Path,'rb'); if not F then return nil end
    local B=assert(F:read('*a')); assert(F:close()); return B
end
local function Write(Path,B)
    local F=assert(io.open(Path,'wb')); assert(F:write(B)); assert(F:close())
end
Windows.Run('New-Item -ItemType Directory -Path ' .. Windows.Literal(Scratch) .. ' -ErrorAction Stop | Out-Null')
local Project=Scratch..'/project space'
Windows.MakeDirectory(Project..'/scripts/deeper')
Windows.MakeDirectory(Project..'/build')
Windows.MakeDirectory(Project..'/.git')
Windows.MakeDirectory(Project..'/nested/BUILD')
local Originals={['Main.lua']='print("main")\r\n',['scripts/a.lua']='return 42\n',
    ['scripts/deeper/b.lua']='return "deep"', ['empty']='', ['binary.dat']='\0\255\128'..string.rep('X',150000)}
for Name,Bytes in pairs(Originals) do Write(Project..'/'..Name,Bytes) end
for _,Name in ipairs({'build/old.lcb','.git/config','nested/BUILD/old','old.EXE','old.lcb'}) do Write(Project..'/'..Name,'excluded') end
local Files=Bundler.GetFiles(Project)
Check(#Files==5,'Recursive discovery/exclusions')
local Result=Compiler.Build(Project,{ExeName='Test'})
Check(Result.Ready==true and Result.Executable==Result.Output and Result.Output:match('%.exe$'),'Misleading EXE result')
local Bytes=assert(Read(Result.Bundle))
-- Independent decoder: no string.unpack and no production bundle reader.
local Position=1
local function Take(N)
    assert(N>=0 and Position+N-1<=#Bytes,'Truncated bundle')
    local B=Bytes:sub(Position,Position+N-1); Position=Position+N; return B
end
local function LE(Size)
    local B=Take(Size); local N=0
    for I=Size,1,-1 do N=N*256+B:byte(I) end
    return N
end
Check(Take(4)=='LCB1' and LE(4)==1,'Header')
Check(LE(4)==5,'File count')
local Seen={}
for I=1,5 do
    local Length,Size=LE(4),LE(8)
    local Name=Take(Length); local Content=Take(Size)
    Check(Originals[Name]~=nil and not Seen[Name],'Unexpected/duplicate file')
    Check(Content==Originals[Name],'Content mismatch: '..Name)
    Seen[Name]=true
    -- Actually extract and compare the bytes on disk, too.
    Windows.MakeDirectory(Scratch..'/extracted/'..(Name:match('^(.*)/') or ''))
    Write(Scratch..'/extracted/'..Name,Content)
    Check(Read(Scratch..'/extracted/'..Name)==Read(Project..'/'..Name),'Extracted bytes mismatch')
end
Check(Position==#Bytes+1,'Trailing bundle data')
Compiler.Build(Project,{ExeName='Test'})
Check(Read(Result.Bundle)==Bytes,'Repeat build changed bundle')
for _,Path in ipairs({'','../x','a/../x','/x','C:/x','C:x','a//b','a/./b','a/','a\0b','x:stream','a\\..\\b','CON','aux.txt','a.','a '}) do
    Reject(function() Bundler.ValidatePath(Path) end)
end
Check(Bundler.ValidatePath('scripts\\a.lua')=='scripts/a.lua')
local function Entry(Name,Source) return {RelativePath=Name,Path=Source or Project..'/Main.lua'} end
Reject(function() Bundler.WriteBundle({Entry('A'),Entry('a')},Result.Bundle) end)
Reject(function() Bundler.WriteBundle({Entry('a'),Entry('a/b')},Result.Bundle) end)
Reject(function() Bundler.WriteBundle({Entry('build/x')},Result.Bundle) end)
Reject(function() Bundler.WriteBundle({Entry('missing',Project..'/missing')},Result.Bundle) end)
Check(Read(Result.Bundle)==Bytes,'Failure destroyed previous bundle')
Reject(function() Compiler.Build(Project,{ExeName='../bad'}) end)
Reject(function() Compiler.Build(Project..'/missing') end)
local Empty=Scratch..'/empty project'; Windows.MakeDirectory(Empty)
Reject(function() Compiler.Build(Empty) end)
local Blocked=Scratch..'/blocked'; Windows.MakeDirectory(Blocked); Write(Blocked..'/Main.lua','return 1'); Write(Blocked..'/build','file')
Reject(function() Compiler.Build(Blocked) end)
local New=Scratch..'/new project'; Windows.MakeDirectory(New); Write(New..'/Main.lua','return 1')
Check(Read(Compiler.Build(New).Bundle)~=nil,'Output directory creation')
-- Real current-directory detection in a fresh Lua process.
local Driver=Scratch..'/cwd.lua'
Write(Driver,"local C=assert(loadfile("..string.format('%q',Root..'/Compiler.lua').."))(); C.Build()")
Check(os.execute('cd /d "'..New..'" && lua "'..Driver..'"'),'Current directory build')
local Special=Scratch..'/caf'..string.char(233).." & (space) % '"
Windows.MakeDirectory(Special)
local UnicodeName='caf'..string.char(233)..'.lua'
Write(Special..'/'..UnicodeName,'return 99')
local SpecialResult=Compiler.Build(Special,{Entry=UnicodeName})
Check(Read(SpecialResult.Bundle):find(UnicodeName,1,true)~=nil,'Representable Unicode path lost')
print('Bundle checks complete: '..Checks)

local Installed=Scratch..'/installed'; local Remote=Scratch..'/remote'
Windows.MakeDirectory(Installed); Windows.MakeDirectory(Remote)
local Base={}
for _,Name in ipairs(Updater.Files) do Base[Name]=assert(Read(Root..'/'..Name)); Write(Installed..'/'..Name,Base[Name]); Write(Remote..'/'..Name,Base[Name]) end
Write(Remote..'/VERSION','1.0.0.1\n')
local Manifest={}
for _,Name in ipairs(Updater.Files) do Manifest[#Manifest+1]=Windows.Hash(Remote..'/'..Name)..'  '..Name end
Write(Remote..'/SHA256SUMS',table.concat(Manifest,'\n'))
local function Reset()
    for _,Name in ipairs(Updater.Files) do Write(Installed..'/'..Name,Base[Name]) end
end
local function Unchanged()
    for _,Name in ipairs(Updater.Files) do Check(Read(Installed..'/'..Name)==Base[Name],'Installation damaged: '..Name) end
end
local Calls=0
local function Fetch(Name,Destination)
    Calls=Calls+1
    local B=Read(Remote..'/'..Name)
    if not B then return false end
    Write(Destination,B); return true
end
local function Update(Download, Rename)
    return Updater.UpdateCheck{Directory=Installed,Fetch=Download or Fetch,Rename=Rename}
end
local R=Update(function() return false,'HTTP 404','failed' end)
Check(R.Status=='failed' and R.Usable,'HTTP error classified as offline'); Unchanged()
R=Update(function() return false end)
Check(R.Status=='offline' and R.Usable,'Offline fallback'); Unchanged()
R=Update(function(Name,Dest) Write(Dest,Base.VERSION); return true end)
Check(R.Status=='current' and R.Usable,'Current status'); Unchanged()
R=Update(function(Name,Dest) if Name=='Builder.lua' then return false end; return Fetch(Name,Dest) end)
Check(R.Status=='failed' and R.Usable,'Failed download'); Unchanged()
R=Update(function(Name,Dest) if Name=='Builder.lua' then Write(Dest,'corrupted'); return true end; return Fetch(Name,Dest) end)
Check(R.Status=='failed' and R.Usable,'Checksum mismatch'); Unchanged()
R=Update(function(Name,Dest) if Name=='VERSION' then Write(Dest,'garbage'); return true end; return Fetch(Name,Dest) end)
Check(R.Status=='failed','Invalid version classified incorrectly'); Unchanged()
local Renames=0
R=Update(nil,function(Source,Destination)
    Renames=Renames+1
    if Renames==4 then return nil,'simulated replacement failure' end
    Check(Read(Installed..'/VERSION')==Base.VERSION,'VERSION changed before final commit')
    Windows.Publish(Source,Destination); return true
end)
Check(R.Status=='failed' and R.Usable and Renames==4,'Replacement rollback'); Unchanged()
R=Update()
Check(R.Status=='updated' and R.Usable and R.Version=='1.0.0.1','Successful update')
for _,Name in ipairs(Updater.Files) do Check(Read(Installed..'/'..Name)==Read(Remote..'/'..Name),'Installed bytes mismatch') end
Calls=0; R=Update(); Check(R.Status=='current' and Calls==1,'Redundant download on current install')
-- A manifest with a matching hash still cannot install invalid Lua syntax.
Reset()
local GoodBuilder=Read(Remote..'/Builder.lua')
Write(Remote..'/Builder.lua','invalid lua !')
local BrokenManifest={}
for _,Name in ipairs(Updater.Files) do BrokenManifest[#BrokenManifest+1]=Windows.Hash(Remote..'/'..Name)..'  '..Name end
Write(Remote..'/SHA256SUMS',table.concat(BrokenManifest,'\n'))
R=Update(); Check(R.Status=='failed' and R.Usable,'Invalid downloaded Lua accepted'); Unchanged()
Write(Remote..'/Builder.lua',GoodBuilder); Write(Remote..'/SHA256SUMS',table.concat(Manifest,'\n'))
-- Even a self-consistent release manifest must not install a malformed launcher.
local GoodLauncher=Read(Remote..'/Launcher.exe')
local GoodSidecar=Read(Remote..'/Launcher.exe.sha256')
Write(Remote..'/Launcher.exe',string.rep('X',300))
Write(Remote..'/Launcher.exe.sha256',Windows.Hash(Remote..'/Launcher.exe'))
local BadLauncherManifest={}
for _,Name in ipairs(Updater.Files) do BadLauncherManifest[#BadLauncherManifest+1]=Windows.Hash(Remote..'/'..Name)..'  '..Name end
Write(Remote..'/SHA256SUMS',table.concat(BadLauncherManifest,'\n'))
R=Update(); Check(R.Status=='failed' and R.Usable,'Malformed launcher installed'); Unchanged()
Write(Remote..'/Launcher.exe',GoodLauncher); Write(Remote..'/Launcher.exe.sha256',GoodSidecar)
Write(Remote..'/SHA256SUMS',table.concat(Manifest,'\n'))
-- Recreate an interrupted transaction, then recover from its on-disk journal.
local Stage=Installed..'/.update-stage'; Windows.MakeDirectory(Stage)
local Journal={}
for _,Name in ipairs(Updater.Files) do Write(Stage..'/'..Name..'.backup',Base[Name]); Journal[#Journal+1]=Name..' present' end
Write(Stage..'/journal',table.concat(Journal,'\n'))
Write(Installed..'/Compiler.lua',Read(Remote..'/Compiler.lua')..'\n-- interrupted update')
R=Update(); Check(R.Status=='failed' and not R.Usable,'Pending transaction allowed build')
Check(Updater.Recover(Installed),'Recovery failed'); Unchanged()
Reset(); Write(Installed..'/Compiler.lua','invalid lua !')
R=Update(function() return false end); Check(R.Status=='offline' and not R.Usable,'Broken install allowed offline')
Reset()
-- Exercise the real curl failure path against a closed loopback port.
R=Updater.UpdateCheck{Directory=Installed,URL='http://127.0.0.1:1/'}
Check(R.Status=='offline' and R.Usable,'Real offline transport fallback'); Unchanged()
-- Actual .cmd invocations use an isolated copy and the same closed endpoint.
local LocalUpdater=Read(Installed..'/Updater.lua'):gsub('https://raw.githubusercontent.com/WhoBuscusYT/LuaCompiler/main/', 'http://127.0.0.1:1/')
Write(Installed..'/Updater.lua',LocalUpdater)
Check(os.execute('call "'..Installed..'/luacompiler.cmd" build "'..Project..'" ProcessOffline'),'CMD offline build')
Check(not os.execute('call "'..Installed..'/luacompiler.cmd" build "'..Empty..'"'),'CMD failure exit')
Check(not os.execute('call "'..Installed..'/luacompiler.cmd" update'),'CMD offline update exit')
Check(os.execute('call "'..Installed..'/luacompiler.cmd" version'),'CMD version')
Reset()
-- Exercise actual command dispatch without network or process exit. The updater
-- is injected at the load boundary; all other modules are the real modules.
local function CLI(Arguments,Status)
    local UpdateCalls, ExitCode=0,0
    local Env=setmetatable({arg=Arguments},{__index=_G})
    Env.os=setmetatable({exit=function(Code) ExitCode=Code; error('TEST_EXIT',0) end},{__index=os})
    Env.loadfile=function(Path,...)
        if Path:match('Updater.lua$') then return function() return {UpdateCheck=function()
            UpdateCalls=UpdateCalls+1
            return Status or {Status='offline',Message='simulated offline',Usable=true}
        end} end end
        return loadfile(Path,...)
    end
    local Ok,Error=pcall(assert(loadfile(Root..'/GameCompile.lua','t',Env)))
    Check(Ok or Error=='TEST_EXIT','Unexpected CLI failure')
    return ExitCode,UpdateCalls
end
local Exit,Times=CLI({'build',Project,'CliOffline'})
Check(Exit==0 and Times==1,'Offline CLI build/update call count')
Exit,Times=CLI({'build',Empty}); Check(Exit~=0 and Times==1,'Build error exit code')
Exit,Times=CLI({'build',Project},{Status='offline',Message='offline',Usable=false}); Check(Exit~=0,'Invalid offline build allowed')
Exit,Times=CLI({'update'},{Status='updated',Message='ok',Usable=true}); Check(Exit==0 and Times==1,'Update command')
Exit,Times=CLI({'update'}); Check(Exit~=0 and Times==1,'Offline update exit')
Exit,Times=CLI({'version'}); Check(Exit==0 and Times==0,'Version triggers update')
Exit=CLI({'bad'}); Check(Exit~=0,'Unknown command exit')
print('PASS: '..Checks..' checks. Scratch files retained at '..Scratch)
