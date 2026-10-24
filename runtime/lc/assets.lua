-- Asset decoding, caching and OBJ triangulation remain in Lua.
local Math = require('lc.math')
local Assets = {}
Assets.__index = Assets
local MAX_IMAGE = 8192

local function safePath(path)
    assert(type(path) == 'string' and #path > 0 and not path:find('[%z\\:]')
        and path:sub(1, 1) ~= '/', 'Asset path must be a relative forward-slash path')
    for part in (path .. '/'):gmatch('(.-)/') do
        assert(part ~= '' and part ~= '.' and part ~= '..', 'Unsafe asset path')
    end
    return path
end

local function defaultRead(path)
    safePath(path)
    if lcb then return assert(lcb.read(path)) end
    local file = assert(io.open(path, 'rb'))
    local bytes = assert(file:read('a'))
    assert(file:close())
    return bytes
end

local function dimensions(width, height)
    assert(math.type(width) == 'integer' and math.type(height) == 'integer'
        and width >= 1 and height >= 1 and width <= MAX_IMAGE and height <= MAX_IMAGE
        and width * height <= 16777216, 'Texture dimensions exceed supported limits')
end

function Assets.decodeBMP(bytes)
    assert(type(bytes) == 'string' and #bytes >= 54 and bytes:sub(1, 2) == 'BM',
        'Expected a Windows BMP image')
    local declared = string.unpack('<I4', bytes, 3)
    local offset = string.unpack('<I4', bytes, 11)
    local dib = string.unpack('<I4', bytes, 15)
    local width, height, planes, bits, compression = string.unpack('<i4i4I2I2I4', bytes, 19)
    assert(dib >= 40 and dib <= #bytes - 14 and offset >= 14 + dib, 'Invalid BMP header')
    assert(planes == 1 and (bits == 24 or bits == 32) and compression == 0,
        'Only uncompressed 24-bit and 32-bit BMP textures are supported')
    dimensions(width, math.abs(height))
    local rows, stride = math.abs(height), ((width * bits + 31) // 32) * 4
    local finish = offset + stride * rows
    assert(finish <= #bytes and (declared == 0 or declared >= finish and declared <= #bytes),
        'Truncated BMP pixel data')
    local output = {}
    for y = 0, rows - 1 do
        local sourceY = height > 0 and rows - 1 - y or y
        local row = offset + sourceY * stride + 1
        local pixels = {}
        for x = 0, width - 1 do
            local index = row + x * (bits // 8)
            local blue, green, red, alpha = bytes:byte(index, index + (bits // 8) - 1)
            pixels[#pixels + 1] = string.char(red, green, blue, bits == 32 and alpha or 255)
        end
        output[#output + 1] = table.concat(pixels)
    end
    return {width = width, height = rows, pixels = table.concat(output)}
end

function Assets.decodePPM(bytes)
    assert(type(bytes) == 'string' and bytes:sub(1, 2) == 'P6', 'Expected a binary P6 PPM image')
    local at = 3
    local function token()
        while true do
            local _, last = bytes:find('^%s+', at)
            if last then at = last + 1 end
            if bytes:sub(at, at) ~= '#' then break end
            at = assert(bytes:find('\n', at, true), 'Truncated PPM comment') + 1
        end
        local first, last = bytes:find('^%d+', at)
        assert(first, 'Invalid PPM header')
        at = last + 1
        return tonumber(bytes:sub(first, last))
    end
    local width, height, maximum = token(), token(), token()
    dimensions(width, height)
    assert(maximum == 255, 'Only 8-bit PPM textures are supported')
    assert(bytes:sub(at, at):match('%s'), 'Missing PPM pixel separator')
    if bytes:sub(at, at + 1) == '\r\n' then at = at + 2 else at = at + 1 end
    assert(#bytes - at + 1 == width * height * 3, 'Invalid PPM pixel data length')
    local rows = {}
    for y = 0, height - 1 do
        local row = {}
        for x = 0, width - 1 do
            local index = at + (y * width + x) * 3
            row[#row + 1] = bytes:sub(index, index + 2) .. '\255'
        end
        rows[#rows + 1] = table.concat(row)
    end
    return {width = width, height = height, pixels = table.concat(rows)}
end

local function objIndex(text, list, kind)
    local index = tonumber(text)
    assert(index and math.type(index) == 'integer' and index ~= 0, 'Invalid OBJ ' .. kind .. ' index')
    if index < 0 then index = #list + index + 1 end
    assert(list[index], 'OBJ ' .. kind .. ' index is out of bounds')
    return list[index]
end

function Assets.decodeOBJ(bytes)
    assert(type(bytes) == 'string' and #bytes <= 32 * 1024 * 1024, 'OBJ data is too large')
    local positions, normals, coordinates, triangles = {}, {}, {}, {}
    local function numbers(text, count)
        local result = {}
        for word in text:gmatch('%S+') do
            result[#result + 1] = Math.number(assert(tonumber(word), 'Invalid OBJ number'))
            if #result == count then break end
        end
        assert(#result == count, 'Missing OBJ coordinates')
        return result
    end
    for line in (bytes .. '\n'):gmatch('(.-)\r?\n') do
        line = line:gsub('#.*', '')
        local kind, value = line:match('^%s*(%S+)%s+(.+)$')
        if kind == 'v' then
            assert(#positions < 1000000, 'OBJ has too many positions')
            positions[#positions + 1] = numbers(value, 3)
        elseif kind == 'vn' then
            normals[#normals + 1] = Math.normalize(numbers(value, 3))
        elseif kind == 'vt' then
            coordinates[#coordinates + 1] = numbers(value, 2)
        elseif kind == 'f' then
            local face = {}
            for item in value:gmatch('%S+') do
                local p, t, n = item:match('^(-?%d+)/(%-?%d*)/(%-?%d*)$')
                if not p then p, t = item:match('^(-?%d+)/(-?%d+)$') end
                if not p then p = item:match('^(-?%d+)$') end
                assert(p, 'Malformed OBJ face')
                face[#face + 1] = {position = objIndex(p, positions, 'position'),
                    uv = t and t ~= '' and objIndex(t, coordinates, 'texture') or {0, 1},
                    normal = n and n ~= '' and objIndex(n, normals, 'normal') or nil}
                assert(#face <= 128, 'OBJ polygon has too many corners')
            end
            assert(#face >= 3, 'OBJ face must have at least three corners')
            for corner = 2, #face - 1 do
                local a, b, c = face[1], face[corner], face[corner + 1]
                local faceNormal = Math.normalize(Math.cross(Math.sub(b.position, a.position),
                    Math.sub(c.position, a.position)))
                for _, vertex in ipairs({a, b, c}) do
                    local p, n, uv = vertex.position, vertex.normal or faceNormal, vertex.uv
                    triangles[#triangles + 1] = {p[1], p[2], p[3], n[1], n[2], n[3], uv[1], 1 - uv[2]}
                end
                assert(#triangles <= 1500000, 'OBJ has too many triangles')
            end
        end
    end
    assert(#triangles > 0, 'OBJ contains no supported triangle faces')
    return {vertices = triangles}
end

function Assets.new(renderer, reader)
    return setmetatable({renderer = renderer, reader = reader or defaultRead,
        byteCache = {}, meshCache = {}, textureCache = {}}, Assets)
end

function Assets:read(path)
    safePath(path)
    if not self.byteCache[path] then self.byteCache[path] = assert(self.reader(path)) end
    return self.byteCache[path]
end

function Assets:mesh(path)
    if not self.meshCache[path] then self.meshCache[path] = Assets.decodeOBJ(self:read(path)) end
    return self.meshCache[path]
end

function Assets:upload(image)
    dimensions(image.width, image.height)
    assert(type(image.pixels) == 'string' and #image.pixels == image.width * image.height * 4,
        'RGBA texture data length does not match its dimensions')
    return {handle = self.renderer:texture(image.width, image.height, image.pixels),
        width = image.width, height = image.height}
end

function Assets:texture(path)
    if not self.textureCache[path] then
        local bytes = self:read(path)
        local decoder = bytes:sub(1, 2) == 'BM' and Assets.decodeBMP or Assets.decodePPM
        self.textureCache[path] = self:upload(decoder(bytes))
    end
    return self.textureCache[path]
end

function Assets:checker(width, height, cell, first, second)
    dimensions(width, height)
    assert(math.type(cell) == 'integer' and cell > 0, 'Checker cell size must be a positive integer')
    first, second = first or {255, 255, 255, 255}, second or {40, 100, 230, 255}
    local a, b = string.char(table.unpack(first)), string.char(table.unpack(second))
    assert(#a == 4 and #b == 4, 'Checker colors must contain four bytes')
    local rows = {}
    for y = 0, height - 1 do
        local row = {}
        for x = 0, width - 1 do row[#row + 1] = (x // cell + y // cell) % 2 == 0 and a or b end
        rows[#rows + 1] = table.concat(row)
    end
    return self:upload({width = width, height = height, pixels = table.concat(rows)})
end

function Assets:clearCache()
    -- GPU resources remain owned by the renderer until it closes.
    self.byteCache, self.meshCache, self.textureCache = {}, {}, {}
end

return Assets
