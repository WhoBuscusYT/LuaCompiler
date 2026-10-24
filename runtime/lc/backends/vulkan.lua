-- Lua owns Vulkan setup, resources, command recording, synchronization and presentation.
-- The replaceable backend accepts batched clip-position/color/UV triangles.
local vk=require('moonvulkan')
local platform=require('lc_native_graphics')
local Backend={}
Backend.__index=Backend
local HOST=vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT|vk.MEMORY_PROPERTY_HOST_COHERENT_BIT
local DEVICE=vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT
local function shader(name)
    if lcb and lcb.read then return assert(lcb.read('lc/shaders/'..name)) end
    local directory=debug.getinfo(1,'S').source:match('^@(.+[\\/])') or './'
    local f=assert(io.open(directory..'../shaders/'..name,'rb'))
    local bytes=assert(f:read('a')); f:close(); return bytes
end
local function memory_type(self,requirements,flags)
    for i,t in ipairs(self.memoryTypes) do
        if requirements.memory_type_bits & (1<<(i-1)) ~= 0 and t.property_flags & flags == flags then return i-1 end
    end
    error('Vulkan device does not provide the required memory type')
end
local function release(fn,value,bestEffort)
    if value then if bestEffort then pcall(fn,value) else fn(value) end end
end
local function buffer(self,size,usage)
    local b=vk.create_buffer(self.device,{size=size,usage=usage,sharing_mode='exclusive'})
    local memory
    local ok,why=pcall(function()
        local requirements=vk.get_buffer_memory_requirements(b)
        memory=vk.allocate_memory(self.device,requirements.size,memory_type(self,requirements,HOST))
        vk.bind_buffer_memory(b,memory,0)
    end)
    if not ok then release(vk.destroy_buffer,b,true); release(vk.free_memory,memory,true); error(why,0) end
    return {buffer=b,memory=memory,size=size}
end
local function free_buffer(b,bestEffort)
    if b then release(vk.destroy_buffer,b.buffer,bestEffort); release(vk.free_memory,b.memory,bestEffort); b.buffer=nil; b.memory=nil end
end
local function image(self,width,height,format,usage)
    local img=vk.create_image(self.device,{image_type='2d',format=format,extent={width=width,height=height,depth=1},
        mip_levels=1,array_layers=1,samples=1,tiling='optimal',usage=usage,sharing_mode='exclusive',initial_layout='undefined'})
    local mem
    local ok,why=pcall(function()
        local requirements=vk.get_image_memory_requirements(img)
        mem=vk.allocate_memory(self.device,requirements.size,memory_type(self,requirements,DEVICE))
        vk.bind_image_memory(img,mem,0)
    end)
    if not ok then release(vk.destroy_image,img,true); release(vk.free_memory,mem,true); error(why,0) end
    return {image=img,memory=mem}
end
local function free_image(i,bestEffort)
    if i then release(vk.destroy_image_view,i.view,bestEffort); release(vk.destroy_image,i.image,bestEffort); release(vk.free_memory,i.memory,bestEffort) end
end
local function one_time(self,fn)
    local cb=vk.allocate_command_buffers(self.commandPool,'primary',1)[1]
    local ok,why=pcall(function()
        vk.begin_command_buffer(cb,vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)
        fn(cb)
        vk.end_command_buffer(cb)
        vk.queue_submit(self.queue,{{command_buffers={cb}}})
        vk.queue_wait_idle(self.queue)
    end)
    if not ok then pcall(vk.device_wait_idle,self.device) end
    vk.free_command_buffers({cb})
    assert(ok,why)
end
local function barrier(cb,img,old,new,source,destination,sourceStage,destinationStage)
    vk.cmd_pipeline_barrier(cb,sourceStage,destinationStage,0,nil,nil,{{
        old_layout=old,new_layout=new,src_access_mask=source,dst_access_mask=destination,
        image=img,
        subresource_range=vk.imagesubresourcerange({'color'},0,1,0,1)}})
end
function Backend:texture(width,height,rgba)
    assert(not self.closed,'Renderer is closed')
    assert(math.type(width)=='integer' and math.type(height)=='integer' and width>0 and height>0 and width<=8192 and height<=8192,'Invalid texture size')
    assert(type(rgba)=='string' and #rgba==width*height*4,'Texture requires exact RGBA8 bytes')
    assert(#self.textures<1024,'This backend supports up to 1024 textures')
    vk.device_wait_idle(self.device)
    local staging=buffer(self,#rgba,vk.BUFFER_USAGE_TRANSFER_SRC_BIT)
    local texture
    local ok,why=pcall(function()
        vk.map_memory(staging.memory,0,#rgba); vk.write_memory(staging.memory,0,rgba); vk.unmap_memory(staging.memory)
        texture=image(self,width,height,'r8g8b8a8 unorm',vk.IMAGE_USAGE_TRANSFER_DST_BIT|vk.IMAGE_USAGE_SAMPLED_BIT)
        self.textures[#self.textures+1]=texture
        texture.owner=self
        one_time(self,function(cb)
        barrier(cb,texture.image,'undefined','transfer dst optimal',0,vk.ACCESS_TRANSFER_WRITE_BIT,vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,vk.PIPELINE_STAGE_TRANSFER_BIT)
        vk.cmd_copy_buffer_to_image(cb,staging.buffer,texture.image,'transfer dst optimal',{{
            buffer_offset=0,buffer_row_length=0,buffer_image_height=0,
            image_subresource=vk.imagesubresourcelayers({'color'},0,0,1),image_offset={x=0,y=0,z=0},image_extent={width=width,height=height,depth=1}}})
        barrier(cb,texture.image,'transfer dst optimal','shader read only optimal',vk.ACCESS_TRANSFER_WRITE_BIT,vk.ACCESS_SHADER_READ_BIT,vk.PIPELINE_STAGE_TRANSFER_BIT,vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT)
        end)
    end)
    free_buffer(staging,true)
    assert(ok,why)
    texture.view=vk.create_image_view(texture.image,{view_type='2d',format='r8g8b8a8 unorm',components={},subresource_range=vk.imagesubresourcerange({'color'},0,1,0,1)})
    texture.sampler=vk.create_sampler(self.device,{mag_filter='linear',min_filter='linear',mipmap_mode='nearest',
        address_mode_u='repeat',address_mode_v='repeat',address_mode_w='repeat',max_lod=0})
    texture.descriptor=vk.allocate_descriptor_sets(self.descriptorPool,{self.descriptorLayout})[1]
    vk.update_descriptor_sets(self.device,{{dst_set=texture.descriptor,dst_binding=0,descriptor_type='combined image sampler',
        image_info={{sampler=texture.sampler,image_view=texture.view,image_layout='shader read only optimal'}}}},nil)
    return texture
end
local function cleanup_swapchain(self,bestEffort)
    if not self.swapchain then return end
    if not bestEffort then vk.device_wait_idle(self.device) end
    for _,fb in ipairs(self.framebuffers or {}) do release(vk.destroy_framebuffer,fb,bestEffort) end
    for _,p in ipairs(self.pipelines or {}) do release(vk.destroy_pipeline,p,bestEffort) end
    release(vk.destroy_render_pass,self.renderPass,bestEffort)
    for _,v in ipairs(self.views or {}) do release(vk.destroy_image_view,v,bestEffort) end
    for _,s in ipairs(self.finished or {}) do release(vk.destroy_semaphore,s,bestEffort) end
    free_image(self.depth,bestEffort)
    release(vk.destroy_swapchain,self.swapchain,bestEffort)
    self.swapchain=nil; self.framebuffers={}; self.pipelines={}; self.views={}; self.finished={}; self.depth=nil; self.renderPass=nil
end
local function pipeline(self,depth,depthWrite)
    return vk.create_graphics_pipelines(self.device,nil,{{
        stages={{module=self.vertexShader,stage=vk.SHADER_STAGE_VERTEX_BIT,name='main'},{module=self.fragmentShader,stage=vk.SHADER_STAGE_FRAGMENT_BIT,name='main'}},
        vertex_input_state={vertex_binding_descriptions={{binding=0,stride=40,input_rate='vertex'}},vertex_attribute_descriptions={
            {location=0,binding=0,format='r32g32b32a32 sfloat',offset=0},
            {location=1,binding=0,format='r32g32b32a32 sfloat',offset=16},{location=2,binding=0,format='r32g32 sfloat',offset=32}}},
        input_assembly_state={topology='triangle list'},
        viewport_state={viewports={vk.viewport(0,0,self.width,self.height,0,1)},scissors={vk.rect2d(0,0,self.width,self.height)}},
        rasterization_state={polygon_mode='fill',cull_mode=0,front_face='counter clockwise',line_width=1},
        multisample_state={rasterization_samples=1},
        depth_stencil_state={depth_test_enable=depth,depth_write_enable=depth and depthWrite~=false,depth_compare_op='less or equal'},
        color_blend_state={attachments={{blend_enable=true,src_color_blend_factor='src alpha',dst_color_blend_factor='one minus src alpha',
            color_blend_op='add',src_alpha_blend_factor='one',dst_alpha_blend_factor='one minus src alpha',alpha_blend_op='add',color_write_mask=vk.colorcomponentflags('r','g','b','a')}}},
        layout=self.pipelineLayout,render_pass=self.renderPass,subpass=0}})[1]
end
function Backend:_recreate()
    local width,height=self.window:size()
    if width==0 or height==0 then self.minimized=true; return false end
    self.minimized=false
    cleanup_swapchain(self)
    local caps=vk.get_physical_device_surface_capabilities(self.gpu,self.surface)
    local formats=vk.get_physical_device_surface_formats(self.gpu,self.surface)
    local format=formats[1]
    assert(format,'Vulkan surface has no supported formats')
    for _,candidate in ipairs(formats) do if candidate.format=='b8g8r8a8 unorm' then format=candidate; break end end
    if format.format=='undefined' then format={format='b8g8r8a8 unorm',color_space='srgb nonlinear'} end
    local extent=caps.current_extent
    if not extent or extent.width==0xffffffff then
        extent={width=math.max(caps.min_image_extent.width,math.min(caps.max_image_extent.width,width)),
            height=math.max(caps.min_image_extent.height,math.min(caps.max_image_extent.height,height))}
    end
    self.width,self.height=extent.width,extent.height
    local count=caps.min_image_count+1
    if caps.max_image_count>0 then count=math.min(count,caps.max_image_count) end
    local usage=vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT
    self.canCapture=caps.supported_usage_flags & vk.IMAGE_USAGE_TRANSFER_SRC_BIT ~= 0
    if self.canCapture then usage=usage|vk.IMAGE_USAGE_TRANSFER_SRC_BIT end
    local alpha=vk.COMPOSITE_ALPHA_OPAQUE_BIT
    if caps.supported_composite_alpha & alpha == 0 then
        for i=0,3 do if caps.supported_composite_alpha & (1<<i) ~=0 then alpha=1<<i; break end end
    end
    self.swapchain=vk.create_swapchain(self.device,{surface=self.surface,min_image_count=count,image_format=format.format,
        image_color_space=format.color_space,image_extent=extent,image_array_layers=1,image_usage=usage,image_sharing_mode='exclusive',
        pre_transform=caps.current_transform,composite_alpha=alpha,present_mode='fifo',clipped=true})
    self.format=format.format
    self.images=vk.get_swapchain_images(self.swapchain)
    self.views={}; self.finished={}; self.framebuffers={}; self.pipelines={}
    for i,img in ipairs(self.images) do
        self.views[i]=vk.create_image_view(img,{view_type='2d',format=format.format,components={},subresource_range=vk.imagesubresourcerange({'color'},0,1,0,1)})
        self.finished[i]=vk.create_semaphore(self.device)
    end
    self.depth=image(self,self.width,self.height,self.depthFormat,vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT)
    self.depth.view=vk.create_image_view(self.depth.image,{view_type='2d',format=self.depthFormat,components={},subresource_range=vk.imagesubresourcerange({'depth'},0,1,0,1)})
    self.renderPass=vk.create_render_pass(self.device,{
        attachments={{format=format.format,samples=1,load_op='clear',store_op='store',initial_layout='undefined',final_layout='present src'},
            {format=self.depthFormat,samples=1,load_op='clear',store_op='dont care',initial_layout='undefined',final_layout='depth stencil attachment optimal'}},
        subpasses={{pipeline_bind_point='graphics',color_attachments={{attachment=0,layout='color attachment optimal'}},depth_stencil_attachment={attachment=1,layout='depth stencil attachment optimal'}}},
        dependencies={{src_subpass='external',dst_subpass=0,
            src_stage_mask=vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT|vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT|vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
            dst_stage_mask=vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT|vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
            dst_access_mask=vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT|vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT}}})
    self.pipelines[1]=pipeline(self,false); self.pipelines[2]=pipeline(self,true); self.pipelines[3]=pipeline(self,true,false)
    for i,view in ipairs(self.views) do
        self.framebuffers[i]=vk.create_framebuffer(self.device,{render_pass=self.renderPass,attachments={view,self.depth.view},width=self.width,height=self.height,layers=1})
    end
    self.dirty=false
    return true
end
function Backend:poll()
    assert(not self.closed,'Renderer is closed')
    local events=self.window:poll()
    for _,e in ipairs(events) do if e.type=='resize' then self.dirty=true end end
    return events
end
function Backend:size() return self.window:size() end
function Backend:resize(width,height) self.window:resize(width,height); self.dirty=true end
function Backend:time() return platform.time() end
function Backend:sleep(ms) platform.sleep(ms) end
function Backend:capture(path)
    assert(type(path)=='string' and #path>0,'Screenshot requires a path')
    self.capturePath=path -- GPU readback on the next rendered frame.
end
local function save_capture(self,readback,path)
    local size=self.width*self.height*4
    vk.map_memory(readback.memory,0,size)
    local bytes=vk.read_memory(readback.memory,0,size)
    vk.unmap_memory(readback.memory)
    if self.format:sub(1,4)=='r8g8' then bytes=bytes:gsub('(.)(.)(.)(.)',function(r,g,b,a) return b..g..r..a end) end
    local header='BM'..string.pack('<I4I4I4I4i4i4I2I2I4I4i4i4I4I4',54+#bytes,0,54,40,self.width,-self.height,1,32,0,#bytes,0,0,0,0)
    local file=assert(io.open(path,'wb')); assert(file:write(header,bytes)); assert(file:close())
end
function Backend:render(commands,clear)
    assert(not self.closed,'Renderer is closed')
    if self.dirty or self.minimized then if not self:_recreate() then platform.sleep(10); return false end end
    local chunks,offsets,total={}, {},0
    for i,command in ipairs(commands) do
        local bytes=assert(command.vertices,'Draw command requires packed vertices')
        assert(type(bytes)=='string' and #bytes%120==0,'Triangle vertices must contain 10 float32 values per vertex')
        if command.texture then assert(command.texture.owner==self,'Texture belongs to another renderer') end
        offsets[i]=total; total=total+#bytes; chunks[i]=bytes
    end
    assert(total<=134217728,'Frame vertex batch exceeds 128 MiB')
    vk.device_wait_idle(self.device) -- First backend deliberately permits one frame in flight.
    if total>0 then
        if not self.vertices or self.vertices.size<total then
            local nextBuffer=buffer(self,math.max(65536,total),vk.BUFFER_USAGE_VERTEX_BUFFER_BIT)
            free_buffer(self.vertices); self.vertices=nextBuffer
        end
        vk.map_memory(self.vertices.memory,0,total); vk.write_memory(self.vertices.memory,0,table.concat(chunks)); vk.unmap_memory(self.vertices.memory)
    end
    local index,result=vk.acquire_next_image(self.swapchain,'blocking',self.available)
    if not index then
        if result=='out of date' then self.dirty=true; return false end
        error('Vulkan image acquisition: '..tostring(result))
    end
    local cb=self.commandBuffer
    vk.reset_command_buffer(cb,0); vk.begin_command_buffer(cb,vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)
    vk.cmd_begin_render_pass(cb,{render_pass=self.renderPass,framebuffer=self.framebuffers[index+1],render_area=vk.rect2d(0,0,self.width,self.height),
        clear_values={{color=clear or {0.05,0.06,0.09,1}},{depth=1,stencil=0}}},'inline')
    for i,command in ipairs(commands) do if #command.vertices>0 then
        local texture=command.texture or self.white
        vk.cmd_bind_pipeline(cb,'graphics',self.pipelines[command.depth and (command.depthWrite==false and 3 or 2) or 1])
        vk.cmd_bind_vertex_buffers(cb,0,{self.vertices.buffer},{offsets[i]})
        vk.cmd_bind_descriptor_sets(cb,'graphics',self.pipelineLayout,0,{texture.descriptor})
        vk.cmd_draw(cb,#command.vertices//40,1,0,0)
    end end
    vk.cmd_end_render_pass(cb)
    local readback,capturePath
    if self.capturePath then
        assert(self.canCapture,'Surface does not support Vulkan screenshot readback')
        assert(self.format:match('^[br]8g8[br]8a8'),'Screenshot requires an RGBA8 or BGRA8 swapchain')
        capturePath=self.capturePath; self.capturePath=nil
        readback=buffer(self,self.width*self.height*4,vk.BUFFER_USAGE_TRANSFER_DST_BIT)
        self.readback=readback
        barrier(cb,self.images[index+1],'present src','transfer src optimal',vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,vk.ACCESS_TRANSFER_READ_BIT,vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,vk.PIPELINE_STAGE_TRANSFER_BIT)
        vk.cmd_copy_image_to_buffer(cb,self.images[index+1],'transfer src optimal',readback.buffer,{{buffer_offset=0,buffer_row_length=0,buffer_image_height=0,
            image_subresource=vk.imagesubresourcelayers({'color'},0,0,1),image_offset={x=0,y=0,z=0},image_extent={width=self.width,height=self.height,depth=1}}})
        vk.cmd_pipeline_barrier(cb,vk.PIPELINE_STAGE_TRANSFER_BIT,vk.PIPELINE_STAGE_HOST_BIT,0,nil,{{
            src_access_mask=vk.ACCESS_TRANSFER_WRITE_BIT,dst_access_mask=vk.ACCESS_HOST_READ_BIT,buffer=readback.buffer,offset=0,size=self.width*self.height*4}},nil)
        barrier(cb,self.images[index+1],'transfer src optimal','present src',vk.ACCESS_TRANSFER_READ_BIT,0,vk.PIPELINE_STAGE_TRANSFER_BIT,vk.PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT)
    end
    vk.end_command_buffer(cb)
    vk.queue_submit(self.queue,{{command_buffers={cb},wait_semaphores={self.available},wait_dst_stage_mask={vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT},signal_semaphores={self.finished[index+1]}}})
    local status=vk.queue_present(self.queue,{swapchains={self.swapchain},image_indices={index},wait_semaphores={self.finished[index+1]}})
    vk.queue_wait_idle(self.queue)
    if readback then
        local ok,why=pcall(save_capture,self,readback,capturePath)
        free_buffer(readback,true); self.readback=nil; assert(ok,why)
    end
    if status=='out of date' or status=='suboptimal' or result=='suboptimal' then self.dirty=true
    elseif status~='success' then error('Vulkan presentation: '..tostring(status)) end
    self.frames=self.frames+1
    return true
end
function Backend:close()
    if self.closed then return end
    self.closed=true
    if self.device then
        pcall(vk.device_wait_idle,self.device)
        cleanup_swapchain(self,true)
        free_buffer(self.vertices,true); self.vertices=nil
        free_buffer(self.readback,true); self.readback=nil
        for _,texture in ipairs(self.textures) do release(vk.destroy_sampler,texture.sampler,true); free_image(texture,true) end
        release(vk.destroy_descriptor_pool,self.descriptorPool,true)
        release(vk.destroy_pipeline_layout,self.pipelineLayout,true)
        release(vk.destroy_descriptor_set_layout,self.descriptorLayout,true)
        release(vk.destroy_shader_module,self.vertexShader,true)
        release(vk.destroy_shader_module,self.fragmentShader,true)
        release(vk.destroy_semaphore,self.available,true)
        release(vk.destroy_command_pool,self.commandPool,true)
        release(vk.destroy_device,self.device,true); self.device=nil
    end
    if self.surface then release(vk.destroy_surface,self.surface,true); self.surface=nil end
    if self.debugMessenger then release(vk.destroy_debug_utils_messenger,self.debugMessenger,true); self.debugMessenger=nil end
    if self.instance then release(vk.destroy_instance,self.instance,true); self.instance=nil end
    if self.window then pcall(self.window.close,self.window); self.window=nil end
end
function Backend.new(config)
    config=config or {}
    local self=setmetatable({textures={},frames=0,validationMessages={},validationErrors=0},Backend)
    local ok,why=xpcall(function()
        local layers={}
        if config.validation then
            assert(vk.enumerate_instance_layer_properties(true).VK_LAYER_KHRONOS_validation,
                'Vulkan validation requested but VK_LAYER_KHRONOS_validation is not installed')
            layers[1]='VK_LAYER_KHRONOS_validation'
        end
        self.window=platform.create(config)
        local extensions=platform.extensions()
        if config.validation then
            assert(vk.enumerate_instance_extension_properties(nil,true).VK_EXT_debug_utils,'Vulkan validation requires VK_EXT_debug_utils')
            extensions[#extensions+1]='VK_EXT_debug_utils'
        end
        self.instance=vk.create_instance({application_info={application_name=config.title or 'LuaCompiler',engine_name='LuaCompiler Lua Vulkan',api_version=vk.make_version(1,0,0)},enabled_extension_names=extensions,enabled_layer_names=layers})
        if config.validation then
            self.debugMessenger=vk.create_debug_utils_messenger(self.instance,{
                message_severity=vk.debugutilsmessageseverityflags('warning','error'),
                message_type=vk.debugutilsmessagetypeflags('general','validation','performance')},function(_,severity,kind,data)
                self.validationMessages[#self.validationMessages+1]={severity=severity,type=kind,message=data.message}
                if severity & vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT ~=0 then self.validationErrors=self.validationErrors+1 end
            end)
        end
        local hinstance,hwnd=self.window:handles()
        self.surface=vk.create_win32_surface(self.instance,0,hinstance,hwnd)
        for _,gpu in ipairs(vk.enumerate_physical_devices(self.instance)) do
            for index,family in ipairs(vk.get_physical_device_queue_family_properties(gpu)) do
                if family.queue_flags & vk.QUEUE_GRAPHICS_BIT ~=0 and vk.get_physical_device_surface_support(gpu,index-1,self.surface) then
                    self.gpu,self.family=gpu,index-1; break
                end
            end
            if self.gpu then break end
        end
        assert(self.gpu,'No Vulkan device with graphics and presentation support')
        self.deviceName=vk.get_physical_device_properties(self.gpu).device_name
        self.memoryTypes=vk.get_physical_device_memory_properties(self.gpu).memory_types
        self.device=vk.create_device(self.gpu,{queue_create_infos={{queue_family_index=self.family,queue_priorities={1}}},enabled_extension_names={'VK_KHR_swapchain'}})
        self.queue=vk.get_device_queue(self.device,self.family,0)
        self.commandPool=vk.create_command_pool(self.device,vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,self.family)
        self.commandBuffer=vk.allocate_command_buffers(self.commandPool,'primary',1)[1]
        self.available=vk.create_semaphore(self.device)
        self.descriptorLayout=vk.create_descriptor_set_layout(self.device,0,{{binding=0,descriptor_type='combined image sampler',descriptor_count=1,stage_flags=vk.SHADER_STAGE_FRAGMENT_BIT}})
        self.descriptorPool=vk.create_descriptor_pool(self.device,0,1024,{{type='combined image sampler',descriptor_count=1024}})
        self.pipelineLayout=vk.create_pipeline_layout(self.device,0,{self.descriptorLayout},nil)
        self.vertexShader=vk.create_shader_module(self.device,0,config.vertexShader or shader('default.vert.spv'))
        self.fragmentShader=vk.create_shader_module(self.device,0,config.fragmentShader or shader('default.frag.spv'))
        for _,format in ipairs({'d32 sfloat','d24 unorm s8 uint','d16 unorm'}) do
            if vk.get_physical_device_format_properties(self.gpu,format).optimal_tiling_features & vk.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT ~=0 then self.depthFormat=format; break end
        end
        assert(self.depthFormat,'Vulkan device has no depth attachment format')
        self.white=self:texture(1,1,string.char(255,255,255,255))
        self:_recreate()
    end,debug.traceback)
    if not ok then pcall(self.close,self); error(why,0) end
    return self
end
return Backend
