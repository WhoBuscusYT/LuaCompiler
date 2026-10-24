package.path='./runtime/?.lua;./runtime/?/init.lua;'..package.path
local backend=require('lc.backends.vulkan')
local renderer=backend.new{title='LuaCompiler actual Vulkan smoke',width=640,height=480}
print('Vulkan GPU: '..renderer.deviceName)
local function vertex(x,y,z,r,g,b) return string.pack('<ffffffffff',x,y,z,1,r,g,b,1,0,0) end
local triangles=vertex(-.8,.7,.5,1,.1,.1)..vertex(.8,.7,.5,.1,1,.1)..vertex(0,-.8,.5,.1,.3,1)
local ok,why=xpcall(function()
    renderer:capture(assert(arg[1],'Screenshot output path required'))
    for frame=1,8 do
        renderer:poll()
        if frame==3 then renderer:resize(720,480) end
        renderer:render({{vertices=triangles,depth=true}},{.04,.05,.08,1})
        renderer:sleep(10)
    end
end,debug.traceback)
renderer:close()
assert(ok,why)
print('VULKAN_SMOKE_OK')
