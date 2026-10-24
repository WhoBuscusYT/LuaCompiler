-- Compiler-owned policy, embedded in the launcher independently of project files.
-- The captured native primitive compiles directly from validated mapped bytes.
local LoadEmbedded=...
local Type,ToString,Raise=type,tostring,error
local Find,Replace=string.find,string.gsub

local function Searcher(Name)
    if Type(Name)=='number' then Name=ToString(Name) end
    if Type(Name)~='string' then
        Raise('Embedded module name must be a string',2)
    end
    if #Name==0 or #Name>32758 or Find(Name,'\0',1,true) then
        Raise('Invalid embedded module name',0)
    end
    local Path=Replace(Name,'%.','/')
    local Loader,Resolved=LoadEmbedded(Path..'.lua')
    if not Loader then Loader,Resolved=LoadEmbedded(Path..'/init.lua') end
    if Loader then return Loader,Resolved end
    return "\n\tno bundled Lua module '"..Name.."'"
end

package.searchers={package.searchers[1],Searcher}
package.path=''
package.cpath=''
package.loadlib=nil
