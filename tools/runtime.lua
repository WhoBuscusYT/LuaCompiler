-- Build the redistributable framework archive after editing runtime/.
local Root=assert(arg[1], 'Compiler root required')
local Windows=assert(loadfile(Root..'/Windows.lua'))()
local Bundler=assert(loadfile(Root..'/Bundler.lua'))()
local Files=Bundler.GetFiles(Root..'/runtime')
assert(#Files>0,'No runtime files')
local License=assert(io.open(Root..'/THIRD-PARTY-LICENSES.txt','rb'))
Files[#Files+1]={RelativePath='lc/THIRD-PARTY-LICENSES.txt',Content=assert(License:read('*a'))}
assert(License:close())
local Result=Bundler.WriteBundle(Files,Root..'/Runtime.lcb')
local F=assert(io.open(Result.Path..'.sha256','wb'))
assert(F:write(Windows.Hash(Result.Path)..'\n')); assert(F:close())
print('Framework archive generated: '..Result.FileCount..' files')
