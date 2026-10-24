/* LuaCompiler console launcher. See README.md for the on-disk contract. */
#define WIN32_LEAN_AND_MEAN
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <limits.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "bootstrap.h"
#ifdef LC_DESKTOP
#include "ui.h"
extern int luaopen_lc_native_graphics(lua_State *state);
extern int luaopen_moonvulkan(lua_State *state);
#include "third_party_licenses.h"
#endif

#if LUA_VERSION_NUM != 504
#error LuaCompiler requires the standard Lua 5.4 runtime
#endif

#define FOOTER_SIZE 64u
#define MAX_BUNDLE_SIZE UINT64_C(1073741824)
#define MAX_FILES 100000u
#define MAX_PATH_BYTES 32768u

static int diagnostic_mode = 0;

static void report_error(const char *message)
{
    const unsigned char *base = (const unsigned char *)GetModuleHandleW(NULL);
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *)base;
    const IMAGE_NT_HEADERS64 *pe = (const IMAGE_NT_HEADERS64 *)(base + dos->e_lfanew);
    fprintf(stderr, "LuaCompiler: %s\n", message);
    if (!diagnostic_mode && pe->OptionalHeader.Subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI) {
        int size = MultiByteToWideChar(CP_UTF8, 0, message, -1, NULL, 0);
        wchar_t *wide = size > 0 ? (wchar_t *)malloc((size_t)size * sizeof(wchar_t)) : NULL;
        if (wide != NULL) {
            MultiByteToWideChar(CP_UTF8, 0, message, -1, wide, size);
            MessageBoxW(NULL, wide, L"LuaCompiler application error", MB_OK | MB_ICONERROR);
            free(wide);
        }
    }
}

static void install_native_modules(lua_State *state)
{
#ifdef LC_DESKTOP
    /* Preload loaders lazily: console apps and build validation never require
       graphics drivers or initialize a windowing system. */
    luaL_getsubtable(state, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
    lua_pushcfunction(state, luaopen_lc_ui);
    lua_setfield(state, -2, "lc_native_ui");
    lua_pushcfunction(state, luaopen_lc_native_graphics);
    lua_setfield(state, -2, "lc_native_graphics");
    lua_pushcfunction(state, luaopen_moonvulkan);
    lua_setfield(state, -2, "moonvulkan");
    lua_pop(state, 1);
#else
    (void)state;
#endif
}

static const char lua_license[] =
    "Copyright (C) 1994-2026 Lua.org, PUC-Rio.\n\n"
    "Permission is hereby granted, free of charge, to any person obtaining\n"
    "a copy of this software and associated documentation files (the\n"
    "\"Software\"), to deal in the Software without restriction, including\n"
    "without limitation the rights to use, copy, modify, merge, publish,\n"
    "distribute, sublicense, and/or sell copies of the Software, and to\n"
    "permit persons to whom the Software is furnished to do so, subject to\n"
    "the following conditions:\n\n"
    "The above copyright notice and this permission notice shall be\n"
    "included in all copies or substantial portions of the Software.\n\n"
    "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND,\n"
    "EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF\n"
    "MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.\n"
    "IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY\n"
    "CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,\n"
    "TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE\n"
    "SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\n";

typedef struct BundleFile {
    wchar_t *path;
    char *utf8_path;
    const unsigned char *data;
    size_t size;
} BundleFile;

typedef struct Runtime {
    HANDLE file;
    HANDLE mapping;
    const unsigned char *image;
    uint64_t image_size;
    BundleFile *files;
    BundleFile **sorted;
    uint32_t count;
    BundleFile *entry;
    char error[256];
} Runtime;

static int fail(Runtime *runtime, const char *message)
{
    (void)snprintf(runtime->error, sizeof(runtime->error), "%s", message);
    return 0;
}

/* Template probes parse trusted policy without executing it or opening libraries. */
static int check_bootstrap_syntax(Runtime *runtime)
{
    lua_State *state = luaL_newstate();
    int valid;
    if (state == NULL) return fail(runtime, "Cannot allocate Lua state to validate launcher bootstrap");
    valid = luaL_loadbufferx(state, (const char *)lc_bootstrap, sizeof(lc_bootstrap) - 1,
        "@luacompiler/bootstrap.lua", "t") == LUA_OK;
    if (!valid) {
        const char *message = lua_tostring(state, -1);
        (void)snprintf(runtime->error, sizeof(runtime->error), "Invalid trusted Lua bootstrap: %s",
            message != NULL ? message : "Unknown parser error");
    }
    lua_close(state);
    return valid;
}

static uint32_t read_u32(const unsigned char *bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8)
        | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint64_t read_u64(const unsigned char *bytes)
{
    return (uint64_t)read_u32(bytes) | ((uint64_t)read_u32(bytes + 4) << 32);
}

static void release_runtime(Runtime *runtime)
{
    uint32_t i;
    for (i = 0; runtime->files != NULL && i < runtime->count; ++i) {
        free(runtime->files[i].path);
        free(runtime->files[i].utf8_path);
    }
    free(runtime->files);
    free(runtime->sorted);
    if (runtime->image != NULL) UnmapViewOfFile(runtime->image);
    if (runtime->mapping != NULL) CloseHandle(runtime->mapping);
    if (runtime->file != NULL && runtime->file != INVALID_HANDLE_VALUE)
        CloseHandle(runtime->file);
}

/* Conversion is explicit: bundle paths use the footer code page, Lua uses UTF-8. */
static wchar_t *decode_path(const char *bytes, size_t length, UINT codepage)
{
    wchar_t *wide;
    int needed;
    if (length == 0 || length > MAX_PATH_BYTES || memchr(bytes, 0, length))
        return NULL;
    needed = MultiByteToWideChar(codepage, MB_ERR_INVALID_CHARS,
        bytes, (int)length, NULL, 0);
    if (needed <= 0) return NULL;
    wide = (wchar_t *)calloc((size_t)needed + 1, sizeof(wchar_t));
    if (wide == NULL) return NULL;
    if (MultiByteToWideChar(codepage, MB_ERR_INVALID_CHARS,
        bytes, (int)length, wide, needed) != needed) {
        free(wide);
        return NULL;
    }
    return wide;
}

static char *encode_utf8(const wchar_t *wide)
{
    int length = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        wide, -1, NULL, 0, NULL, NULL);
    char *result;
    if (length <= 0) return NULL;
    result = (char *)malloc((size_t)length);
    if (result == NULL) return NULL;
    if (!WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS,
        wide, -1, result, length, NULL, NULL)) {
        free(result);
        return NULL;
    }
    return result;
}

static int equal_component(const wchar_t *part, size_t length, const wchar_t *name)
{
    return length == wcslen(name)
        && CompareStringOrdinal(part, (int)length, name, -1, TRUE) == CSTR_EQUAL;
}

/* Reject Windows aliases as well as traversal, ADS, rooted and malformed paths. */
static int validate_path(wchar_t *path)
{
    wchar_t *cursor = path, *start = path;
    if (*path == 0) return 0;
    for (;;) {
        wchar_t c = *cursor;
        if (c == L'\\') c = *cursor = L'/';
        if (c != 0 && (c < 32 || c == 127 || wcschr(L":<>\"|?*", c)))
            return 0;
        if (c == L'/' || c == 0) {
            size_t length = (size_t)(cursor - start), stem;
            if (length == 0 || start[length - 1] == L' ' || start[length - 1] == L'.')
                return 0;
            stem = 0;
            while (stem < length && start[stem] != L'.') ++stem;
            while (stem > 0 && start[stem - 1] == L' ') --stem;
            if (equal_component(start, stem, L"CON")
                || equal_component(start, stem, L"PRN")
                || equal_component(start, stem, L"AUX")
                || equal_component(start, stem, L"NUL")
                || equal_component(start, stem, L"CONIN$")
                || equal_component(start, stem, L"CONOUT$")) return 0;
            if (stem == 4 && (equal_component(start, 3, L"COM")
                || equal_component(start, 3, L"LPT"))
                && ((start[3] >= L'1' && start[3] <= L'9')
                    || start[3] == 0x00b9 || start[3] == 0x00b2 || start[3] == 0x00b3))
                return 0;
            if (c == 0) break;
            start = cursor + 1;
        }
        ++cursor;
    }
    return 1;
}

static int compare_paths(const void *left, const void *right)
{
    const BundleFile *a = *(BundleFile * const *)left;
    const BundleFile *b = *(BundleFile * const *)right;
    int result = CompareStringOrdinal(a->path, -1, b->path, -1, TRUE);
    return result == CSTR_LESS_THAN ? -1 : result == CSTR_GREATER_THAN ? 1 : 0;
}

static BundleFile *find_file_folded(Runtime *runtime, const wchar_t *path, int path_length)
{
    size_t low = 0, high = runtime->count;
    while (low < high) {
        size_t middle = low + (high - low) / 2;
        BundleFile *file = runtime->sorted[middle];
        int result = CompareStringOrdinal(path, path_length, file->path, -1, TRUE);
        if (result == CSTR_LESS_THAN) high = middle;
        else if (result == CSTR_GREATER_THAN) low = middle + 1;
        else return file;
    }
    return NULL;
}

static BundleFile *find_file(Runtime *runtime, const wchar_t *path)
{
    BundleFile *file = find_file_folded(runtime, path, -1);
    return file != NULL && CompareStringOrdinal(path, -1, file->path, -1, FALSE)
        == CSTR_EQUAL ? file : NULL;
}

static int verify_hash(Runtime *runtime, const unsigned char *data,
    uint64_t length, const unsigned char *expected)
{
    BCRYPT_ALG_HANDLE algorithm = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    PUCHAR object = NULL;
    DWORD object_size = 0, property_size = 0;
    unsigned char digest[32];
    NTSTATUS status;
    int result = 0;
    status = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, NULL, 0);
    if (status < 0) goto done;
    status = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
        (PUCHAR)&object_size, sizeof(object_size), &property_size, 0);
    if (status < 0 || property_size != sizeof(object_size) || object_size == 0) goto done;
    object = (PUCHAR)malloc(object_size);
    if (object == NULL) goto done;
    status = BCryptCreateHash(algorithm, &hash, object, object_size, NULL, 0, 0);
    if (status < 0) goto done;
    while (length > 0) {
        ULONG chunk = length > UINT32_C(1048576) ? UINT32_C(1048576) : (ULONG)length;
        status = BCryptHashData(hash, (PUCHAR)data, chunk, 0);
        if (status < 0) goto done;
        data += chunk;
        length -= chunk;
    }
    status = BCryptFinishHash(hash, digest, sizeof(digest), 0);
    if (status < 0) goto done;
    result = memcmp(digest, expected, sizeof(digest)) == 0;
done:
    if (hash != NULL) BCryptDestroyHash(hash);
    free(object);
    if (algorithm != NULL) BCryptCloseAlgorithmProvider(algorithm, 0);
    return result ? 1 : fail(runtime, "Executable bundle checksum verification failed");
}

static int map_executable(Runtime *runtime)
{
    wchar_t *path = (wchar_t *)malloc(32768u * sizeof(wchar_t));
    DWORD length;
    LARGE_INTEGER size;
    if (path == NULL) return fail(runtime, "Out of memory");
    length = GetModuleFileNameW(NULL, path, 32768u);
    if (length == 0 || length >= 32768u) {
        free(path);
        return fail(runtime, "Cannot locate this executable");
    }
    runtime->file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    free(path);
    if (runtime->file == INVALID_HANDLE_VALUE)
        return fail(runtime, "Cannot open this executable");
    if (!GetFileSizeEx(runtime->file, &size) || size.QuadPart < FOOTER_SIZE
        || (uint64_t)size.QuadPart > SIZE_MAX)
        return fail(runtime, "Invalid executable size");
    runtime->image_size = (uint64_t)size.QuadPart;
    runtime->mapping = CreateFileMappingW(runtime->file, NULL, PAGE_READONLY, 0, 0, NULL);
    if (runtime->mapping == NULL) return fail(runtime, "Cannot map this executable");
    runtime->image = (const unsigned char *)MapViewOfFile(runtime->mapping,
        FILE_MAP_READ, 0, 0, 0);
    if (runtime->image == NULL) return fail(runtime, "Cannot read this executable");
    return 1;
}

static int read_bundle(Runtime *runtime)
{
    const unsigned char magic[8] = {'L','C','B','E','X','E','1',0};
    const unsigned char *footer = runtime->image + (size_t)runtime->image_size - FOOTER_SIZE;
    const unsigned char *bundle;
    uint64_t offset, length, position, footer_offset;
    uint32_t entry_length, i;
    UINT codepage;
    wchar_t *entry_path;
    if (memcmp(footer, magic, sizeof(magic)) != 0)
        return fail(runtime, "This launcher does not contain a valid embedded bundle");
    offset = read_u64(footer + 8);
    length = read_u64(footer + 16);
    entry_length = read_u32(footer + 24);
    codepage = read_u32(footer + 28);
    if (codepage == 0) codepage = GetACP();
    footer_offset = runtime->image_size - FOOTER_SIZE;
    if (!IsValidCodePage(codepage) || length < 12 || length > MAX_BUNDLE_SIZE
        || offset < 64 || offset > footer_offset || length > footer_offset - offset
        || entry_length == 0 || entry_length > MAX_PATH_BYTES
        || (uint64_t)entry_length != footer_offset - offset - length)
        return fail(runtime, "Invalid executable footer or bundle bounds");
    bundle = runtime->image + (size_t)offset;
    if (!verify_hash(runtime, bundle, length + entry_length, footer + 32)) return 0;
    if (memcmp(bundle, "LCB1", 4) != 0 || read_u32(bundle + 4) != 1)
        return fail(runtime, "Unsupported LCB header or format version");
    runtime->count = read_u32(bundle + 8);
    if (runtime->count == 0 || runtime->count > MAX_FILES
        || runtime->count > (length - 12) / 13)
        return fail(runtime, "Invalid LCB file count");
    runtime->files = (BundleFile *)calloc(runtime->count, sizeof(BundleFile));
    runtime->sorted = (BundleFile **)calloc(runtime->count, sizeof(BundleFile *));
    if (runtime->files == NULL || runtime->sorted == NULL) {
        /* release_runtime must not index a failed allocation. */
        runtime->count = 0;
        return fail(runtime, "Out of memory");
    }
    position = 12;
    for (i = 0; i < runtime->count; ++i) {
        uint32_t path_length;
        uint64_t file_size;
        BundleFile *file = &runtime->files[i];
        if (position > length || length - position < 12)
            return fail(runtime, "Truncated LCB file header");
        path_length = read_u32(bundle + (size_t)position);
        file_size = read_u64(bundle + (size_t)position + 4);
        position += 12;
        if (path_length == 0 || path_length > MAX_PATH_BYTES
            || path_length > length - position)
            return fail(runtime, "Invalid LCB path length");
        file->path = decode_path((const char *)bundle + (size_t)position, path_length, codepage);
        if (file->path == NULL || !validate_path(file->path))
            return fail(runtime, "Unsafe or invalid LCB file path");
        file->utf8_path = encode_utf8(file->path);
        if (file->utf8_path == NULL) return fail(runtime, "Cannot convert LCB path to UTF-8");
        position += path_length;
        if (file_size > length - position)
            return fail(runtime, "Truncated or oversized LCB file content");
        file->data = bundle + (size_t)position;
        file->size = (size_t)file_size;
        runtime->sorted[i] = file;
        position += file_size;
    }
    if (position != length) return fail(runtime, "Unexpected trailing LCB data");
    qsort(runtime->sorted, runtime->count, sizeof(BundleFile *), compare_paths);
    for (i = 1; i < runtime->count; ++i) {
        const wchar_t *previous = runtime->sorted[i - 1]->path;
        const wchar_t *current = runtime->sorted[i]->path;
        if (CompareStringOrdinal(previous, -1, current, -1, TRUE) == CSTR_EQUAL)
            return fail(runtime, "Duplicate or conflicting LCB file paths");
    }
    /* A punctuation sibling can sort between a file and its child: a, a!, a/b. */
    for (i = 0; i < runtime->count; ++i) {
        const wchar_t *path = runtime->sorted[i]->path, *cursor;
        for (cursor = path; *cursor != 0; ++cursor) {
            if (*cursor == L'/' && find_file_folded(runtime, path, (int)(cursor - path)) != NULL)
                return fail(runtime, "Duplicate or conflicting LCB file paths");
        }
    }
    entry_path = decode_path((const char *)bundle + (size_t)length, entry_length, CP_UTF8);
    if (entry_path == NULL || !validate_path(entry_path)) {
        free(entry_path);
        return fail(runtime, "Invalid entry script path");
    }
    runtime->entry = find_file(runtime, entry_path);
    free(entry_path);
    if (runtime->entry == NULL) return fail(runtime, "Entry script is missing from bundle");
    return 1;
}

static Runtime *lua_runtime(lua_State *state)
{
    return (Runtime *)lua_touserdata(state, lua_upvalueindex(1));
}

static BundleFile *lua_find_file(lua_State *state, Runtime *runtime, int argument)
{
    size_t length;
    const char *path = luaL_checklstring(state, argument, &length);
    wchar_t *wide = decode_path(path, length, CP_UTF8);
    BundleFile *file = NULL;
    if (wide != NULL && validate_path(wide)) file = find_file(runtime, wide);
    free(wide);
    return file;
}

static int lcb_read(lua_State *state)
{
    BundleFile *file = lua_find_file(state, lua_runtime(state), 1);
    if (file == NULL) {
        lua_pushnil(state);
        lua_pushliteral(state, "Embedded file not found or invalid path");
        return 2;
    }
    lua_pushlstring(state, (const char *)file->data, file->size);
    return 1;
}

static int lcb_exists(lua_State *state)
{
    lua_pushboolean(state, lua_find_file(state, lua_runtime(state), 1) != NULL);
    return 1;
}

static int lcb_files(lua_State *state)
{
    Runtime *runtime = lua_runtime(state);
    uint32_t i;
    lua_createtable(state, (int)runtime->count, 0);
    for (i = 0; i < runtime->count; ++i) {
        lua_pushstring(state, runtime->files[i].utf8_path);
        lua_rawseti(state, -2, (lua_Integer)i + 1);
    }
    return 1;
}

static int load_embedded(lua_State *state, BundleFile *file)
{
    int status;
    const char *source = (const char *)file->data;
    size_t length = file->size;
    /* Match luaL_loadfile's text preamble handling without extracting files. */
    if (length >= 3 && (unsigned char)source[0] == 0xef
        && (unsigned char)source[1] == 0xbb && (unsigned char)source[2] == 0xbf) {
        source += 3;
        length -= 3;
    }
    if (length > 0 && source[0] == '#') {
        while (length > 0 && source[0] != '\n') {
            ++source;
            --length;
        }
    }
    lua_pushfstring(state, "@lcb/%s", file->utf8_path);
    status = luaL_loadbufferx(state, source, length,
        lua_tostring(state, -1), "t");
    lua_remove(state, -2);
    return status;
}

/* Keep mapped-byte access native; module search policy belongs to bootstrap.lua. */
static int load_embedded_path(lua_State *state)
{
    BundleFile *file = lua_find_file(state, lua_runtime(state), 1);
    if (file == NULL) {
        lua_pushnil(state);
        return 1;
    }
    if (load_embedded(state, file) != LUA_OK) return lua_error(state);
    lua_pushstring(state, file->utf8_path);
    return 2;
}

static void install_bundle_api(lua_State *state, Runtime *runtime)
{
    static const luaL_Reg functions[] = {
        {"read", lcb_read}, {"exists", lcb_exists}, {"files", lcb_files}, {NULL, NULL}
    };
    lua_newtable(state);
    lua_pushlightuserdata(state, runtime);
    luaL_setfuncs(state, functions, 1);
    lua_pushstring(state, lua_license);
    lua_setfield(state, -2, "license");
#ifdef LC_DESKTOP
    lua_pushstring(state, lc_third_party_licenses);
    lua_setfield(state, -2, "third_party_licenses");
#endif
    lua_pushvalue(state, -1);
    lua_setglobal(state, "lcb");
    luaL_getsubtable(state, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
    lua_pushvalue(state, -2);
    lua_setfield(state, -2, "lcb");
    lua_pop(state, 2);

    if (luaL_loadbufferx(state, (const char *)lc_bootstrap, sizeof(lc_bootstrap) - 1,
        "@luacompiler/bootstrap.lua", "t") != LUA_OK) lua_error(state);
    lua_pushlightuserdata(state, runtime);
    lua_pushcclosure(state, load_embedded_path, 1);
    lua_call(state, 1, 0);
}

static int traceback(lua_State *state)
{
    const char *message = lua_tostring(state, 1);
    if (message != NULL) luaL_traceback(state, state, message, 1);
    else lua_pushliteral(state, "Lua raised a non-string error");
    return 1;
}

static void print_lua_error(lua_State *state)
{
    const char *message = lua_tostring(state, -1);
    report_error(message != NULL ? message : "Unknown Lua error");
}

typedef struct Execution {
    Runtime *runtime;
    int argc;
    wchar_t **argv;
    int validate_only;
    int exit_code;
} Execution;

/* All allocation-capable Lua setup runs under pcall, including opening libraries. */
static int execute(lua_State *state)
{
    Execution *execution = (Execution *)lua_touserdata(state, 1);
    Runtime *runtime = execution->runtime;
    int i, status;
    luaL_openlibs(state);
    install_bundle_api(state, runtime);
    install_native_modules(state);
    lua_createtable(state, execution->argc, 0);
    for (i = 0; i < execution->argc; ++i) {
        char *argument = encode_utf8(execution->argv[i]);
        if (argument == NULL) return luaL_error(state, "Cannot convert command line to UTF-8");
        lua_pushstring(state, argument);
        free(argument);
        lua_rawseti(state, -2, i);
    }
    lua_setglobal(state, "arg");
    status = load_embedded(state, runtime->entry);
    if (status != LUA_OK) return lua_error(state);
    if (execution->validate_only) return 0;
    /* The entry chunk receives the application arguments in ... as Lua does. */
    luaL_checkstack(state, execution->argc, "Too many application arguments");
    for (i = 1; i < execution->argc; ++i) {
        char *argument = encode_utf8(execution->argv[i]);
        if (argument == NULL) return luaL_error(state, "Cannot convert command line to UTF-8");
        lua_pushstring(state, argument);
        free(argument);
    }
    lua_call(state, execution->argc - 1, 1);
    if (lua_isinteger(state, -1)) {
        lua_Integer code = lua_tointeger(state, -1);
        if (code < 0 || code > 255)
            return luaL_error(state, "Application return code must be between 0 and 255");
        execution->exit_code = (int)code;
    }
    return 0;
}

int main(void)
{
    Runtime runtime;
    Execution execution;
    lua_State *state = NULL;
    wchar_t **argv = NULL;
    int argc = 0, result = 1;
    const unsigned char magic[8] = {'L','C','B','E','X','E','1',0};
    memset(&runtime, 0, sizeof(runtime));
    memset(&execution, 0, sizeof(execution));
    argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (argv == NULL || argc < 1) {
        fail(&runtime, "Cannot read command line");
        goto done;
    }
    diagnostic_mode = argc == 2 && (wcscmp(argv[1], L"--luacompiler-probe") == 0
        || wcscmp(argv[1], L"--luacompiler-capabilities") == 0
        || wcscmp(argv[1], L"--luacompiler-validate") == 0
        || wcscmp(argv[1], L"--luacompiler-license") == 0);
    if (argc == 2 && wcscmp(argv[1], L"--luacompiler-license") == 0) {
        fputs(lua_license, stdout);
#ifdef LC_DESKTOP
        fputs(lc_third_party_licenses, stdout);
#endif
        result = 0;
        goto done;
    }
    if (!map_executable(&runtime)) goto done;
    if (argc == 2 && wcscmp(argv[1], L"--luacompiler-probe") == 0) {
        if (memcmp(runtime.image + (size_t)runtime.image_size - FOOTER_SIZE, magic, 8) == 0) {
            fail(&runtime, "Launcher probe requires an unbundled template");
            goto done;
        }
        if (!check_bootstrap_syntax(&runtime)) goto done;
        puts("LuaCompiler launcher 1 Lua 5.4");
        result = 0;
        goto done;
    }
    if (argc == 2 && wcscmp(argv[1], L"--luacompiler-capabilities") == 0) {
        if (memcmp(runtime.image + (size_t)runtime.image_size - FOOTER_SIZE, magic, 8) == 0) {
            fail(&runtime, "Launcher capabilities require an unbundled template");
            goto done;
        }
#ifdef LC_DESKTOP
        puts("LuaCompiler runtime 1 console gui vulkan2d vulkan3d");
#else
        puts("LuaCompiler runtime 1 console");
#endif
        result = 0;
        goto done;
    }
    if (!read_bundle(&runtime)) goto done;
    execution.runtime = &runtime;
    execution.argc = argc;
    execution.argv = argv;
    execution.validate_only = argc == 2 && wcscmp(argv[1], L"--luacompiler-validate") == 0;
    state = luaL_newstate();
    if (state == NULL) {
        fail(&runtime, "Cannot allocate Lua state");
        goto done;
    }
    lua_pushcfunction(state, traceback);
    lua_pushcfunction(state, execute);
    lua_pushlightuserdata(state, &execution);
    if (lua_pcall(state, 1, 0, 1) != LUA_OK) {
        print_lua_error(state);
        goto done;
    }
    if (execution.validate_only) puts("LuaCompiler executable valid");
    result = execution.exit_code;
done:
    if (result != 0 && runtime.error[0] != 0)
        report_error(runtime.error);
    if (state != NULL) lua_close(state);
    release_runtime(&runtime);
    if (argv != NULL) LocalFree(argv);
    return result;
}
