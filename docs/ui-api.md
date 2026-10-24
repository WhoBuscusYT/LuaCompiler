# Native Windows application API

The public framework is `require('lc.ui')`. Windows and controls are Win32
objects. Ownership, callbacks, menu descriptions, event dispatch, application
loops and error cleanup are implemented in Lua. The native `lc_native_ui`
module supplies the platform operations and a message queue.

Build a desktop application from CMD or PowerShell:

```
luacompiler build "path to project" MyApplication Main.lua --mode gui
```

GUI builds embed `Runtime.lcb` and use the Windows GUI subsystem. Add `--console`
for a development build that also has a console. A console build can embed the
framework with `--runtime`. No Lua installation or separate project scripts are
needed to run the completed executable.

## A small application

```lua
local UI = require('lc.ui')
local App = UI.app()
local Window = App:window{
    title='My Lua application', width=480, height=240, resizable=true,
}
Window:label{text='Your name', x=20, y=20, width=200, height=24}
local Name = Window:input{text='World', x=20, y=48, width=260, height=28}
local Output = Window:label{x=20, y=140, width=420, height=40}
Window:button{
    text='Greet', x=300, y=48, width=120, height=28,
    onClick=function() Output:text('Hello, '..Name:text()..'!') end,
}
return App:run()
```

Use one application object for a desktop application's windows. Call the API
from its Lua thread. Window coordinates are screen coordinates; controls use
coordinates within their parent window. Dimensions are pixels under Windows'
current DPI virtualization. Window `width` and `height` set its initial client
area; later `bounds` changes use Win32 outer window dimensions.

## Applications and objects

`UI.app()` creates an application. `App:window(options)` creates a window with
`title`, `width`, `height`, optional `x`/`y`, `resizable` and `visible`. Windows
are visible and resizable by default. `visible=false` supports deferred display
and automated checks. A window may contain several native controls:

| Factory | Specific options |
| --- | --- |
| `Window:button(options)` | `text`, `onClick` |
| `Window:label(options)` | `text` |
| `Window:input(options)` | `text`, `multiline`, `password`, `onChange` |
| `Window:checkbox(options)` | `text`, `checked`, `onClick` |
| `Window:dropdown(options)` | `items`, `selected`, `onChange` |

Control options also accept `x`, `y`, `width`, `height`, `visible` and `enabled`.
For a dropdown, `height` includes its expanded list; the default is 160.
`items` contains strings, and `selected` uses a one-based index. Text must be
valid UTF-8 with no embedded NUL. Assets remain available through `lcb.read`.

Objects provide these methods:

| Method | Behavior |
| --- | --- |
| `Object:text()` / `Object:text(value)` | Read or set native text |
| `Object:show(visible)` | Show or hide; defaults to showing |
| `Object:enable(enabled)` | Enable or disable; defaults to enabling |
| `Object:focus()` | Request keyboard focus |
| `Object:bounds{x=...,y=...,width=...,height=...}` | Set position and dimensions |
| `Object:isClosed()` | Check whether the native object was destroyed |
| `Object:close()` | Destroy the native object; safe to repeat |
| `Object:on(event, callback)` | Set a handler; `nil` removes it |
| `Checkbox:checked()` / `Checkbox:checked(boolean)` | Read or set checked state |
| `Dropdown:selection()` / `Dropdown:selection(index)` | Read or set selection; zero means none |
| `Dropdown:addItem(text)` | Append an item; Lua `Dropdown.items` stores its strings |
| `Button:click()` / `Checkbox:click()` | Invoke a native click, including its notification |
| `Window:requestClose()` | Queue a close request that can be cancelled |

Setters return their object for chaining. Getter methods return their value.
Operations on destroyed controls raise a Lua error. Destroying a parent window
also destroys its controls. Construction errors close partially created objects.

## Events and loops

Handlers receive `(object, event)`. Callbacks execute in Lua when messages are
polled, outside Win32 window procedures. Callback options use the names below;
the equivalent `Object:on` event names appear in the first column.

| Event | Callback option | Event fields |
| --- | --- | --- |
| `click` | `onClick` | `checked` for a checkbox |
| `change` | `onChange` | `text` for input; `index`, `value` for dropdown |
| `close` | `onClose` | Return `false` to cancel a requested close |
| `closed` | `onClosed` | Window destruction notification |
| `resize` | `onResize` | `width`, `height` client dimensions |
| `key_down`, `key_up` | `onKeyDown`, `onKeyUp` | `key`, a Windows virtual-key code |
| `text` | `onText` | `text`, one UTF-8 code point |
| `mouse_move` | `onMouseMove` | `x`, `y` client coordinates |
| `mouse_down`, `mouse_up` | `onMouseDown`, `onMouseUp` | `x`, `y`, `button`: left=1, right=2, middle=3 |
| `mouse_wheel` | `onMouseWheel` | `x`, `y`, `delta`: wheel notches |

`event.object` identifies the source. Register input handlers on the window or
control that receives the input; events do not bubble. Native keyboard
navigation handles Tab and normal control activation. Useful virtual-key codes
are in `UI.keys`: `escape`, `enter`, `tab`, `space`, and the four arrow keys.

`App:run()` pumps events until all windows close or `App:quit(code)` is called,
then closes remaining application windows and returns the exit code. Codes are
integers from 0 through 255, defaulting to zero. A callback failure closes the
application's windows and rethrows the Lua error with a traceback.

For an existing application loop, `App:step(timeoutMilliseconds)` polls and
dispatches a batch, returning whether it processed events. The timeout defaults
to zero and must be between zero and 60,000. `App:hasWindows()` reports whether
any window remains open. `App:close()` destroys all of that application's
windows. Queued notifications are delivered during polling; stale input for
already destroyed objects is discarded.

## Menus and message dialogs

```lua
Window:menu{
    {label='File', items={
        {label='Exit', onClick=function() Window:requestClose() end},
    }},
    {label='Help', items={
        {label='About', onClick=function()
            Window:dialog{title='About', message='Built with LuaCompiler'}
        end},
    }},
}
```

`Window:menu` replaces the existing menu. Leaf items accept `onClick`; nested
items accept `items`. Menu callbacks receive the window and event.

`UI.dialog{parent=Window,title='Question',message='Continue?',kind='question'}`
returns `'yes'` or `'no'`. Kinds `info`, `warning` and `error` return `'ok'`.
`Window:dialog(options)` supplies the parent automatically. Dialogs use native
modal message boxes; Lua event callbacks resume after dismissal.

## Current scope and verification

The API targets Windows x64 and standard controls. It uses system User32 and
Gdi32 libraries. Layout is explicit; automatic layout, custom styling,
per-monitor DPI handling, accessibility-specific helpers, rich text and file
picker dialogs are future extensions. Menus allow up to eight nested levels;
objects and menu IDs have a lifetime limit of 65,535. The native queue holds
1,024 events and reports overflow as a Lua error; poll regularly and keep
callbacks brief.

`examples/NativeUI/Main.lua` demonstrates text input, buttons, checkbox,
dropdown, menus and a native dialog. Passing `--self-test` creates hidden real
controls, invokes their native notifications, checks UTF-8 text and close
cancellation, then prints `NATIVE_UI_SELF_TEST_OK`.

`tests/ui.lua` adds construction failures, invalid arguments, resize events,
callback failure cleanup and application exit codes. The development harness
executed 34 checks successfully. Visual interaction checks and packaged runtime
checks should accompany changes to native launcher integration.
