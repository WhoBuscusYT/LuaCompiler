-- Runtime archive parser and in-memory writer checks, including malformed bounds.
local Root,Scratch=assert(arg[1]),assert(arg[2])
local B=assert(loadfile(Root..'/Bundler.lua'))()
local W=assert(loadfile(Root..'/Windows.lua'))()
local Checks=0
local function check(Value,Message) assert(Value,Message); Checks=Checks+1 end
local function reject(Bytes) check(not pcall(B.ReadBundle,Bytes),'Malformed runtime accepted') end
local function record(Name,Content) return string.pack('<I4I8',#Name,#Content)..Name..Content end
local function bundle(Records) return 'LCB1'..string.pack('<I4I4',1,#Records)..table.concat(Records) end
local Data=bundle{record('lc/a.lua','return 42'),record('lc/empty',''),record('lc/data','\0\255\128')}
local E=B.ReadBundle(Data)
check(#E==3 and E[1].Content=='return 42' and E[2].Content=='' and E[3].Content=='\0\255\128','Exact in-memory bytes')
for I=0,#Data-1 do reject(Data:sub(1,I)) end
reject(Data..'extra')
reject('BAD1'..Data:sub(5))
reject('LCB1'..string.pack('<I4I4',2,1)..record('ok',''))
reject('LCB1'..string.pack('<I4I4',1,0xffffffff))
reject(bundle{record('../escape','x')})
reject(bundle{record('C:/escape','x')})
reject(bundle{record('lc/a','x'),record('LC/A','y')})
reject(bundle{record('lc/a','x'),record('lc/a/b','y')})
reject('LCB1'..string.pack('<I4I4I4I8',1,1,1,math.maxinteger)..'a')
W.Run('New-Item -ItemType Directory -Path '..W.Literal(Scratch)..' -ErrorAction Stop | Out-Null')
local Path=Scratch..'/runtime.lcb'
B.WriteBundle(E,Path)
local F=assert(io.open(Path,'rb')); local Written=assert(F:read('*a')); assert(F:close())
local Roundtrip=B.ReadBundle(Written)
local Map={}; for _,File in ipairs(Roundtrip) do Map[File.RelativePath]=File.Content end
for _,File in ipairs(E) do check(Map[File.RelativePath]==File.Content,'Virtual input changed bytes') end
check(not pcall(B.WriteBundle,{{RelativePath='a',Content='x'},{RelativePath='A',Content='y'}},Path),'Virtual duplicate accepted')
check(not pcall(B.WriteBundle,{{RelativePath='build/a',Content='x'}},Path),'Virtual build output accepted')
print('PASS: '..Checks..' runtime archive checks')
