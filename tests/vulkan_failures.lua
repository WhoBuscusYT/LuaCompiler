-- Development-only failure injection, run through graphics-test.exe.
package.path='./runtime/?.lua;./runtime/?/init.lua;'..package.path
local vk=require('moonvulkan')
local Backend=require('lc.backends.vulkan')
local checks=0
local function check(value,message) assert(value,message); checks=checks+1 end
local renderer=Backend.new{width=320,height=240,title='LuaCompiler Vulkan cleanup tests'}
local native=require('lc_native_graphics')
local width,height=renderer:size()
for _,dimension in ipairs({0,-1,16385,4294967936,4294967776,math.maxinteger,math.mininteger,1.5}) do
    check(not pcall(native.create,{width=dimension,height=128}),
        'Native create accepted invalid width: '..tostring(dimension))
    check(not pcall(native.create,{width=128,height=dimension}),
        'Native create accepted invalid height: '..tostring(dimension))
    check(not pcall(renderer.window.resize,renderer.window,dimension,128),
        'Native resize accepted invalid width: '..tostring(dimension))
    check(not pcall(renderer.window.resize,renderer.window,128,dimension),
        'Native resize accepted invalid height: '..tostring(dimension))
end
local nextWidth,nextHeight=renderer:size()
check(nextWidth==width and nextHeight==height,'Rejected native resizes changed the window dimensions')
local function vertex(x,y) return string.pack('<ffffffffff',x,y,.5,1,1,1,1,1,0,0) end
local triangle=vertex(-.5,.5)..vertex(.5,.5)..vertex(0,-.5)
renderer:render{{vertices=triangle,depth=true}}
local old=renderer.vertices
local allocate=vk.allocate_memory
vk.allocate_memory=function() error('INJECTED_ALLOCATION_FAILURE') end
local ok,why=pcall(renderer.render,renderer,{{vertices=triangle:rep(1000),depth=true}})
vk.allocate_memory=allocate
check(not ok and tostring(why):find('INJECTED_ALLOCATION_FAILURE',1,true),'Vertex allocation failure was not injected')
check(renderer.vertices==old and old.buffer and old.memory,'Failed growth retired previous vertex storage')
check(renderer:render{{vertices=triangle,depth=true}},'Renderer did not recover after failed growth')

local calls,destroyedBuffers,destroyedImages=0,0,0
local destroyBuffer,destroyImage=vk.destroy_buffer,vk.destroy_image
vk.allocate_memory=function(...)
    calls=calls+1
    if calls==2 then error('INJECTED_TEXTURE_ALLOCATION_FAILURE') end
    return allocate(...)
end
vk.destroy_buffer=function(...) destroyedBuffers=destroyedBuffers+1; return destroyBuffer(...) end
vk.destroy_image=function(...) destroyedImages=destroyedImages+1; return destroyImage(...) end
ok,why=pcall(renderer.texture,renderer,2,2,string.rep('\255',16))
vk.allocate_memory=allocate; vk.destroy_buffer=destroyBuffer; vk.destroy_image=destroyImage
check(not ok and tostring(why):find('INJECTED_TEXTURE_ALLOCATION_FAILURE',1,true),'Texture allocation failure was not injected')
check(destroyedBuffers==1 and destroyedImages==1,'Partial texture upload did not release staging and image')
check(renderer:texture(2,2,string.rep('\255',16))~=nil,'Texture allocation did not recover')

renderer:capture(assert(arg[1])..'/nonexistent-subdirectory/capture.bmp')
ok=pcall(renderer.render,renderer,{{vertices=triangle}})
check(not ok and renderer.readback==nil,'Screenshot failure retained readback allocation')
check(renderer:render{{vertices=triangle}},'Renderer did not recover after screenshot failure')

local window=renderer.window
local wait=vk.device_wait_idle
wait(renderer.device)
vk.device_wait_idle=function() error('INJECTED_DEVICE_LOST_ON_SHUTDOWN') end
renderer:close()
vk.device_wait_idle=wait
check(renderer.closed and renderer.device==nil and renderer.window==nil,'Device wait failure blocked cleanup')
check(not pcall(window.size,window),'SDL window survived renderer cleanup')
renderer:close()
print('VULKAN_FAILURE_CHECKS_OK '..checks)
