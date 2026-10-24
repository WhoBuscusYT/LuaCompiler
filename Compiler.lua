local Compiler = {}
local Directory = (debug.getinfo(1,'S').source:match('^@(.+[\\/])') or './')
local Bundler = assert(loadfile(Directory .. 'Bundler.lua'))()
local Builder = assert(loadfile(Directory .. 'Builder.lua'))()

function Compiler.Build(ProjectPath, Config)
    local Windows = assert(loadfile(Directory .. 'Windows.lua'))()
    ProjectPath = Windows.FullPath(ProjectPath)
    print('[LuaCompiler] Project: ' .. ProjectPath)
    local Files = Bundler.GetFiles(ProjectPath)
    assert(#Files > 0, '[LuaCompiler] No project files found')
    return Builder.Build(ProjectPath, Files, Config)
end

return Compiler
