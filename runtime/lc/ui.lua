-- The public desktop framework: ownership, events and application loops stay Lua.
local Native = require('lc_native_ui')
local UI = {backend=Native.backend, keys={escape=27,enter=13,tab=9,space=32,left=37,up=38,right=39,down=40}}
local App, Object = {}, {}
App.__index, Object.__index = App, Object

local function Callback(Options, Name)
    local Value=Options[Name]
    assert(Value==nil or type(Value)=='function',Name..' must be a function')
    return Value
end

local CallbackNames={click='onClick',change='onChange',close='onClose',closed='onClosed',
    resize='onResize',key_down='onKeyDown',key_up='onKeyUp',text='onText',
    mouse_move='onMouseMove',mouse_down='onMouseDown',mouse_up='onMouseUp',mouse_wheel='onMouseWheel'}

local function CheckText(Text)
    assert(type(Text)=='string' and not Text:find('%z') and utf8.len(Text),'UI text must be valid UTF-8')
end

local function CheckOptions(Options)
    assert(type(Options)=='table','UI options must be a table')
    for _,Name in pairs(CallbackNames) do Callback(Options,Name) end
    if Options.title~=nil then CheckText(Options.title) end
    if Options.text~=nil then CheckText(Options.text) end
end

local function Wrap(Application, Handle, Kind, Options, Parent)
    local Result=setmetatable({app=Application,native=Handle,kind=Kind,parent=Parent,
        children={},callbacks={},items=Options.items or {}},Object)
    for Event,Name in pairs(CallbackNames) do Result.callbacks[Event]=Callback(Options,Name) end
    Application.objects[Handle:id()]=Result
    if Parent then Parent.children[#Parent.children+1]=Result end
    return Result
end

function UI.app()
    return setmetatable({objects={},windows={},running=false,exitCode=0,nextMenu=0},App)
end

function App:window(Options)
    Options=Options or {}
    CheckOptions(Options)
    local Result=Wrap(self,Native.window(Options),'window',Options)
    self.windows[#self.windows+1]=Result
    local OK,Error=pcall(function() if Options.menu then Result:menu(Options.menu) end end)
    if not OK then
        Result:close(); self.objects[Result.native:id()]=nil
        self.windows[#self.windows]=nil; error(Error,0)
    end
    return Result
end

function Object:on(Event, Handler)
    assert(CallbackNames[Event] or Event=='menu','Unknown event: '..tostring(Event))
    assert(Handler==nil or type(Handler)=='function','Event handler must be a function')
    self.callbacks[Event]=Handler
    return self
end

function Object:control(Kind, Options)
    assert(self.kind=='window','Controls require a window')
    Options=Options or {}
    CheckOptions(Options)
    local Result=Wrap(self.app,Native.control(self.native,Kind,Options),Kind,Options,self)
    local OK,Error=pcall(function()
        if Kind=='checkbox' then Result:checked(Options.checked or false) end
        if Kind=='dropdown' then
            Result.items={}
            for _,Text in ipairs(Options.items or {}) do Result:addItem(Text) end
            if #Result.items>0 then Result:selection(Options.selected or 1) end
        end
        if Options.enabled~=nil then Result:enable(Options.enabled) end
        if Options.visible==false then Result:show(false) end
    end)
    if not OK then
        Result:close(); self.app.objects[Result.native:id()]=nil
        self.children[#self.children]=nil; error(Error,0)
    end
    return Result
end

for _,Kind in ipairs({'button','label','input','checkbox','dropdown'}) do
    Object[Kind]=function(self,Options) return self:control(Kind,Options) end
end

function Object:text(Value)
    if Value==nil then return self.native:text() end
    self.native:text(Value); return self
end
function Object:checked(Value)
    assert(self.kind=='checkbox','checked requires a checkbox')
    if Value==nil then return self.native:checked() end
    self.native:checked(Value); return self
end
function Object:selection(Value)
    assert(self.kind=='dropdown','selection requires a dropdown')
    if Value==nil then return self.native:selection() end
    self.native:selection(Value); return self
end
function Object:addItem(Text)
    assert(self.kind=='dropdown' and type(Text)=='string','addItem requires dropdown text')
    self.native:add_item(Text); self.items[#self.items+1]=Text; return self
end
function Object:bounds(Options) self.native:bounds(Options); return self end
function Object:focus() self.native:focus(); return self end
function Object:show(Visible) self.native:show(Visible~=false); return self end
function Object:enable(Enabled) self.native:enable(Enabled~=false); return self end
function Object:isClosed() return self.native:closed() end
function Object:close() self.native:close(); return self end
function Object:requestClose()
    assert(self.kind=='window','requestClose requires a window')
    self.native:request_close(); return self
end
function Object:click()
    assert(self.kind=='button' or self.kind=='checkbox','click requires a button or checkbox')
    self.native:click(); return self
end

function Object:menu(Entries)
    assert(self.kind=='window' and type(Entries)=='table','menu requires a window and entries')
    local Handlers={}
    local function Copy(Items,Depth)
        assert(Depth<=8,'Menu nesting is too deep')
        local Result={}
        for _,Item in ipairs(Items) do
            assert(type(Item)=='table' and type(Item.label)=='string','Menu entries require labels')
            CheckText(Item.label)
            local Entry={label=Item.label}
            if Item.items then Entry.items=Copy(Item.items,Depth+1)
            else
                self.app.nextMenu=self.app.nextMenu+1
                assert(self.app.nextMenu<=65535,'Menu item limit reached')
                Entry.id=self.app.nextMenu
                assert(Item.onClick==nil or type(Item.onClick)=='function','Menu callback must be a function')
                Handlers[Entry.id]=Item.onClick
            end
            Result[#Result+1]=Entry
        end
        return Result
    end
    self.native:menu(Copy(Entries,0)); self.menuHandlers=Handlers; return self
end

function UI.dialog(Options)
    assert(type(Options)=='table','dialog requires options')
    CheckText(Options.title or 'LuaCompiler'); CheckText(Options.message or '')
    assert(Options.kind==nil or ({info=true,warning=true,error=true,question=true})[Options.kind],
        'Unknown native dialog kind')
    return Native.dialog(Options.parent and Options.parent.native or nil,
        Options.title or 'LuaCompiler',Options.message or '',Options.kind or 'info')
end
function Object:dialog(Options)
    Options=Options or {}; Options.parent=self.kind=='window' and self or self.parent
    return UI.dialog(Options)
end

function App:dispatch(Event)
    local Target=self.objects[Event.target]
    if not Target then return end
    -- Destruction can leave input notifications already queued by Win32.
    if Target:isClosed() and Event.type~='closed' then return end
    if Event.type=='closed' then
        if Target.closedDispatched then return end
        Target.closedDispatched=true
    end
    Event.object=Target
    if Event.type=='resize' then Event.width,Event.height=Event.x,Event.y end
    if Event.type=='text' then Event.text=utf8.char(Event.code) end
    if Event.type=='key_down' or Event.type=='key_up' then Event.key=Event.code end
    if Event.type=='mouse_down' or Event.type=='mouse_up' then Event.button=Event.code end
    if Event.type=='mouse_wheel' then Event.delta=Event.code/120 end
    if not Target:isClosed() then
        if Event.type=='change' and Target.kind=='input' then Event.text=Target:text() end
        if Event.type=='click' and Target.kind=='checkbox' then Event.checked=Target:checked() end
        if Event.type=='change' and Target.kind=='dropdown' then
            Event.index=Target:selection(); Event.value=Target.items[Event.index]
        end
    end
    local Handler=Target.callbacks[Event.type]
    if Event.type=='menu' and Target.menuHandlers then Handler=Target.menuHandlers[Event.code] or Handler end
    local Result
    if Handler then Result=Handler(Target,Event) end
    if Event.type=='close' and Result~=false and not Target:isClosed() then Target:close() end
    return Result
end

function App:step(Timeout)
    local Event=Native.poll(Timeout or 0)
    if not Event then return false end
    local Count=0
    repeat
        self:dispatch(Event)
        Count=Count+1
        Event=Count<1024 and Native.poll(0) or nil
    until not Event
    return true
end

function App:hasWindows()
    for _,Window in ipairs(self.windows) do if not Window:isClosed() then return true end end
    return false
end

function App:quit(Code)
    assert(Code==nil or math.type(Code)=='integer' and Code>=0 and Code<=255,'Exit code must be 0..255')
    self.exitCode=Code or 0; self.running=false
end

function App:close()
    self.running=false
    for _,Window in ipairs(self.windows) do if not Window:isClosed() then Window:close() end end
end

function App:run()
    assert(not self.running,'Application loop is already running')
    self.running=true
    local OK,Error=xpcall(function()
        while self.running and self:hasWindows() do self:step(16) end
    end,debug.traceback)
    self:close()
    if not OK then error(Error,0) end
    return self.exitCode
end

return UI
