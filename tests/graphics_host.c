/* Development-only host for running the Lua backend before launcher packaging. */
#include <stdio.h>
#define SDL_MAIN_HANDLED
#include <SDL3/SDL.h>
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
extern int luaopen_moonvulkan(lua_State *L);
extern int luaopen_lc_native_graphics(lua_State *L);
typedef struct TestWindow { SDL_Window *window; } TestWindow;
static int minimize_window(lua_State *L) {
    TestWindow *window=(TestWindow*)luaL_checkudata(L,1,"lc.graphics.window");
    if(!window->window || !SDL_MinimizeWindow(window->window)) return luaL_error(L,"Cannot minimize test window: %s",SDL_GetError());
    return 0;
}
static int restore_window(lua_State *L) {
    TestWindow *window=(TestWindow*)luaL_checkudata(L,1,"lc.graphics.window");
    if(!window->window || !SDL_RestoreWindow(window->window)) return luaL_error(L,"Cannot restore test window: %s",SDL_GetError());
    return 0;
}
int main(int argc,char **argv) {
    lua_State *L=luaL_newstate(); int i,status;
    if(!L || argc<2) return 2;
    luaL_openlibs(L);
    lua_newtable(L); lua_pushcfunction(L,minimize_window); lua_setfield(L,-2,"minimize");
    lua_pushcfunction(L,restore_window); lua_setfield(L,-2,"restore"); lua_setglobal(L,"graphics_test");
    luaL_getsubtable(L,LUA_REGISTRYINDEX,LUA_PRELOAD_TABLE);
    lua_pushcfunction(L,luaopen_moonvulkan); lua_setfield(L,-2,"moonvulkan");
    lua_pushcfunction(L,luaopen_lc_native_graphics); lua_setfield(L,-2,"lc_native_graphics"); lua_pop(L,1);
    lua_newtable(L); for(i=1;i<argc;i++) { lua_pushstring(L,argv[i]); lua_rawseti(L,-2,i-1); } lua_setglobal(L,"arg");
    status=luaL_dofile(L,argv[1]);
    if(status!=LUA_OK) fprintf(stderr,"%s\n",lua_tostring(L,-1));
    lua_close(L); return status==LUA_OK?0:1;
}
