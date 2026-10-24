-- Lua-side vectors and column-major transforms. Angles are in radians.
local M = {}

local function number(value, name)
    assert(type(value) == 'number' and value == value and math.abs(value) < math.huge,
        (name or 'value') .. ' must be a finite number')
    return value
end
M.number = number

function M.vec3(x, y, z)
    return {number(x or 0), number(y or 0), number(z or 0)}
end

function M.add(a, b)
    return {a[1] + b[1], a[2] + b[2], a[3] + b[3]}
end

function M.sub(a, b)
    return {a[1] - b[1], a[2] - b[2], a[3] - b[3]}
end

function M.scale(a, factor)
    return {a[1] * factor, a[2] * factor, a[3] * factor}
end

function M.dot(a, b)
    return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end

function M.cross(a, b)
    return {a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3],
        a[1] * b[2] - a[2] * b[1]}
end

function M.length(a)
    return math.sqrt(M.dot(a, a))
end

function M.normalize(a)
    local length = M.length(a)
    assert(length > 1e-12, 'Cannot normalize a zero vector')
    return M.scale(a, 1 / length)
end

function M.identity()
    return {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
end

function M.multiply(a, b)
    local result = {}
    for column = 0, 3 do
        for row = 0, 3 do
            local sum = 0
            for k = 0, 3 do
                sum = sum + a[k * 4 + row + 1] * b[column * 4 + k + 1]
            end
            result[column * 4 + row + 1] = sum
        end
    end
    return result
end

function M.transform(matrix, point, w)
    local x, y, z = point[1], point[2], point[3]
    w = w == nil and 1 or w
    return {
        matrix[1] * x + matrix[5] * y + matrix[9] * z + matrix[13] * w,
        matrix[2] * x + matrix[6] * y + matrix[10] * z + matrix[14] * w,
        matrix[3] * x + matrix[7] * y + matrix[11] * z + matrix[15] * w,
        matrix[4] * x + matrix[8] * y + matrix[12] * z + matrix[16] * w,
    }
end

function M.translation(x, y, z)
    local result = M.identity()
    result[13], result[14], result[15] = number(x), number(y), number(z)
    return result
end

function M.scaling(x, y, z)
    return {number(x), 0, 0, 0, 0, number(y), 0, 0, 0, 0, number(z), 0, 0, 0, 0, 1}
end

function M.rotation(x, y, z)
    local cx, sx = math.cos(number(x)), math.sin(x)
    local cy, sy = math.cos(number(y)), math.sin(y)
    local cz, sz = math.cos(number(z)), math.sin(z)
    local rx = {1, 0, 0, 0, 0, cx, sx, 0, 0, -sx, cx, 0, 0, 0, 0, 1}
    local ry = {cy, 0, -sy, 0, 0, 1, 0, 0, sy, 0, cy, 0, 0, 0, 0, 1}
    local rz = {cz, sz, 0, 0, -sz, cz, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
    return M.multiply(rz, M.multiply(ry, rx))
end

function M.compose(position, rotation, scale)
    return M.multiply(M.translation(table.unpack(position)),
        M.multiply(M.rotation(table.unpack(rotation)), M.scaling(table.unpack(scale))))
end

function M.normalMatrix(matrix)
    local a, b, c = matrix[1], matrix[5], matrix[9]
    local d, e, f = matrix[2], matrix[6], matrix[10]
    local g, h, i = matrix[3], matrix[7], matrix[11]
    local determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    assert(math.abs(determinant) > 1e-12, 'A lit mesh cannot have a zero scale')
    return {(e * i - f * h) / determinant, (c * h - b * i) / determinant,
        (b * f - c * e) / determinant, (f * g - d * i) / determinant,
        (a * i - c * g) / determinant, (c * d - a * f) / determinant,
        (d * h - e * g) / determinant, (b * g - a * h) / determinant,
        (a * e - b * d) / determinant}
end

function M.transformNormal(matrix, normal)
    return M.normalize({matrix[1] * normal[1] + matrix[4] * normal[2] + matrix[7] * normal[3],
        matrix[2] * normal[1] + matrix[5] * normal[2] + matrix[8] * normal[3],
        matrix[3] * normal[1] + matrix[6] * normal[2] + matrix[9] * normal[3]})
end

function M.lookAt(eye, target, up)
    local forward = M.normalize(M.sub(target, eye))
    local right = M.normalize(M.cross(forward, up or {0, 1, 0}))
    local vertical = M.cross(right, forward)
    return {
        right[1], vertical[1], -forward[1], 0,
        right[2], vertical[2], -forward[2], 0,
        right[3], vertical[3], -forward[3], 0,
        -M.dot(right, eye), -M.dot(vertical, eye), M.dot(forward, eye), 1,
    }
end

-- Vulkan clip depth is 0..1. Flip Y for a positive-height Vulkan viewport.
function M.perspective(fov, aspect, near, far)
    number(fov); number(aspect); number(near); number(far)
    assert(fov > 0 and fov < math.pi, 'Field of view must be between 0 and pi')
    assert(aspect > 0 and near > 0 and far > near, 'Invalid perspective camera range')
    local factor = 1 / math.tan(fov / 2)
    return {factor / aspect, 0, 0, 0, 0, -factor, 0, 0,
        0, 0, far / (near - far), -1, 0, 0, far * near / (near - far), 0}
end

-- Screen coordinates: (0,0) at top-left, +Y down, +Z into the screen.
function M.orthographic(left, right, top, bottom, near, far)
    number(left); number(right); number(top); number(bottom); number(near); number(far)
    assert(right ~= left and bottom ~= top and far ~= near, 'Invalid orthographic camera range')
    return {2 / (right - left), 0, 0, 0, 0, 2 / (bottom - top), 0, 0,
        0, 0, 1 / (far - near), 0,
        -(right + left) / (right - left), -(bottom + top) / (bottom - top),
        -near / (far - near), 1}
end

function M.clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

function M.lerp(a, b, t)
    return a + (b - a) * t
end

return M
