local Directory = (debug.getinfo(1,'S').source:match('^@(.+[\\/])') or './')
local function BuildArguments()
    local Positional,Config={},{}
    local I=2
    while I<=#arg do
        local Value=arg[I]
        if Value=='--mode' then I=I+1; Config.Mode=assert(arg[I], '--mode requires a value')
        elseif Value:match('^%-%-mode=') then Config.Mode=Value:sub(8)
        elseif Value=='--console' then Config.Console=true
        elseif Value=='--runtime' then Config.Runtime=true
        elseif Value:sub(1,2)=='--' then error('Unknown build option: '..Value)
        else Positional[#Positional+1]=Value end
        I=I+1
    end
    assert(#Positional<=3,'Too many build arguments')
    Config.ExeName,Config.Entry=Positional[2],Positional[3]
    return Positional[1],Config
end
local function Main()
    local Command = arg[1]
    if Command == 'build' or Command == 'update' then
        local Updater = assert(loadfile(Directory .. 'Updater.lua'))()
        local Result = Updater.UpdateCheck()
        print('[LuaCompiler] Update: ' .. Result.Status .. ' - ' .. Result.Message)
        if Command == 'update' then
            return Result.Status == 'current' or Result.Status == 'updated'
        end
        assert(Result.Usable, 'No valid compiler installation is available')
        -- Load compiler modules after updating, once per build invocation.
        local Compiler = assert(loadfile(Directory .. 'Compiler.lua'))()
        local Project,Config=BuildArguments()
        Compiler.Build(Project,Config)
        return true
    elseif Command == 'version' then
        local File = assert(io.open(Directory .. 'VERSION','rb'))
        local Version = assert(File:read('*a')):match('^%s*(.-)%s*$')
        assert(File:close())
        print('[LuaCompiler] Version ' .. Version)
        return true
    end
    error('Usage: luacompiler build [project-path] [name] [entry-script] [--mode console|gui|vulkan2d|vulkan3d] [--console] | update | version')
end
local Ok, Result = pcall(Main)
if not Ok then io.stderr:write('[LuaCompiler] ' .. tostring(Result) .. '\n') end
if not Ok or not Result then os.exit(1) end

