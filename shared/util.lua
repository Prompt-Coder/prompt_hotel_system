Util = {}

-- Rotate a room-local offset into world space using the room origin's heading.
function Util.RotateOffset(origin, off)
    local rad = math.rad(origin.w)
    local c, s = math.cos(rad), math.sin(rad)
    return vec3(origin.x + off.x * c - off.y * s, origin.y + off.x * s + off.y * c, origin.z + off.z)
end

-- A point guaranteed to be inside the room: in from the door, up off the floor.
-- Used to resolve which interior a room belongs to without guessing by distance
-- (origins sit at corners, so nearest-origin picks the wrong room).
function Util.RoomProbe(origin, variant)
    local d = variant.door
    local inward = variant.probeInward or 1.2
    return Util.RotateOffset(origin, vec3(d.x, d.y + inward, d.z + 1.0))
end

function Util.Count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
