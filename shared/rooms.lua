-- Room expansion, shared by client and server rather than sent from the
-- server: a property already carries rooms/layout/variants, so sending
-- the expanded rooms too would double the wire cost (~300KB/client across
-- three maps) and risk room IDs drifting apart between client and server.

-- Two numbering conventions: layout.slots carry a slot INDEX, so the
-- displayed number is floor*100 + slot (slot 3 on floor 1 -> room 103).
-- rooms[].num IS the displayed number, exactly as the map author wrote it.
local function variantType(prop, variant)
    for _, t in ipairs(prop.roomTypes) do
        if not t.variants then return t.id end            -- single-type property
        for _, v in ipairs(t.variants) do
            if v == variant then return t.id end
        end
    end
end

local function addRoom(out, propId, prop, localId, data, warn)
    local roomId = ('%s:%s'):format(propId, localId)
    local v = prop.variants[data.variant]
    if not v then
        if warn then warn(("room '%s' uses unknown variant '%s' — skipped"):format(roomId, tostring(data.variant))) end
        return
    end
    local rtype = variantType(prop, data.variant)
    if not rtype then
        if warn then warn(("room '%s' variant '%s' is not sold by any roomType — skipped")
            :format(roomId, tostring(data.variant))) end
        return
    end
    out[roomId] = {
        propId  = propId,
        floor   = data.floor,
        slot    = data.slot,
        num     = data.num,
        variant = data.variant,
        rtype   = rtype,
        origin  = data.origin,
        door    = Util.RotateOffset(data.origin, v.door),
        probe   = Util.RoomProbe(data.origin, v),
        ipl     = data.ipl,
    }
end

-- Returns { [roomId] = room }. `warn` is optional.
function RoomsExpand(propId, prop, warn)
    local out = {}
    local L = prop.layout

    if L and L.mode == 'floors' then
        for floor = 1, L.floors do
            local dz = (floor - 1) * L.zStep
            for _, slot in ipairs(L.slots) do
                addRoom(out, propId, prop, ('f%02d_r%02d'):format(floor, slot.slot), {
                    floor   = floor,
                    slot    = slot.slot,
                    num     = floor * 100 + slot.slot,
                    variant = slot.variant or prop.variant,
                    origin  = vec4(slot.origin.x, slot.origin.y, slot.origin.z + dz, slot.origin.w),
                    ipl     = L.ipls and L.ipls[floor] or nil,
                }, warn)
            end
        end
    end

    for _, r in ipairs(prop.rooms or {}) do
        local floor = r.floor or 1
        addRoom(out, propId, prop, ('f%02d_r%s'):format(floor, tostring(r.num)), {
            floor   = floor,
            slot    = r.num,
            num     = r.num,
            variant = r.variant or prop.variant,
            origin  = r.origin,
            ipl     = r.ipl,
        }, warn)
    end

    return out
end
