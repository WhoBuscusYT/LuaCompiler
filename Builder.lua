local Builder = {}
local Directory = (debug.getinfo(1,'S').source:match('^@(.+[\\/])') or './')
local Bundler = assert(loadfile(Directory .. 'Bundler.lua'))()
local Windows = assert(loadfile(Directory .. 'Windows.lua'))()
local function Read(Path)
    local F=assert(io.open(Path,'rb'))
    local Bytes=assert(F:read('*a')); assert(F:close()); return Bytes
end
local function Copy(InputPath, Output)
    local Input=assert(io.open(InputPath,'rb'))
    local Ok,Error=pcall(function()
        while true do
            local Bytes=Input:read(65536)
            if not Bytes then break end
            assert(Output:write(Bytes))
        end
    end)
    Input:close(); assert(Ok,Error)
end
local function Run(Executable, Command)
    -- Explicitly wait for GUI processes as well as console executables.
    return Windows.Run('$p=New-Object Diagnostics.Process; $p.StartInfo.FileName='..Windows.Literal(Executable)
        ..'; $p.StartInfo.Arguments='..Windows.Literal(Command)
        ..'; $p.StartInfo.UseShellExecute=$false; $p.StartInfo.RedirectStandardOutput=$true; '
        ..'$p.StartInfo.RedirectStandardError=$true; $p.StartInfo.CreateNoWindow=$true; '
        ..'[void]$p.Start(); $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync(); '
        ..'if(-not $p.WaitForExit(30000)) { $p.Kill(); throw "Launcher validation timed out" }; '
        ..'$p.WaitForExit(); if($p.ExitCode -ne 0) { throw $err.Result }; [Console]::Write($out.Result); $p.Dispose()')
end
local Modes={console=true,gui=true,vulkan2d=true,vulkan3d=true}
local function RuntimeFiles(Files)
    local RuntimePath=Directory..'Runtime.lcb'
    local Digest=Read(RuntimePath..'.sha256'):match('^%s*(%x+)%s*$')
    assert(Digest and #Digest==64 and Windows.Hash(RuntimePath)==Digest:lower(), 'Runtime archive checksum mismatch')
    local Combined={}
    for _,File in ipairs(Files) do Combined[#Combined+1]=File end
    for _,File in ipairs(Bundler.ReadBundle(Read(RuntimePath))) do Combined[#Combined+1]=File end
    return Combined
end
local function SetGUISubsystem(Path)
    local F=assert(io.open(Path,'r+b'))
    local Ok,Error=pcall(function()
        assert(F:seek('set',60)); local PE=string.unpack('<I4',assert(F:read(4)))
        assert(F:seek('set',PE)); assert(F:read(4)=='PE\0\0','Invalid launcher PE signature')
        assert(F:seek('set',PE+92)); assert(F:write(string.pack('<I2',2)))
    end)
    local Closed,CloseError=F:close(); assert(Ok and Closed,Error or CloseError)
end
function Builder.ValidateTemplate()
    local Template=Windows.FullPath(Directory..'Launcher.exe')
    local Hash=Read(Template..'.sha256'):match('^%s*(%x+)%s*$')
    assert(Hash and #Hash==64 and Windows.Hash(Template)==Hash:lower(),'Launcher template checksum mismatch')
    local F=assert(io.open(Template,'rb'))
    local Size=assert(F:seek('end')); F:close()
    assert(Size>=256 and Size<=67108864,'Invalid launcher template size')
    assert(Run(Template,'--luacompiler-probe')=='LuaCompiler launcher 1 Lua 5.4','Invalid launcher template')
    return Template,Size
end
function Builder.Build(ProjectPath, Files, Config)
    Config=Config or {}
    local Mode=Config.Mode or 'console'
    assert(Modes[Mode], 'Invalid build mode; expected console, gui, vulkan2d, or vulkan3d')
    local Name=Config.ExeName or 'Game'
    assert(type(Name)=='string' and Name:match('^[%w_-]+$'),'Invalid executable name')
    Bundler.ValidatePath(Name)
    local Entry=Bundler.ValidatePath(Config.Entry or 'Main.lua')
    local Found=false
    for _,File in ipairs(Files) do
        if File.RelativePath==Entry then Found=true end
    end
    assert(Found,'Entry script is missing from bundle: '..Entry)
    local Template,StubSize=Builder.ValidateTemplate()
    if Mode~='console' or Config.Runtime then
        assert(Run(Template,'--luacompiler-capabilities')=='LuaCompiler runtime 1 console gui vulkan2d vulkan3d',
            'Launcher does not support the desktop framework; install a matching compiler package')
        Files=RuntimeFiles(Files)
    end
    local OutputDirectory=ProjectPath:gsub('[\\/]+$','')..'\\build'
    Windows.MakeDirectory(OutputDirectory)
    local BundlePath=OutputDirectory..'\\'..Name..'.lcb'
    local Bundle=Bundler.WriteBundle(Files,BundlePath)
    local Executable=OutputDirectory..'\\'..Name..'.exe'
    local Reserved,Pending,Payload,Output
    local Ok,Error=pcall(function()
        Reserved=Windows.Temporary(Executable)
        Pending=Reserved..'.exe'
        assert(os.rename(Reserved,Pending))
        Payload=Windows.Temporary(BundlePath)
        -- LCB v1 remains byte-for-byte unchanged. Encoding is recorded in the EXE footer.
        local CodePage=tonumber(Windows.Run('[Text.Encoding]::Default.CodePage'))
        assert(CodePage,'Cannot determine bundle filename encoding')
        local EntryUTF8=Windows.Run('[Console]::OutputEncoding=[Text.Encoding]::UTF8; [Console]::Write('..Windows.Literal(Entry)..')')
        Output=assert(io.open(Payload,'wb'))
        Copy(BundlePath,Output); assert(Output:write(EntryUTF8)); assert(Output:close()); Output=nil
        local PayloadHash=Windows.Hash(Payload):gsub('%x%x',function(Pair) return string.char(tonumber(Pair,16)) end)
        local F=assert(io.open(BundlePath,'rb')); local BundleSize=assert(F:seek('end')); assert(F:close())
        assert(BundleSize<=1073741824 and #EntryUTF8<=32768,'Bundle exceeds launcher limits')
        Output=assert(io.open(Pending,'wb'))
        Copy(Template,Output); Copy(Payload,Output)
        assert(Output:write(string.pack('<c8I8I8I4I4c32','LCBEXE1\0',StubSize,BundleSize,#EntryUTF8,CodePage,PayloadHash)))
        assert(Output:close()); Output=nil
        if Mode~='console' and not Config.Console then SetGUISubsystem(Pending) end
        assert(Run(Pending,'--luacompiler-validate')=='LuaCompiler executable valid','Executable validation failed')
        Windows.Publish(Pending,Executable)
    end)
    if Output then Output:close() end
    if Reserved then os.remove(Reserved) end
    if Pending then os.remove(Pending) end
    if Payload then os.remove(Payload) end
    assert(Ok,Error)
    print('[LuaCompiler] Executable: '..Executable)
    return {Output=Executable,Executable=Executable,Bundle=Bundle.Path,FileCount=Bundle.FileCount,Ready=true,Entry=Entry,Mode=Mode}
end
return Builder
