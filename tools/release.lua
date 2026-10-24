-- Run from any directory: lua tools/release.lua ABSOLUTE_COMPILER_ROOT
local Root=assert(arg[1], 'Compiler root required')
local W=assert(loadfile(Root .. '/Windows.lua'))()
local U=assert(loadfile(Root .. '/Updater.lua'))()
assert(U.ValidateInstallation(Root))
local Lines={}
for _,Name in ipairs(U.Files) do Lines[#Lines+1]=W.Hash(Root .. '/' .. Name) .. '  ' .. Name end
local F=assert(io.open(Root .. '/SHA256SUMS','wb'))
assert(F:write(table.concat(Lines,'\n') .. '\n')); assert(F:close())
print('SHA256SUMS generated; publish it with every listed component and VERSION.')
