-- Stop other compiler processes before running this recovery tool.
local Root=assert(arg[1], 'Compiler installation root required')
local U=assert(loadfile(Root .. '/Updater.lua'))()
local Ok,Error=U.Recover(Root)
if not Ok then io.stderr:write(tostring(Error) .. '\n'); os.exit(1) end
print('Update recovery completed.')
