local Root, Scratch=assert(arg[1]),assert(arg[2])
local W=assert(loadfile(Root..'/Windows.lua'))()
local U=assert(loadfile(Root..'/Updater.lua'))()
local function Read(P) local F=assert(io.open(P,'rb')); local B=assert(F:read('*a')); assert(F:close()); return B end
local function Write(P,B) local F=assert(io.open(P,'wb')); assert(F:write(B)); assert(F:close()) end
W.Run('New-Item -ItemType Directory -Path '..W.Literal(Scratch)..' -ErrorAction Stop | Out-Null')
local Remote=Scratch..'/remote'; local Local=Scratch..'/installed'
W.MakeDirectory(Remote); W.MakeDirectory(Local)
local Base={}
for _,N in ipairs(U.Files) do Base[N]=Read(Root..'/'..N); Write(Remote..'/'..N,Base[N]); Write(Local..'/'..N,Base[N]) end
Write(Remote..'/VERSION','1.0.0.1')
local Lines={}
for _,N in ipairs(U.Files) do Lines[#Lines+1]=W.Hash(Remote..'/'..N)..'  '..N end
Write(Remote..'/SHA256SUMS',table.concat(Lines,'\n'))
local Count=0
local R=U.UpdateCheck{Directory=Local, Fetch=function(N,D) Write(D,Read(Remote..'/'..N)); return true end,
    Rename=function(S,D) Count=Count+1; if Count==3 then return nil,'injected failure' end; W.Publish(S,D); return true end,
    Restore=function() error('injected restore failure') end}
assert(R.Status=='failed' and not R.Usable,'Incomplete rollback permitted build')
assert(Read(Local..'/.update-stage/Windows.lua.backup')==Base['Windows.lua'],'Backup lost')
assert(U.Recover(Local),'Recovery failed')
for _,N in ipairs(U.Files) do assert(Read(Local..'/'..N)==Base[N],'Recovery mismatch: '..N) end
Write(Local..'/Updater.lua',Read(Local..'/Updater.lua'):gsub('https://raw.githubusercontent.com/WhoBuscusYT/LuaCompiler/main/','http://127.0.0.1:1/'))
print('PASS: failed rollback blocks builds; recovery restores all component files.')
print('Isolated CLI installation: '..Local)
