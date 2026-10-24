local Bundler = {}
local Directory = (debug.getinfo(1,'S').source:match('^@(.+[\\/])') or './')
local Windows = assert(loadfile(Directory .. 'Windows.lua'))()

function Bundler.ValidatePath(Path)
    assert(type(Path) == 'string' and #Path > 0, 'Empty bundle path')
    assert(not Path:find('[%z\1-\31\127:<>"|?*]'), 'Invalid bundle path')
    Path = Path:gsub('\\', '/')
    assert(Path:sub(1,1) ~= '/' and Path:sub(-1) ~= '/' and not Path:find('//',1,true), 'Path must be relative')
    for Part in Path:gmatch('[^/]+') do
        assert(Part ~= '.' and Part ~= '..' and not Part:match('[ .]$'), 'Invalid path component')
        local Stem = (Part:match('^[^.]+') or ''):upper()
        assert(not ({CON=true, PRN=true, AUX=true, NUL=true})[Stem]
            and not Stem:match('^COM[1-9]$') and not Stem:match('^LPT[1-9]$'), 'Reserved path component')
    end
    return Path
end

function Bundler.IsExcluded(Path)
    Path = Bundler.ValidatePath(Path):lower()
    for Part in Path:gmatch('[^/]+') do
        if Part == 'build' or Part == '.git' then return true end
    end
    return Path:match('%.lcb$') ~= nil or Path:match('%.exe$') ~= nil
end

function Bundler.GetFiles(ProjectPath)
    ProjectPath = Windows.FullPath(ProjectPath)
    ProjectPath = ProjectPath:gsub('/', '\\'):gsub('\\+$', '')
    local Bytes = {}
    for I = 1, #ProjectPath do Bytes[I] = tostring(ProjectPath:byte(I)) end
    -- Pass the root as byte values rather than interpolating a shell argument.
    local Script = "[Console]::OutputEncoding=[Text.Encoding]::Default; $ErrorActionPreference='Stop'; $root=[Text.Encoding]::Default.GetString([byte[]]@(" .. table.concat(Bytes, ',') .. ")); function Scan($dir) { foreach($item in Get-ChildItem -LiteralPath $dir -Force) { if($item.PSIsContainer -and $item.Name -in @('build','.git')) { continue }; if($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Links are not supported' }; if($item.PSIsContainer) { Scan $item.FullName } else { if([Text.Encoding]::Default.GetString([Text.Encoding]::Default.GetBytes($item.FullName)) -cne $item.FullName) { throw 'Path cannot be represented by this Lua runtime code page' }; $item.FullName } } }; Scan $root"
    local Handle = assert(io.popen('powershell.exe -NoProfile -NonInteractive -Command "' .. Script .. '"', 'r'))
    local Files = {}
    for FullPath in Handle:lines() do
        assert(FullPath:sub(1,#ProjectPath):lower() == ProjectPath:lower()
            and FullPath:sub(#ProjectPath+1,#ProjectPath+1) == '\\', 'File outside project root')
        local Relative = Bundler.ValidatePath(FullPath:sub(#ProjectPath+2))
        if not Bundler.IsExcluded(Relative) then
            Files[#Files+1] = {Path=FullPath, RelativePath=Relative}
        end
    end
    assert(Handle:close(), 'Project scan failed')
    table.sort(Files, function(A,B) return A.RelativePath < B.RelativePath end)
    return Files
end

function Bundler.WriteBundle(Files, OutputPath)
    assert(#Files <= 0xffffffff, 'Too many files')
    local Entries, Seen = {}, {}
    for _, File in ipairs(Files) do
        local Path = Bundler.ValidatePath(File.RelativePath)
        assert(not Bundler.IsExcluded(Path), 'Build output cannot be bundled')
        assert(not Seen[Path:lower()], 'Duplicate bundle path')
        for Other in pairs(Seen) do
            local Lower = Path:lower()
            assert(Lower:sub(1,#Other+1) ~= Other .. '/' and Other:sub(1,#Lower+1) ~= Lower .. '/',
                'File/directory path collision')
        end
        Seen[Path:lower()] = true
        assert(#Path <= 0xffffffff, 'Path too long')
        assert(File.Path ~= OutputPath, 'Output cannot be an input')
        assert(File.Content == nil or type(File.Content) == 'string', 'Invalid embedded content')
        Entries[#Entries+1] = {Path=File.Path, RelativePath=Path, Content=File.Content}
    end
    table.sort(Entries, function(A,B) return A.RelativePath < B.RelativePath end)
    local Temporary = Windows.Temporary(OutputPath)
    local Output = assert(io.open(Temporary, 'wb'))
    local Input
    local Ok, Message = pcall(function()
        assert(Output:write('LCB1', string.pack('<I4I4',1,#Entries)))
        for _, File in ipairs(Entries) do
            if File.Content ~= nil then
                assert(Output:write(string.pack('<I4I8',#File.RelativePath,#File.Content), File.RelativePath, File.Content))
            else
            Input = assert(io.open(File.Path, 'rb'))
            local Size = assert(Input:seek('end'))
            assert(Input:seek('set',0))
            assert(Output:write(string.pack('<I4I8',#File.RelativePath,Size), File.RelativePath))
            local Remaining = Size
            while Remaining > 0 do
                local Chunk = assert(Input:read(math.min(Remaining,65536)), 'Source truncated')
                assert(#Chunk > 0, 'Source truncated')
                assert(Output:write(Chunk))
                Remaining = Remaining - #Chunk
            end
            assert(not Input:read(1), 'Source changed during bundling')
            assert(Input:close())
            Input = nil
            end
        end
    end)
    if Input then Input:close() end
    local Closed, CloseError = Output:close()
    if not Ok or not Closed then os.remove(Temporary); error(Message or CloseError) end
    local Published, PublishError = pcall(Windows.Publish, Temporary, OutputPath)
    if not Published then os.remove(Temporary); error(PublishError) end
    return {Path=OutputPath, FileCount=#Entries, FormatVersion=1}
end

-- Read compiler-owned runtime archives without extracting files. The public LCB
-- layout is unchanged; the same writer accepts these in-memory entries.
function Bundler.ReadBundle(Bytes)
    assert(type(Bytes)=='string' and #Bytes>=12 and #Bytes<=67108864, 'Invalid runtime bundle size')
    assert(Bytes:sub(1,4)=='LCB1', 'Invalid runtime bundle magic')
    local Version,Count,Position=string.unpack('<I4I4',Bytes,5)
    assert(Version==1 and Count>0 and Count<=100000 and Count<=(#Bytes-12)//13, 'Invalid runtime bundle header')
    local Entries,Seen={},{}
    for I=1,Count do
        assert(#Bytes-Position+1>=12, 'Truncated runtime record')
        local Length,Size
        Length,Size,Position=string.unpack('<I4I8',Bytes,Position)
        assert(Length>0 and Length<=32768 and Length<=#Bytes-Position+1, 'Invalid runtime path length')
        local Path=Bundler.ValidatePath(Bytes:sub(Position,Position+Length-1))
        Position=Position+Length
        assert(Size>=0 and Size<=#Bytes-Position+1, 'Invalid runtime content size')
        local Key=Path:lower()
        assert(not Seen[Key], 'Duplicate runtime path')
        Seen[Key]=true
        Entries[I]={RelativePath=Path,Content=Bytes:sub(Position,Position+Size-1)}
        Position=Position+Size
    end
    assert(Position==#Bytes+1, 'Trailing runtime data')
    for Key in pairs(Seen) do
        local Prefix=''
        for Part in Key:gmatch('[^/]+') do
            if Prefix~='' then assert(not Seen[Prefix], 'Runtime file/directory collision'); Prefix=Prefix..'/' end
            Prefix=Prefix..Part
        end
    end
    return Entries
end

return Bundler


