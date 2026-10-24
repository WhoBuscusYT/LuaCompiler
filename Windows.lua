-- Windows facilities used by the standard Lua modules. Paths never become shell code.
local Windows = {}
function Windows.Literal(Value)
    local Bytes = {}
    for I=1,#Value do Bytes[I]=tostring(Value:byte(I)) end
    return '([Text.Encoding]::Default.GetString([byte[]]@(' .. table.concat(Bytes, ',') .. ')))'
end
function Windows.Run(Script)
    local Handle = assert(io.popen('powershell.exe -NoProfile -NonInteractive -Command "[Console]::OutputEncoding=[Text.Encoding]::Default; $ErrorActionPreference=\'Stop\'; ' .. Script .. '"', 'r'))
    local Result = Handle:read('*a')
    local Ok = Handle:close()
    assert(Ok, 'Windows operation failed')
    local Trimmed=Result:gsub('[\r\n]+$', '')
    return Trimmed
end
function Windows.FullPath(Path)
    local Expression = Path and Windows.Literal(Path) or '(Get-Location).Path'
    return Windows.Run('[IO.Path]::GetFullPath(' .. Expression .. ')')
end
function Windows.MakeDirectory(Path)
    Windows.Run('$p=' .. Windows.Literal(Path) .. '; if(Test-Path -LiteralPath $p) { $i=Get-Item -LiteralPath $p -Force; if(-not $i.PSIsContainer -or ($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw \'Unsafe output directory\' } }; [IO.Directory]::CreateDirectory($p) | Out-Null')
end
function Windows.Hash(Path)
    return Windows.Run('$f=[IO.File]::OpenRead(' .. Windows.Literal(Path)
        .. "); try { $sha=[Security.Cryptography.SHA256]::Create(); try { [BitConverter]::ToString($sha.ComputeHash($f)).Replace('-','') } finally { $sha.Dispose() } } finally { $f.Dispose() }"):lower()
end
function Windows.Publish(Source, Destination)
    Windows.Run('$src=' .. Windows.Literal(Source) .. '; $dst=' .. Windows.Literal(Destination)
        .. "; if(Test-Path -LiteralPath $dst) { $backup=$dst + '.' + [guid]::NewGuid().ToString('N') + '.previous'; [IO.File]::Replace($src,$dst,$backup); Remove-Item -LiteralPath $backup -ErrorAction SilentlyContinue } else { [IO.File]::Move($src,$dst) }")
end
function Windows.Temporary(Destination)
    return Windows.Run('$p=' .. Windows.Literal(Destination) .. " + '.' + [guid]::NewGuid().ToString('N') + '.pending'; $f=[IO.File]::Open($p,[IO.FileMode]::CreateNew); $f.Close(); $p")
end
return Windows

