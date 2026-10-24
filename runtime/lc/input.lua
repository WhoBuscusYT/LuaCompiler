-- Input state is owned by Lua; platform backends only provide event records.
local Input = {}
Input.__index = Input

local function keyName(value)
    assert(type(value) == 'string', 'Key names must be strings')
    return value:lower()
end

function Input.new()
    return setmetatable({keys = {}, pressedKeys = {}, releasedKeys = {}, buttons = {},
        pressedButtons = {}, releasedButtons = {}, mouseX = 0, mouseY = 0,
        mouseDX = 0, mouseDY = 0, wheelX = 0, wheelY = 0, text = {}, quit = false}, Input)
end

function Input:beginFrame()
    self.pressedKeys, self.releasedKeys = {}, {}
    self.pressedButtons, self.releasedButtons = {}, {}
    self.mouseDX, self.mouseDY, self.wheelX, self.wheelY = 0, 0, 0, 0
    self.text = {}
end

function Input:feed(event)
    assert(type(event) == 'table', 'Input event must be a table')
    local kind = event.type
    if kind == 'key' then kind = event.down and 'keydown' or 'keyup' end
    if kind == 'mousebutton' then kind = event.down and 'mousedown' or 'mouseup' end
    if kind == 'mousewheel' then kind = 'wheel' end
    if kind == 'quit' then
        self.quit = true
    elseif kind == 'keydown' then
        local key = keyName(event.key)
        if not self.keys[key] then self.pressedKeys[key] = true end
        self.keys[key] = true
    elseif kind == 'keyup' then
        local key = keyName(event.key)
        if self.keys[key] then self.releasedKeys[key] = true end
        self.keys[key] = nil
    elseif kind == 'mousedown' then
        local button = event.button or 1
        if not self.buttons[button] then self.pressedButtons[button] = true end
        self.buttons[button] = true
    elseif kind == 'mouseup' then
        local button = event.button or 1
        if self.buttons[button] then self.releasedButtons[button] = true end
        self.buttons[button] = nil
    elseif kind == 'mousemove' then
        local x, y = event.x or self.mouseX, event.y or self.mouseY
        self.mouseDX = self.mouseDX + (event.dx or x - self.mouseX)
        self.mouseDY = self.mouseDY + (event.dy or y - self.mouseY)
        self.mouseX, self.mouseY = x, y
    elseif kind == 'wheel' then
        self.wheelX = self.wheelX + (event.x or 0)
        self.wheelY = self.wheelY + (event.y or 0)
    elseif kind == 'text' then
        self.text[#self.text + 1] = event.text or ''
    elseif kind == 'blur' then
        for key in pairs(self.keys) do self.releasedKeys[key] = true end
        for button in pairs(self.buttons) do self.releasedButtons[button] = true end
        self.keys, self.buttons = {}, {}
    end
end

function Input:down(key) return self.keys[keyName(key)] == true end
function Input:pressed(key) return self.pressedKeys[keyName(key)] == true end
function Input:released(key) return self.releasedKeys[keyName(key)] == true end
function Input:mouseDown(button) return self.buttons[button or 1] == true end
function Input:mousePressed(button) return self.pressedButtons[button or 1] == true end
function Input:mouseReleased(button) return self.releasedButtons[button or 1] == true end

return Input
