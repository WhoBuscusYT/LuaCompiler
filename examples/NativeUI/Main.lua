local UI=require('lc.ui')
local App=UI.app()
local Testing=arg[1]=='--self-test'
local Window=App:window{title='LuaCompiler Native UI',width=520,height=330,
    visible=not Testing,resizable=true}
Window:label{text='Your name',x=24,y=24,width=180,height=24}
local Name=Window:input{text='Lua developer',x=24,y=54,width=280,height=28}
local Greeting=Window:label{text='Press Greet to run a Lua callback.',x=24,y=224,width=465,height=40}
local Excited=Window:checkbox{text='Add an exclamation mark',x=24,y=104,width=280,height=28,checked=true}
local Language=Window:dropdown{x=24,y=148,width=180,items={'Hello','Bonjour','Hola'}}
local Clicks,Changes,Closes=0,0,0
Name:on('change',function() Changes=Changes+1 end)
local Greet=Window:button{text='Greet',x=328,y=54,width=140,height=30,onClick=function()
    Clicks=Clicks+1
    Greeting:text(Language.items[Language:selection()]..', '..Name:text()..(Excited:checked() and '!' or '.'))
end}
Window:menu{{label='File',items={{label='Exit',onClick=function() Window:requestClose() end}}},
    {label='Help',items={{label='About',onClick=function()
        Window:dialog{title='About LuaCompiler',message='Native Win32 controls. Application behavior written in Lua.'}
    end}}}}
Window:on('close',function() Closes=Closes+1 end)

if Testing then
    assert(UI.backend=='win32' and Name:text()=='Lua developer')
    assert(Excited:checked() and Language:selection()==1)
    Name:text('Standalone UTF-8: café')
    Language:selection(2)
    Excited:checked(false)
    Greet:click()
    for _=1,100 do if not App:step(0) then break end end
    assert(Clicks==1 and Changes>=1,'Native control callbacks were not dispatched')
    assert(Greeting:text()=='Bonjour, Standalone UTF-8: café.','Native UTF-8 control text mismatch')
    local Cancel=true
    Window:on('close',function() Closes=Closes+1; if Cancel then return false end end)
    Window:requestClose()
    for _=1,100 do if not App:step(0) then break end end
    assert(not Window:isClosed() and Closes==1,'Close cancellation failed')
    Cancel=false; Window:requestClose()
    for _=1,100 do if not App:step(0) then break end end
    assert(Window:isClosed() and Closes==2 and Name:isClosed(),'Native shutdown failed')
    App:close()
    print('NATIVE_UI_SELF_TEST_OK')
    return 0
end

return App:run()
