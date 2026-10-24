-- The development host changes only its own SDL window via native test hooks.
package.path='./runtime/?.lua;./runtime/?/init.lua;'..package.path
local renderer=require('lc.backends.vulkan').new{title='LuaCompiler owned platform test',width=400,height=300}
local minimized,restored,blur=false,false,false
local ok,why=xpcall(function()
    for frame=1,120 do
        if frame==3 then graphics_test.minimize(renderer.window) end
        if frame==20 then graphics_test.restore(renderer.window) end
        for _,event in ipairs(renderer:poll()) do if event.type=='blur' then blur=true end end
        local width,height=renderer:size()
        if width==0 and height==0 then minimized=true end
        if minimized and width>0 and height>0 then restored=true end
        renderer:render({},{.07,.09,.14,1})
        renderer:sleep(10)
        if minimized and restored then break end
    end
end,debug.traceback)
renderer:close()
assert(ok,why)
assert(minimized,'Did not observe zero-sized minimized window')
assert(restored,'Did not observe restored window size')
print('VULKAN_PLATFORM_OK minimized=true restored=true blur='..tostring(blur))
