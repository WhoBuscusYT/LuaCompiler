/* Minimal SDL3 platform binding. Vulkan orchestration and game logic live in Lua. */
#define SDL_MAIN_HANDLED
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
#include <lua.h>
#include <lauxlib.h>
#include <ctype.h>
#include <string.h>

typedef struct GraphicsWindow { SDL_Window *window; } GraphicsWindow;
static GraphicsWindow *check_window(lua_State *L) {
    GraphicsWindow *w=(GraphicsWindow*)luaL_checkudata(L,1,"lc.graphics.window");
    luaL_argcheck(L,w->window!=NULL,1,"window is closed"); return w;
}
static void field_string(lua_State *L,const char *key,const char *value) {
    lua_pushstring(L,value); lua_setfield(L,-2,key);
}
static void field_number(lua_State *L,const char *key,double value) {
    lua_pushnumber(L,value); lua_setfield(L,-2,key);
}
static int window_close(lua_State *L) {
    GraphicsWindow *w=(GraphicsWindow*)luaL_checkudata(L,1,"lc.graphics.window");
    if(w->window) { SDL_DestroyWindow(w->window); w->window=NULL; SDL_QuitSubSystem(SDL_INIT_VIDEO); }
    return 0;
}
static int window_size(lua_State *L) {
    int width,height;
    SDL_Window *window=check_window(L)->window;
    if(SDL_GetWindowFlags(window)&SDL_WINDOW_MINIMIZED) { lua_pushinteger(L,0); lua_pushinteger(L,0); return 2; }
    if(!SDL_GetWindowSizeInPixels(window,&width,&height)) return luaL_error(L,"%s",SDL_GetError());
    lua_pushinteger(L,width); lua_pushinteger(L,height); return 2;
}
static int window_resize(lua_State *L) {
    SDL_Window *w=check_window(L)->window;
    lua_Integer width=luaL_checkinteger(L,2),height=luaL_checkinteger(L,3);
    luaL_argcheck(L,width>0 && width<=16384,2,"invalid width");
    luaL_argcheck(L,height>0 && height<=16384,3,"invalid height");
    if(!SDL_SetWindowSize(w,(int)width,(int)height)) return luaL_error(L,"%s",SDL_GetError());
    return 0;
}
static int window_handles(lua_State *L) {
    SDL_PropertiesID p=SDL_GetWindowProperties(check_window(L)->window);
    lua_pushlightuserdata(L,SDL_GetPointerProperty(p,SDL_PROP_WINDOW_WIN32_INSTANCE_POINTER,NULL));
    lua_pushlightuserdata(L,SDL_GetPointerProperty(p,SDL_PROP_WINDOW_WIN32_HWND_POINTER,NULL)); return 2;
}
static int window_poll(lua_State *L) {
    SDL_Event e; int count=0; SDL_WindowID id=SDL_GetWindowID(check_window(L)->window);
    lua_newtable(L);
    while(SDL_PollEvent(&e)) {
        int include=1;
        lua_newtable(L);
        switch(e.type) {
        case SDL_EVENT_QUIT: field_string(L,"type","quit"); break;
        case SDL_EVENT_WINDOW_CLOSE_REQUESTED:
            include=e.window.windowID==id; field_string(L,"type","quit"); break;
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            include=e.window.windowID==id; field_string(L,"type","resize");
            field_number(L,"width",e.window.data1); field_number(L,"height",e.window.data2); break;
        case SDL_EVENT_WINDOW_MINIMIZED: case SDL_EVENT_WINDOW_RESTORED: {
            int width=0,height=0;
            include=e.window.windowID==id; field_string(L,"type","resize");
            if(e.type==SDL_EVENT_WINDOW_RESTORED) SDL_GetWindowSizeInPixels(check_window(L)->window,&width,&height);
            field_number(L,"width",width); field_number(L,"height",height); break;
        }
        case SDL_EVENT_WINDOW_FOCUS_LOST:
            include=e.window.windowID==id; field_string(L,"type","blur"); break;
        case SDL_EVENT_KEY_DOWN: case SDL_EVENT_KEY_UP: {
            char key[128]; const char *name=SDL_GetKeyName(e.key.key); size_t i;
            include=e.key.windowID==id; field_string(L,"type","key");
            for(i=0;name[i] && i<sizeof(key)-1;i++) key[i]=(char)tolower((unsigned char)name[i]);
            key[i]=0; field_string(L,"key",key);
            lua_pushboolean(L,e.type==SDL_EVENT_KEY_DOWN); lua_setfield(L,-2,"down");
            lua_pushboolean(L,e.key.repeat); lua_setfield(L,-2,"repeat"); break;
        }
        case SDL_EVENT_MOUSE_MOTION:
            include=e.motion.windowID==id; field_string(L,"type","mousemove");
            field_number(L,"x",e.motion.x); field_number(L,"y",e.motion.y);
            field_number(L,"dx",e.motion.xrel); field_number(L,"dy",e.motion.yrel); break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP:
            include=e.button.windowID==id; field_string(L,"type","mousebutton");
            field_number(L,"button",e.button.button); field_number(L,"x",e.button.x); field_number(L,"y",e.button.y);
            lua_pushboolean(L,e.type==SDL_EVENT_MOUSE_BUTTON_DOWN); lua_setfield(L,-2,"down"); break;
        case SDL_EVENT_MOUSE_WHEEL:
            include=e.wheel.windowID==id; field_string(L,"type","mousewheel");
            field_number(L,"x",e.wheel.x); field_number(L,"y",e.wheel.y); break;
        default: include=0;
        }
        if(include) lua_rawseti(L,-2,++count); else lua_pop(L,1);
    }
    return 1;
}
static int create_window(lua_State *L) {
    const char *title; lua_Integer width,height; int resizable; GraphicsWindow *w;
    wchar_t systemPath[MAX_PATH+32]; char driverPath[(MAX_PATH+32)*3]; UINT length;
    luaL_checktype(L,1,LUA_TTABLE);
    lua_getfield(L,1,"title"); title=luaL_optstring(L,-1,"LuaCompiler Vulkan");
    lua_getfield(L,1,"width"); width=luaL_optinteger(L,-1,960);
    lua_getfield(L,1,"height"); height=luaL_optinteger(L,-1,640);
    lua_getfield(L,1,"resizable"); resizable=lua_isnil(L,-1)||lua_toboolean(L,-1);
    luaL_argcheck(L,width>0 && height>0 && width<=16384 && height<=16384,1,"invalid window dimensions");
    /* Keep SDL's automatic Vulkan window loader on the same system driver as
       MoonVulkan, independent of environment hints or application-directory DLLs. */
    length=GetSystemDirectoryW(systemPath,MAX_PATH);
    if(!length || length>=MAX_PATH) return luaL_error(L,"Cannot locate the Windows graphics driver directory");
    wcscat_s(systemPath,MAX_PATH+32,L"\\vulkan-1.dll");
    if(!WideCharToMultiByte(CP_UTF8,0,systemPath,-1,driverPath,(int)sizeof(driverPath),NULL,NULL))
        return luaL_error(L,"Cannot encode the Vulkan driver path");
    SDL_SetHintWithPriority(SDL_HINT_VULKAN_LIBRARY,driverPath,SDL_HINT_OVERRIDE);
    if(!SDL_Init(SDL_INIT_VIDEO)) return luaL_error(L,"SDL3 initialization: %s",SDL_GetError());
    w=(GraphicsWindow*)lua_newuserdatauv(L,sizeof(*w),0); w->window=NULL;
    luaL_setmetatable(L,"lc.graphics.window");
    w->window=SDL_CreateWindow(title,(int)width,(int)height,SDL_WINDOW_VULKAN|(resizable?SDL_WINDOW_RESIZABLE:0));
    if(!w->window) { SDL_QuitSubSystem(SDL_INIT_VIDEO); return luaL_error(L,"SDL3 Vulkan window: %s",SDL_GetError()); }
    return 1;
}
static int extensions(lua_State *L) {
    Uint32 count=0,i; const char *const *names=SDL_Vulkan_GetInstanceExtensions(&count);
    if(!names) return luaL_error(L,"SDL3 Vulkan extensions: %s",SDL_GetError());
    lua_createtable(L,(int)count,0); for(i=0;i<count;i++) { lua_pushstring(L,names[i]); lua_rawseti(L,-2,(int)i+1); }
    return 1;
}
static int time_seconds(lua_State *L) { lua_pushnumber(L,(double)SDL_GetTicksNS()*1e-9); return 1; }
static int sleep_ms(lua_State *L) {
    lua_Integer n=luaL_checkinteger(L,1); luaL_argcheck(L,n>=0 && n<=60000,1,"invalid delay"); SDL_Delay((Uint32)n); return 0;
}
int luaopen_lc_native_graphics(lua_State *L) {
    static const luaL_Reg methods[]={{"close",window_close},{"size",window_size},{"resize",window_resize},
        {"handles",window_handles},{"poll",window_poll},{NULL,NULL}};
    static const luaL_Reg functions[]={{"create",create_window},{"extensions",extensions},{"time",time_seconds},{"sleep",sleep_ms},{NULL,NULL}};
    luaL_newmetatable(L,"lc.graphics.window"); luaL_setfuncs(L,methods,0);
    lua_pushvalue(L,-1); lua_setfield(L,-2,"__index"); lua_pushcfunction(L,window_close); lua_setfield(L,-2,"__gc"); lua_pop(L,1);
    luaL_newlib(L,functions); return 1;
}
