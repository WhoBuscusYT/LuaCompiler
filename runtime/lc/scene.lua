-- Scene, geometry, camera, transform, lighting and draw batching are Lua systems.
local Math = require('lc.math')
local Scene, Entity, Camera = {}, {}, {}
Scene.__index, Entity.__index, Camera.__index = Scene, Entity, Camera
local PACK_VERTEX = '<fffffffff f'

local function color(value)
    value = value or {1, 1, 1, 1}
    return {Math.clamp(Math.number(value[1] or 1), 0, 1),
        Math.clamp(Math.number(value[2] or 1), 0, 1),
        Math.clamp(Math.number(value[3] or 1), 0, 1),
        Math.clamp(Math.number(value[4] or 1), 0, 1)}
end

local function copyVector(value, fallback)
    value = value or fallback
    return Math.vec3(value[1], value[2], value[3])
end

function Scene.perspective(options)
    options = options or {}
    return setmetatable({kind = 'perspective', fov = options.fov or math.rad(60),
        near = options.near or 0.1, far = options.far or 1000,
        position = copyVector(options.position, {0, 0, 5}),
        target = copyVector(options.target, {0, 0, 0}),
        up = copyVector(options.up, {0, 1, 0})}, Camera)
end

function Scene.orthographic(options)
    options = options or {}
    return setmetatable({kind = 'orthographic', x = options.x or 0, y = options.y or 0,
        width = options.width, height = options.height, near = options.near or -1000,
        far = options.far or 1000}, Camera)
end

function Camera:matrix(width, height)
    assert(width > 0 and height > 0, 'Camera viewport must be positive')
    if self.kind == 'perspective' then
        return Math.multiply(Math.perspective(self.fov, width / height, self.near, self.far),
            Math.lookAt(self.position, self.target, self.up))
    end
    return Math.orthographic(self.x, self.x + (self.width or width), self.y,
        self.y + (self.height or height), self.near, self.far)
end

function Scene.new(options)
    options = options or {}
    local light = options.light or {}
    return setmetatable({entities = {}, nextId = 1, camera = options.camera or Scene.orthographic(),
        clear = color(options.clear or {0.04, 0.05, 0.08, 1}),
        light = {direction = copyVector(light.direction, {-0.5, -1, -0.7}),
            ambient = light.ambient or 0.22, intensity = light.intensity or 0.78,
            color = color(light.color)}, stats = {entities = 0, triangles = 0, batches = 0}}, Scene)
end

function Scene:entity(options)
    options = options or {}
    local entity = setmetatable({scene = self, id = self.nextId, mesh = options.mesh,
        position = copyVector(options.position, {0, 0, 0}),
        rotation = copyVector(options.rotation, {0, 0, 0}),
        scale = copyVector(options.scale, {1, 1, 1}), color = color(options.color),
        texture = options.texture, layer = options.layer or 0,
        visible = options.visible ~= false, depth = options.depth ~= false,
        lit = options.lit ~= false, update = options.update,
        transparent = options.transparent == true, shade = options.shade,
        _version = 0}, Entity)
    self.nextId = self.nextId + 1
    self.entities[#self.entities + 1] = entity
    if options.parent then entity:setParent(options.parent) end
    return entity
end

function Entity:setPosition(x, y, z)
    self.position = Math.vec3(x, y, z)
    return self
end

function Entity:setRotation(x, y, z)
    self.rotation = Math.vec3(x, y, z)
    return self
end

function Entity:rotate(x, y, z)
    self.rotation = Math.add(self.rotation, Math.vec3(x, y, z))
    return self
end

function Entity:setScale(x, y, z)
    self.scale = Math.vec3(x, y or x, z or x)
    return self
end

function Entity:setParent(parent)
    assert(parent == nil or getmetatable(parent) == Entity and parent.scene == self.scene,
        'Parent must belong to the same scene')
    local current = parent
    while current do
        assert(current ~= self, 'Entity parent cycle')
        current = current.parent
    end
    self.parent = parent
    self._state = nil
    return self
end

function Entity:matrix(visiting)
    visiting = visiting or {}
    assert(not visiting[self], 'Entity parent cycle')
    visiting[self] = true
    local parentMatrix = self.parent and self.parent:matrix(visiting)
    local state = {table.unpack(self.position)}
    for _, value in ipairs(self.rotation) do state[#state + 1] = value end
    for _, value in ipairs(self.scale) do state[#state + 1] = value end
    state[10] = self.parent and self.parent._version or 0
    state[11] = self.parent or false
    local unchanged = self._state ~= nil
    if unchanged then
        for index = 1, 11 do if state[index] ~= self._state[index] then unchanged = false; break end end
    end
    if not unchanged then
        local matrix = Math.compose(self.position, self.rotation, self.scale)
        self._matrix = parentMatrix and Math.multiply(parentMatrix, matrix) or matrix
        self._state, self._version = state, self._version + 1
    end
    visiting[self] = nil
    return self._matrix
end

function Entity:remove()
    self.scene:remove(self)
end

function Scene:remove(entity)
    assert(entity.scene == self, 'Entity belongs to another scene')
    for _, child in ipairs(self.entities) do
        if child.parent == entity then child:setParent(nil) end
    end
    for index, value in ipairs(self.entities) do
        if value == entity then table.remove(self.entities, index); entity.scene = nil; return end
    end
end

function Scene:update(delta, game)
    local snapshot = {table.unpack(self.entities)}
    for _, entity in ipairs(snapshot) do
        if entity.scene == self and entity.update then entity:update(delta, game) end
    end
end

function Scene.rectangle(width, height)
    Math.number(width); Math.number(height)
    assert(width > 0 and height > 0, 'Rectangle dimensions must be positive')
    local x, y = width / 2, height / 2
    return {vertices = {
        {-x, -y, 0, 0, 0, 1, 0, 0}, {x, -y, 0, 0, 0, 1, 1, 0}, {x, y, 0, 0, 0, 1, 1, 1},
        {-x, -y, 0, 0, 0, 1, 0, 0}, {x, y, 0, 0, 0, 1, 1, 1}, {-x, y, 0, 0, 0, 1, 0, 1},
    }}
end

function Scene.circle(radius, segments)
    Math.number(radius)
    segments = segments or 32
    assert(radius > 0 and math.type(segments) == 'integer' and segments >= 3 and segments <= 4096,
        'Invalid circle geometry')
    local vertices = {}
    for segment = 0, segments - 1 do
        local a, b = segment * 2 * math.pi / segments, (segment + 1) * 2 * math.pi / segments
        vertices[#vertices + 1] = {0, 0, 0, 0, 0, 1, 0.5, 0.5}
        for _, angle in ipairs({a, b}) do
            local x, y = math.cos(angle), math.sin(angle)
            vertices[#vertices + 1] = {radius * x, radius * y, 0, 0, 0, 1, (x + 1) / 2, (y + 1) / 2}
        end
    end
    return {vertices = vertices}
end

function Scene.cube(size)
    size = size or 1
    Math.number(size)
    assert(size > 0, 'Cube size must be positive')
    local h, vertices = size / 2, {}
    local faces = {
        {{0, 0, 1}, {-1, -1, 1}, {1, -1, 1}, {1, 1, 1}, {-1, 1, 1}},
        {{0, 0, -1}, {1, -1, -1}, {-1, -1, -1}, {-1, 1, -1}, {1, 1, -1}},
        {{1, 0, 0}, {1, -1, 1}, {1, -1, -1}, {1, 1, -1}, {1, 1, 1}},
        {{-1, 0, 0}, {-1, -1, -1}, {-1, -1, 1}, {-1, 1, 1}, {-1, 1, -1}},
        {{0, 1, 0}, {-1, 1, 1}, {1, 1, 1}, {1, 1, -1}, {-1, 1, -1}},
        {{0, -1, 0}, {-1, -1, -1}, {1, -1, -1}, {1, -1, 1}, {-1, -1, 1}},
    }
    local uv = {{0, 1}, {1, 1}, {1, 0}, {0, 0}}
    for _, face in ipairs(faces) do
        for _, index in ipairs({1, 2, 3, 1, 3, 4}) do
            local p, n, t = face[index + 1], face[1], uv[index]
            vertices[#vertices + 1] = {p[1] * h, p[2] * h, p[3] * h,
                n[1], n[2], n[3], t[1], t[2]}
        end
    end
    return {vertices = vertices}
end

function Scene:sprite(options)
    options = options or {}
    local values = {}
    for key, value in pairs(options) do values[key] = value end
    values.mesh = values.mesh or Scene.rectangle(options.width or options.texture and options.texture.width or 64,
        options.height or options.texture and options.texture.height or 64)
    values.depth, values.lit = false, false
    return self:entity(values)
end

local function compare(a, b)
    if a.layer ~= b.layer then return a.layer < b.layer end
    local transparentA = not a.depth or a.transparent or a.color[4] < 1
    local transparentB = not b.depth or b.transparent or b.color[4] < 1
    if transparentA ~= transparentB then return not transparentA end
    if transparentA and a.depth and b.depth and a._distance ~= b._distance then
        return a._distance > b._distance
    end
    return a.id < b.id
end

function Scene:commands(width, height)
    local viewProjection = self.camera:matrix(width, height)
    local visible = {}
    for _, entity in ipairs(self.entities) do
        if entity.visible and entity.mesh then
            local matrix = entity:matrix()
            entity._distance = self.camera.position and Math.length(Math.sub(
                {matrix[13], matrix[14], matrix[15]}, self.camera.position)) or 0
            visible[#visible + 1] = entity
        end
    end
    table.sort(visible, compare)
    local towardLight = Math.scale(Math.normalize(self.light.direction), -1)
    local commands, chunks, current, triangles = {}, {}, nil, 0
    local function finish()
        if current then current.vertices = table.concat(chunks); commands[#commands + 1] = current end
        chunks = {}
    end
    for _, entity in ipairs(visible) do
        local vertices = assert(entity.mesh.vertices, 'Mesh is missing its vertices')
        assert(#vertices > 0 and #vertices % 3 == 0, 'Meshes must contain complete triangles')
        local texture = entity.texture and (type(entity.texture) == 'table' and entity.texture.handle or entity.texture)
        local depthWrite = entity.depth and not entity.transparent and entity.color[4] >= 1
        if not current or current.texture ~= texture or current.depth ~= entity.depth or current.depthWrite ~= depthWrite then
            finish()
            current = {texture = texture, depth = entity.depth, depthWrite = depthWrite}
        end
        local model = entity:matrix()
        local transform = Math.multiply(viewProjection, model)
        local normalMatrix = entity.lit and Math.normalMatrix(model)
        for _, vertex in ipairs(vertices) do
            assert(#vertex >= 8, 'Mesh vertex needs position, normal and UV coordinates')
            local point = Math.transform(transform, vertex)
            local red, green, blue, alpha = table.unpack(entity.color)
            local worldNormal
            if entity.lit then
                worldNormal = Math.transformNormal(normalMatrix, {vertex[4], vertex[5], vertex[6]})
                local diffuse = self.light.intensity * math.max(0, Math.dot(worldNormal, towardLight))
                red = red * (self.light.ambient + diffuse * self.light.color[1])
                green = green * (self.light.ambient + diffuse * self.light.color[2])
                blue = blue * (self.light.ambient + diffuse * self.light.color[3])
            end
            local u, v = vertex[7], vertex[8]
            if entity.shade then
                local shaded = entity.shade({position = Math.transform(model, vertex), normal = worldNormal,
                    color = {red, green, blue, alpha}, uv = {u, v}})
                assert(type(shaded) == 'table', 'Lua material shader must return a color table')
                red, green, blue, alpha = table.unpack(color(shaded))
            end
            chunks[#chunks + 1] = string.pack(PACK_VERTEX, point[1], point[2], point[3], point[4],
                Math.clamp(red, 0, 1), Math.clamp(green, 0, 1), Math.clamp(blue, 0, 1), alpha, u, v)
        end
        triangles = triangles + #vertices // 3
    end
    finish()
    self.stats = {entities = #visible, triangles = triangles, batches = #commands}
    return commands
end

return Scene
