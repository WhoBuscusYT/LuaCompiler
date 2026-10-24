/* Minimal Win32 operations. Application policy and callbacks live in Lua. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <windowsx.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "ui.h"

#define LC_HANDLE "LuaCompiler.UI.Handle"
#define LC_CONTEXT "LuaCompiler.UI.Context"
#define LC_QUEUE 1024u

typedef struct LCEvent {
    const char *type;
    unsigned int target;
    int x, y, code;
} LCEvent;
typedef struct LCContext LCContext;
typedef struct LCHandle {
    HWND hwnd;
    WNDPROC previous;
    LCContext *context;
    struct LCHandle *next;
    unsigned int id;
    int top;
    wchar_t surrogate;
} LCHandle;
struct LCContext {
    LCHandle *handles;
    LCEvent events[LC_QUEUE];
    unsigned int begin, count, next_id;
    int overflow;
};
static const wchar_t class_name[] = L"LuaCompiler.NativeUI.1";
static const char context_key = 0;

static void enqueue(LCHandle *handle, const char *type, int x, int y, int code)
{
    LCContext *context = handle->context;
    LCEvent *event;
    if (context == NULL) return;
    if (context->count == LC_QUEUE) {
        context->overflow = 1;
        return;
    }
    event = &context->events[(context->begin + context->count) % LC_QUEUE];
    event->type = type; event->target = handle->id;
    event->x = x; event->y = y; event->code = code;
    ++context->count;
}

static void input_event(LCHandle *handle, UINT message, WPARAM word, LPARAM parameter)
{
    switch (message) {
    case WM_KEYDOWN: case WM_SYSKEYDOWN:
        enqueue(handle, "key_down", 0, 0, (int)word); break;
    case WM_KEYUP: case WM_SYSKEYUP:
        enqueue(handle, "key_up", 0, 0, (int)word); break;
    case WM_CHAR:
        if (word >= 0xd800 && word <= 0xdbff) handle->surrogate = (wchar_t)word;
        else {
            int code = (int)word;
            if (word >= 0xdc00 && word <= 0xdfff && handle->surrogate != 0)
                code = 0x10000 + (((int)handle->surrogate - 0xd800) << 10) + ((int)word - 0xdc00);
            handle->surrogate = 0;
            if (code < 0xd800 || code > 0xdfff) enqueue(handle, "text", 0, 0, code);
        }
        break;
    case WM_MOUSEMOVE:
        enqueue(handle, "mouse_move", GET_X_LPARAM(parameter), GET_Y_LPARAM(parameter), 0); break;
    case WM_LBUTTONDOWN: case WM_RBUTTONDOWN: case WM_MBUTTONDOWN:
        enqueue(handle, "mouse_down", GET_X_LPARAM(parameter), GET_Y_LPARAM(parameter),
            message == WM_LBUTTONDOWN ? 1 : message == WM_RBUTTONDOWN ? 2 : 3); break;
    case WM_LBUTTONUP: case WM_RBUTTONUP: case WM_MBUTTONUP:
        enqueue(handle, "mouse_up", GET_X_LPARAM(parameter), GET_Y_LPARAM(parameter),
            message == WM_LBUTTONUP ? 1 : message == WM_RBUTTONUP ? 2 : 3); break;
    case WM_MOUSEWHEEL:
        {
            POINT point;
            point.x = GET_X_LPARAM(parameter); point.y = GET_Y_LPARAM(parameter);
            ScreenToClient(handle->hwnd, &point);
            enqueue(handle, "mouse_wheel", point.x, point.y, GET_WHEEL_DELTA_WPARAM(word));
        }
        break;
    }
}

static LRESULT CALLBACK control_proc(HWND hwnd, UINT message, WPARAM word, LPARAM parameter)
{
    LCHandle *handle = (LCHandle *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    WNDPROC previous;
    LRESULT result;
    if (handle == NULL || handle->previous == NULL) return DefWindowProcW(hwnd, message, word, parameter);
    previous = handle->previous;
    input_event(handle, message, word, parameter);
    result = CallWindowProcW(previous, hwnd, message, word, parameter);
    if (message == WM_NCDESTROY) {
        handle->hwnd = NULL;
        handle->previous = NULL;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
    }
    return result;
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT message, WPARAM word, LPARAM parameter)
{
    LCHandle *handle = (LCHandle *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        CREATESTRUCTW *create = (CREATESTRUCTW *)parameter;
        handle = (LCHandle *)create->lpCreateParams;
        handle->hwnd = hwnd;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)handle);
    }
    if (handle == NULL) return DefWindowProcW(hwnd, message, word, parameter);
    input_event(handle, message, word, parameter);
    switch (message) {
    case WM_CLOSE:
        enqueue(handle, "close", 0, 0, 0); return 0;
    case WM_SIZE:
        enqueue(handle, "resize", LOWORD(parameter), HIWORD(parameter), (int)word); break;
    case WM_COMMAND:
        if (parameter != 0) {
            LCHandle *control;
            for (control = handle->context->handles; control != NULL; control = control->next)
                if (control->hwnd == (HWND)parameter && !control->top) break;
            if (control != NULL) {
                int code = HIWORD(word);
                if (code == BN_CLICKED) enqueue(control, "click", 0, 0, code);
                else if (code == EN_CHANGE) enqueue(control, "change", 0, 0, code);
                else if (code == CBN_SELCHANGE) enqueue(control, "change", 0, 0, code);
            }
        } else enqueue(handle, "menu", 0, 0, LOWORD(word));
        return 0;
    case WM_DESTROY:
        enqueue(handle, "closed", 0, 0, 0); break;
    case WM_NCDESTROY:
        handle->hwnd = NULL;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0); break;
    }
    return DefWindowProcW(hwnd, message, word, parameter);
}

static LCContext *context(lua_State *state)
{
    LCContext *result;
    lua_rawgetp(state, LUA_REGISTRYINDEX, &context_key);
    result = (LCContext *)luaL_checkudata(state, -1, LC_CONTEXT);
    lua_pop(state, 1);
    return result;
}

static LCHandle *handle(lua_State *state, int index)
{
    LCHandle *result = (LCHandle *)luaL_checkudata(state, index, LC_HANDLE);
    luaL_argcheck(state, result->hwnd != NULL && IsWindow(result->hwnd), index, "UI object is closed");
    return result;
}

static wchar_t *wide_string(lua_State *state, int index)
{
    size_t size;
    const char *text = luaL_checklstring(state, index, &size);
    int length;
    wchar_t *result;
    luaL_argcheck(state, size < 1048576u && memchr(text, 0, size) == NULL, index, "Invalid UI text");
    length = size == 0 ? 0 : MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)size, NULL, 0);
    luaL_argcheck(state, size == 0 || length > 0, index, "UI text must be UTF-8");
    result = (wchar_t *)calloc((size_t)length + 1, sizeof(wchar_t));
    if (result == NULL) luaL_error(state, "Out of memory");
    if (length > 0) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, (int)size, result, length);
    return result;
}

static wchar_t *wide_field(lua_State *state, int table, const char *name, const char *fallback)
{
    wchar_t *result;
    lua_getfield(state, table, name);
    if (lua_isnil(state, -1)) { lua_pop(state, 1); lua_pushstring(state, fallback); }
    result = wide_string(state, -1);
    lua_pop(state, 1);
    return result;
}

static int integer_field(lua_State *state, int table, const char *name, int fallback)
{
    lua_Integer value;
    lua_getfield(state, table, name);
    value = lua_isnil(state, -1) ? fallback : luaL_checkinteger(state, -1);
    luaL_argcheck(state, value >= -1000000 && value <= 1000000, table, "UI coordinate out of range");
    lua_pop(state, 1);
    return (int)value;
}

static int boolean_field(lua_State *state, int table, const char *name, int fallback)
{
    int value;
    lua_getfield(state, table, name);
    value = lua_isnil(state, -1) ? fallback : lua_toboolean(state, -1);
    lua_pop(state, 1);
    return value;
}

static LCHandle *new_handle(lua_State *state, LCContext *owner, int top)
{
    LCHandle *result;
    luaL_argcheck(state, owner->next_id < 65535u, 1, "UI object limit reached");
    result = (LCHandle *)lua_newuserdatauv(state, sizeof(*result), 1);
    memset(result, 0, sizeof(*result));
    result->context = owner; result->top = top; result->id = ++owner->next_id;
    result->next = owner->handles; owner->handles = result;
    luaL_setmetatable(state, LC_HANDLE);
    lua_rawgetp(state, LUA_REGISTRYINDEX, &context_key);
    lua_setiuservalue(state, -2, 1);
    return result;
}

static int close_handle(lua_State *state)
{
    LCHandle *object = (LCHandle *)luaL_checkudata(state, 1, LC_HANDLE);
    if (object->hwnd != NULL && !DestroyWindow(object->hwnd)) return luaL_error(state, "Cannot destroy UI object");
    return 0;
}

static int release_handle(lua_State *state)
{
    LCHandle *object = (LCHandle *)luaL_checkudata(state, 1, LC_HANDLE);
    LCHandle **link;
    if (object->hwnd != NULL) DestroyWindow(object->hwnd);
    if (object->context != NULL) {
        for (link = &object->context->handles; *link != NULL; link = &(*link)->next) {
            if (*link == object) { *link = object->next; break; }
        }
    }
    object->context = NULL;
    return 0;
}

static int shutdown(lua_State *state)
{
    LCContext *owner = context(state);
    LCHandle *object;
    for (object = owner->handles; object != NULL; object = object->next)
        if (object->hwnd != NULL && object->top) DestroyWindow(object->hwnd);
    return 0;
}

static int release_context(lua_State *state)
{
    LCContext *owner = (LCContext *)luaL_checkudata(state, 1, LC_CONTEXT);
    LCHandle *object;
    for (object = owner->handles; object != NULL; object = object->next)
        if (object->hwnd != NULL) DestroyWindow(object->hwnd);
    return 0;
}

static int create_window(lua_State *state)
{
    LCContext *owner = context(state);
    LCHandle *object;
    WNDCLASSEXW definition;
    DWORD style;
    RECT rectangle;
    wchar_t *title;
    int width, height, x, y, visible;
    luaL_checktype(state, 1, LUA_TTABLE);
    width = integer_field(state, 1, "width", 640); height = integer_field(state, 1, "height", 480);
    luaL_argcheck(state, width > 0 && height > 0 && width <= 32768 && height <= 32768, 1, "Invalid window dimensions");
    x = integer_field(state, 1, "x", -1000000); y = integer_field(state, 1, "y", -1000000);
    visible = boolean_field(state, 1, "visible", 1);
    style = boolean_field(state, 1, "resizable", 1) ? WS_OVERLAPPEDWINDOW
        : WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
    memset(&definition, 0, sizeof(definition));
    definition.cbSize = sizeof(definition); definition.lpfnWndProc = window_proc;
    definition.hInstance = GetModuleHandleW(NULL); definition.hCursor = LoadCursorW(NULL, MAKEINTRESOURCEW(32512));
    definition.hbrBackground = (HBRUSH)(COLOR_BTNFACE + 1); definition.lpszClassName = class_name;
    if (!RegisterClassExW(&definition) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
        return luaL_error(state, "Cannot register Win32 window class");
    rectangle.left = 0; rectangle.top = 0; rectangle.right = width; rectangle.bottom = height;
    if (!AdjustWindowRectEx(&rectangle, style, FALSE, WS_EX_CONTROLPARENT))
        return luaL_error(state, "Cannot calculate Win32 window dimensions");
    object = new_handle(state, owner, 1);
    title = wide_field(state, 1, "title", "LuaCompiler");
    object->hwnd = CreateWindowExW(WS_EX_CONTROLPARENT, class_name, title, style,
        x == -1000000 ? CW_USEDEFAULT : x, y == -1000000 ? CW_USEDEFAULT : y,
        rectangle.right - rectangle.left, rectangle.bottom - rectangle.top,
        NULL, NULL, definition.hInstance, object);
    free(title);
    if (object->hwnd == NULL) return luaL_error(state, "Cannot create Win32 window");
    ShowWindow(object->hwnd, visible ? SW_SHOW : SW_HIDE);
    if (visible) UpdateWindow(object->hwnd);
    return 1;
}

static int create_control(lua_State *state)
{
    LCHandle *parent = handle(state, 1), *object;
    const char *kind = luaL_checkstring(state, 2);
    const wchar_t *class_type;
    DWORD style = WS_CHILD | WS_VISIBLE;
    wchar_t *text;
    int x, y, width, height;
    luaL_checktype(state, 3, LUA_TTABLE);
    luaL_argcheck(state, parent->top, 1, "Controls require a top-level parent window");
    if (strcmp(kind, "button") == 0) { class_type = L"BUTTON"; style |= WS_TABSTOP | BS_PUSHBUTTON; }
    else if (strcmp(kind, "label") == 0) { class_type = L"STATIC"; style |= SS_LEFT | SS_NOTIFY; }
    else if (strcmp(kind, "input") == 0) {
        class_type = L"EDIT"; style |= WS_TABSTOP | WS_BORDER | ES_AUTOHSCROLL;
        if (boolean_field(state, 3, "multiline", 0)) style = (style & ~ES_AUTOHSCROLL) | ES_MULTILINE | ES_AUTOVSCROLL | WS_VSCROLL;
        if (boolean_field(state, 3, "password", 0)) style |= ES_PASSWORD;
    } else if (strcmp(kind, "checkbox") == 0) { class_type = L"BUTTON"; style |= WS_TABSTOP | BS_AUTOCHECKBOX; }
    else if (strcmp(kind, "dropdown") == 0) { class_type = L"COMBOBOX"; style |= WS_TABSTOP | CBS_DROPDOWNLIST | WS_VSCROLL; }
    else return luaL_argerror(state, 2, "Unknown control type");
    x = integer_field(state, 3, "x", 0); y = integer_field(state, 3, "y", 0);
    width = integer_field(state, 3, "width", 120); height = integer_field(state, 3, "height", strcmp(kind, "dropdown") == 0 ? 160 : 28);
    luaL_argcheck(state, width > 0 && height > 0, 3, "Invalid control dimensions");
    object = new_handle(state, parent->context, 0);
    text = wide_field(state, 3, "text", "");
    object->hwnd = CreateWindowExW(0, class_type, text, style, x, y, width, height,
        parent->hwnd, (HMENU)(UINT_PTR)object->id, GetModuleHandleW(NULL), NULL);
    free(text);
    if (object->hwnd == NULL) return luaL_error(state, "Cannot create Win32 control");
    SetWindowLongPtrW(object->hwnd, GWLP_USERDATA, (LONG_PTR)object);
    object->previous = (WNDPROC)SetWindowLongPtrW(object->hwnd, GWLP_WNDPROC, (LONG_PTR)control_proc);
    if (object->previous == NULL) {
        DestroyWindow(object->hwnd); object->hwnd = NULL;
        return luaL_error(state, "Cannot install native control event handler");
    }
    SendMessageW(object->hwnd, WM_SETFONT, (WPARAM)GetStockObject(DEFAULT_GUI_FONT), TRUE);
    return 1;
}

static int object_id(lua_State *state)
{
    LCHandle *object = (LCHandle *)luaL_checkudata(state, 1, LC_HANDLE);
    lua_pushinteger(state, object->id); return 1;
}
static int object_closed(lua_State *state)
{
    LCHandle *object = (LCHandle *)luaL_checkudata(state, 1, LC_HANDLE);
    lua_pushboolean(state, object->hwnd == NULL || !IsWindow(object->hwnd)); return 1;
}
static int object_show(lua_State *state)
{
    LCHandle *object = handle(state, 1);
    ShowWindow(object->hwnd, lua_toboolean(state, 2) ? SW_SHOW : SW_HIDE); return 0;
}
static int object_enable(lua_State *state)
{
    EnableWindow(handle(state, 1)->hwnd, lua_toboolean(state, 2)); return 0;
}
static int object_text(lua_State *state)
{
    LCHandle *object = handle(state, 1);
    wchar_t *text;
    int length, bytes;
    char *result;
    if (!lua_isnone(state, 2)) {
        text = wide_string(state, 2);
        if (!SetWindowTextW(object->hwnd, text)) { free(text); return luaL_error(state, "Cannot set UI text"); }
        free(text); return 0;
    }
    length = GetWindowTextLengthW(object->hwnd);
    text = (wchar_t *)calloc((size_t)length + 1, sizeof(wchar_t));
    if (text == NULL) return luaL_error(state, "Out of memory");
    GetWindowTextW(object->hwnd, text, length + 1);
    bytes = WideCharToMultiByte(CP_UTF8, 0, text, length, NULL, 0, NULL, NULL);
    result = (char *)malloc((size_t)bytes + 1);
    if (result == NULL) { free(text); return luaL_error(state, "Out of memory"); }
    if (bytes > 0) WideCharToMultiByte(CP_UTF8, 0, text, length, result, bytes, NULL, NULL);
    free(text);
    lua_pushlstring(state, result, (size_t)bytes); free(result); return 1;
}
static int object_checked(lua_State *state)
{
    HWND hwnd = handle(state, 1)->hwnd;
    if (!lua_isnone(state, 2)) { SendMessageW(hwnd, BM_SETCHECK, lua_toboolean(state, 2) ? BST_CHECKED : BST_UNCHECKED, 0); return 0; }
    lua_pushboolean(state, SendMessageW(hwnd, BM_GETCHECK, 0, 0) == BST_CHECKED); return 1;
}
static int object_selection(lua_State *state)
{
    HWND hwnd = handle(state, 1)->hwnd;
    if (!lua_isnone(state, 2)) {
        lua_Integer selected = luaL_checkinteger(state, 2);
        luaL_argcheck(state, selected >= 0 && selected <= 65535, 2, "Invalid dropdown selection");
        if (SendMessageW(hwnd, CB_SETCURSEL, (WPARAM)(selected - 1), 0) == CB_ERR && selected != 0)
            return luaL_error(state, "Dropdown selection does not exist");
        return 0;
    }
    lua_pushinteger(state, (lua_Integer)SendMessageW(hwnd, CB_GETCURSEL, 0, 0) + 1); return 1;
}
static int object_add_item(lua_State *state)
{
    HWND hwnd = handle(state, 1)->hwnd;
    wchar_t *text = wide_string(state, 2);
    LRESULT index = SendMessageW(hwnd, CB_ADDSTRING, 0, (LPARAM)text);
    free(text);
    if (index == CB_ERR || index == CB_ERRSPACE) return luaL_error(state, "Cannot add dropdown item");
    lua_pushinteger(state, (lua_Integer)index + 1); return 1;
}
static int object_bounds(lua_State *state)
{
    LCHandle *object = handle(state, 1);
    int x, y, width, height;
    luaL_checktype(state, 2, LUA_TTABLE);
    x = integer_field(state, 2, "x", 0); y = integer_field(state, 2, "y", 0);
    width = integer_field(state, 2, "width", 120); height = integer_field(state, 2, "height", 28);
    luaL_argcheck(state, width > 0 && height > 0, 2, "Invalid dimensions");
    if (!SetWindowPos(object->hwnd, NULL, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE))
        return luaL_error(state, "Cannot position UI object");
    return 0;
}
static int object_focus(lua_State *state) { SetFocus(handle(state, 1)->hwnd); return 0; }
static int object_click(lua_State *state) { SendMessageW(handle(state, 1)->hwnd, BM_CLICK, 0, 0); return 0; }
static int object_request_close(lua_State *state)
{
    if (!PostMessageW(handle(state, 1)->hwnd, WM_CLOSE, 0, 0))
        return luaL_error(state, "Cannot request window close");
    return 0;
}

static HMENU menu_from_table(lua_State *state, int table, int popup, int depth)
{
    HMENU menu;
    lua_Integer i, count;
    if (depth > 8) return NULL;
    menu = popup ? CreatePopupMenu() : CreateMenu();
    if (menu == NULL) return NULL;
    table = lua_absindex(state, table); count = (lua_Integer)lua_rawlen(state, table);
    if (count > 1024) { DestroyMenu(menu); return NULL; }
    for (i = 1; i <= count; ++i) {
        HMENU child = NULL;
        wchar_t *label;
        UINT_PTR id;
        UINT flags = MF_STRING;
        lua_rawgeti(state, table, i);
        if (!lua_istable(state, -1)) { lua_pop(state, 1); DestroyMenu(menu); return NULL; }
        lua_getfield(state, -1, "items");
        if (lua_istable(state, -1)) {
            child = menu_from_table(state, -1, 1, depth + 1);
            if (child == NULL) { lua_pop(state, 2); DestroyMenu(menu); return NULL; }
            flags |= MF_POPUP; id = (UINT_PTR)child;
        } else {
            lua_getfield(state, -2, "id");
            if (!lua_isinteger(state, -1) || lua_tointeger(state, -1) < 1 || lua_tointeger(state, -1) > 65535) {
                lua_pop(state, 3); DestroyMenu(menu); return NULL;
            }
            id = (UINT_PTR)lua_tointeger(state, -1); lua_pop(state, 1);
        }
        lua_pop(state, 1);
        label = wide_field(state, -1, "label", "");
        if (!AppendMenuW(menu, flags, id, label)) {
            free(label); if (child != NULL) DestroyMenu(child);
            lua_pop(state, 1); DestroyMenu(menu); return NULL;
        }
        free(label); lua_pop(state, 1);
    }
    return menu;
}
static int object_menu(lua_State *state)
{
    LCHandle *object = handle(state, 1);
    HMENU menu, previous;
    luaL_checktype(state, 2, LUA_TTABLE);
    luaL_argcheck(state, object->top, 1, "Menu requires a window");
    luaL_checkstack(state, 32, "Menu nesting is too deep");
    menu = menu_from_table(state, 2, 0, 0);
    if (menu == NULL) return luaL_error(state, "Invalid menu or Win32 menu creation failure");
    previous = GetMenu(object->hwnd);
    if (!SetMenu(object->hwnd, menu)) { DestroyMenu(menu); return luaL_error(state, "Cannot attach menu"); }
    if (previous != NULL) DestroyMenu(previous);
    DrawMenuBar(object->hwnd); return 0;
}
static int dialog(lua_State *state)
{
    LCHandle *parent = lua_isnil(state, 1) ? NULL : handle(state, 1);
    wchar_t *title = wide_string(state, 2), *message = wide_string(state, 3);
    const char *kind = luaL_optstring(state, 4, "info");
    UINT flags = MB_OK | MB_ICONINFORMATION;
    int result;
    if (strcmp(kind, "warning") == 0) flags = MB_OK | MB_ICONWARNING;
    else if (strcmp(kind, "error") == 0) flags = MB_OK | MB_ICONERROR;
    else if (strcmp(kind, "question") == 0) flags = MB_YESNO | MB_ICONQUESTION;
    result = MessageBoxW(parent == NULL ? NULL : parent->hwnd, message, title, flags);
    free(title); free(message);
    if (result == 0) return luaL_error(state, "Cannot display native message dialog");
    lua_pushstring(state, result == IDYES ? "yes" : result == IDNO ? "no" : result == IDCANCEL ? "cancel" : "ok");
    return 1;
}

static int poll_event(lua_State *state)
{
    LCContext *owner = context(state);
    lua_Integer timeout = luaL_optinteger(state, 1, 0);
    MSG message;
    LCEvent event;
    luaL_argcheck(state, timeout >= 0 && timeout <= 60000, 1, "Invalid UI polling timeout");
    if (owner->count == 0 && timeout > 0)
        MsgWaitForMultipleObjectsEx(0, NULL, (DWORD)timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    while (PeekMessageW(&message, NULL, 0, 0, PM_REMOVE)) {
        LCHandle *object;
        int handled = 0;
        for (object = owner->handles; object != NULL; object = object->next) {
            if (object->top && object->hwnd != NULL && IsDialogMessageW(object->hwnd, &message)) { handled = 1; break; }
        }
        if (!handled) { TranslateMessage(&message); DispatchMessageW(&message); }
    }
    if (owner->overflow) { owner->overflow = 0; return luaL_error(state, "Native UI event queue overflow; poll more frequently"); }
    if (owner->count == 0) return 0;
    event = owner->events[owner->begin]; owner->begin = (owner->begin + 1) % LC_QUEUE; --owner->count;
    lua_createtable(state, 0, 5);
    lua_pushstring(state, event.type); lua_setfield(state, -2, "type");
    lua_pushinteger(state, event.target); lua_setfield(state, -2, "target");
    lua_pushinteger(state, event.x); lua_setfield(state, -2, "x");
    lua_pushinteger(state, event.y); lua_setfield(state, -2, "y");
    lua_pushinteger(state, event.code); lua_setfield(state, -2, "code");
    return 1;
}

int luaopen_lc_ui(lua_State *state)
{
    static const luaL_Reg methods[] = {
        {"id", object_id}, {"closed", object_closed}, {"close", close_handle},
        {"show", object_show}, {"enable", object_enable}, {"text", object_text},
        {"checked", object_checked}, {"selection", object_selection}, {"add_item", object_add_item},
        {"bounds", object_bounds}, {"focus", object_focus}, {"menu", object_menu},
        {"click", object_click}, {"request_close", object_request_close}, {NULL, NULL}
    };
    static const luaL_Reg functions[] = {
        {"window", create_window}, {"control", create_control}, {"poll", poll_event},
        {"dialog", dialog}, {"shutdown", shutdown}, {NULL, NULL}
    };
    if (luaL_newmetatable(state, LC_HANDLE)) {
        lua_pushcfunction(state, release_handle); lua_setfield(state, -2, "__gc");
        lua_newtable(state); luaL_setfuncs(state, methods, 0); lua_setfield(state, -2, "__index");
    }
    lua_pop(state, 1);
    if (luaL_newmetatable(state, LC_CONTEXT)) {
        lua_pushcfunction(state, release_context); lua_setfield(state, -2, "__gc");
    }
    lua_pop(state, 1);
    lua_rawgetp(state, LUA_REGISTRYINDEX, &context_key);
    if (lua_isnil(state, -1)) {
        LCContext *owner;
        lua_pop(state, 1); owner = (LCContext *)lua_newuserdatauv(state, sizeof(*owner), 0);
        memset(owner, 0, sizeof(*owner)); luaL_setmetatable(state, LC_CONTEXT);
        lua_rawsetp(state, LUA_REGISTRYINDEX, &context_key);
    } else lua_pop(state, 1);
    luaL_newlib(state, functions);
    lua_pushliteral(state, "win32"); lua_setfield(state, -2, "backend");
    return 1;
}
