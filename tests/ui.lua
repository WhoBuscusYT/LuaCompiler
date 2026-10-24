-- Run as a packaged console project or with the native UI development harness.
local UI=require('lc.ui')
local Count=0
local function Check(Value,Message)
    assert(Value,Message); Count=Count+1
end
local function Reject(Function,Message)
    Check(not pcall(Function),Message)
end
local App=UI.app()
local Window=App:window{title='LuaCompiler UI automated tests',width=480,height=300,visible=false,resizable=false}
local Label=Window:label{text='initial',x=8,y=8,width=200,height=24}
local Input=Window:input{text='editable',x=8,y=40,width=200,height=28}
local CheckBox=Window:checkbox{text='check',x=8,y=76,width=180,checked=true}
local Drop=Window:dropdown{x=8,y=112,width=200,items={'one','two','café'}}
local Button=Window:button{text='click',x=240,y=40,width=100,height=28}
Check(UI.backend=='win32','Win32 backend')
Check(UI.keys.enter==13 and UI.keys.escape==27,'Public key constants')
Check(not Window:isClosed() and not Button:isClosed(),'Native windows and controls exist')
Check(Input:text()=='editable' and CheckBox:checked(),'Initial control values')
Check(Drop:selection()==1 and Drop.items[3]=='café','Dropdown items and initial selection')
Label:text('Unicode: café 世界 🎮')
Check(Label:text()=='Unicode: café 世界 🎮','UTF-8 controls round trip')
Input:text('two\nlines')
Check(Input:text()=='two\nlines','Input text round trip')
Drop:addItem('four'):selection(4)
Check(Drop:selection()==4 and Drop.items[4]=='four','Dropdown append and select')
CheckBox:checked(false)
Check(not CheckBox:checked(),'Checkbox setter')
Button:enable(false):enable(true):show(false):show(true):focus()
Button:bounds{x=242,y=42,width=104,height=30}
Check(true,'Control enable/show/focus/position operations')
Window:menu{{label='File',items={{label='Close',onClick=function() Window:requestClose() end}}}}
Check(true,'Native menu hierarchy creation')
local Clicks,Changes,Checked,Closed,Resized=0,0,false,0,0
Input:on('change',function(_,Event) Changes=Changes+1; Check(type(Event.text)=='string','Input event text') end)
Button:on('click',function(Target,Event) Check(Target==Button and Event.object==Button,'Lua callback identity'); Clicks=Clicks+1 end)
CheckBox:on('click',function(_,Event) Checked=Event.checked end)
Window:on('resize',function(_,Event) if Event.width>0 and Event.height>0 then Resized=Resized+1 end end)
Window:on('closed',function() Closed=Closed+1 end)
Input:text('changed')
Button:click(); CheckBox:click()
Window:bounds{x=100,y=100,width=500,height=320}
App:step(0)
Check(Clicks==1 and Changes>=1,'Native button and edit notifications reach Lua')
Check(Checked and CheckBox:checked(),'Native checkbox click changes state and callback')
Check(Resized>=1,'Native resize reaches Lua')
Reject(function() Window:button{onClick=3} end,'Invalid callback rejected before control creation')
Reject(function() App:window{width=0,visible=false} end,'Invalid dimensions rejected')
Reject(function() App:window{visible=false,menu={{label='bad',onClick=4}}} end,'Invalid menu construction rolls window back')
Reject(function() Window:dropdown{items={'one',{} }} end,'Partial control initialization rolls back')
Reject(function() Input:checked() end,'Wrong control type rejected')
Reject(function() Drop:selection(99) end,'Invalid dropdown index rejected')
Reject(function() Label:text(string.char(255)) end,'Malformed UTF-8 rejected')
Reject(function() Window:on('unknown',function() end) end,'Unknown event rejected')
Reject(function() App:quit(256) end,'Invalid application exit code rejected')
local Cancel=true
Window:on('close',function() if Cancel then return false end end)
Window:requestClose(); App:step(0)
Check(not Window:isClosed(),'Close callback can veto close')
Cancel=false
Window:requestClose(); App:step(0)
Check(Window:isClosed() and Input:isClosed() and Button:isClosed(),'Parent destruction closes controls')
Check(Closed==1,'Final closed callback delivered once')
Window:close(); App:close()
Check(Window:isClosed(),'Shutdown is idempotent')
Reject(function() Input:text() end,'Use after close is a Lua error')

local Fault=UI.app()
local FaultWindow=Fault:window{title='UI callback failure cleanup',visible=false}
local FaultButton=FaultWindow:button{onClick=function() error('EXPECTED_UI_CALLBACK_FAILURE') end}
FaultButton:click()
local OK,Error=pcall(function() Fault:run() end)
Check(not OK and tostring(Error):find('EXPECTED_UI_CALLBACK_FAILURE',1,true),'Callback error propagates')
Check(FaultWindow:isClosed() and FaultButton:isClosed(),'Callback error closes all application resources')

local Quit=UI.app()
local QuitWindow=Quit:window{title='UI exit status',visible=false}
QuitWindow:button{onClick=function() Quit:quit(7) end}:click()
Check(Quit:run()==7 and QuitWindow:isClosed(),'Application exit code and cleanup')
collectgarbage('collect')
print('NATIVE_UI_TESTS_OK '..Count)
return 0
