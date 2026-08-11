-- Point capture for map authors.
--
-- Amenity points in a property config are ROOM-LOCAL offsets, so a world coordinate
-- (what /<prefix>_here gives you) can't be pasted in directly. This aims a ray,
-- converts the hit to the room's local space, and prints it ready to paste.
--
--   /<prefix>_place      menu -> pick a point kind -> aim, [E] saves, [X] cancels
--   /<prefix>_setpoint   no menu: just print where you are standing

if not Config.Debug then return end

local KINDS = { 'stash', 'wardrobe', 'shower', 'showerHead' }

local captured = {}     -- [variant][kind] = vec3, this session only
local placing  = nil

local function announce(msg)
    print(('[prompt_hotel_system] %s'):format(msg))
    TriggerEvent('chat:addMessage',
        { color = { 120, 200, 255 }, args = { Config.CommandPrefix or 'hotel', msg } })
end

-- Interior match first, but room origins sit at room corners so nearest-origin
-- alone often picks the neighbour. Interior match needs the room streamed AND
-- the ped inside it, so this falls back to plain proximity rather than refusing.
local function currentRoom()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local interior = GetInteriorFromEntity(ped)

    if interior ~= 0 then
        for roomId, room in pairs(CRooms) do
            if #(pos - vec3(room.origin.x, room.origin.y, room.origin.z)) < 30.0 then
                local variant = HotelRoomVariant(room)
                if variant then
                    local p = Util.RoomProbe(room.origin, variant)
                    if GetInteriorAtCoords(p.x, p.y, p.z) == interior then
                        return room, roomId, variant, 'interior'
                    end
                end
            end
        end
    end

    local best, bestId, bestVar, bestD = nil, nil, nil, 10.0
    for roomId, room in pairs(CRooms) do
        local variant = HotelRoomVariant(room)
        if variant then
            local d = #(pos - Util.RoomProbe(room.origin, variant))
            if d < bestD then best, bestId, bestVar, bestD = room, roomId, variant, d end
        end
    end
    if best then return best, bestId, bestVar, ('nearest, %.1fm'):format(bestD) end
    return nil
end

-- Never fail silently: say which gate stopped us.
local function blocked()
    if not HotelDebugAllowed() then
        if Util.Count(CRooms) == 0 then
            announce('no rooms known yet — is a hotel map running? (try again in a few seconds)')
        end
        -- the ace only gates the teleports; capture is read-only, so carry on
    end
    if Util.Count(CRooms) == 0 then
        announce('no rooms loaded — the engine has not received any property yet')
        return true
    end
    return false
end

-- inverse of Util.RotateOffset
local function toLocal(room, world)
    local rad = math.rad(-room.origin.w)
    local c, s = math.cos(rad), math.sin(rad)
    local dx, dy = world.x - room.origin.x, world.y - room.origin.y
    return vec3(dx * c - dy * s, dx * s + dy * c, world.z - room.origin.z)
end

local function rotationToDirection(rot)
    local z, x = math.rad(rot.z), math.rad(rot.x)
    local num = math.abs(math.cos(x))
    return vec3(-math.sin(z) * num, math.cos(z) * num, math.sin(x))
end

RegisterCommand(CMD('setpoint'), function()
    if blocked() then return end
    local room, _, _, how = currentRoom()
    if not room then
        announce(('setpoint: no room within 10m (you are at interior %d, %d rooms known)')
            :format(GetInteriorFromEntity(PlayerPedId()), Util.Count(CRooms)))
        return
    end
    local off = toLocal(room, GetEntityCoords(PlayerPedId()))
    announce(('%s = vec3(%.3f, %.3f, %.3f)   [%s]'):format(room.variant, off.x, off.y, off.z, how))
end, false)

RegisterCommand(CMD('place'), function()
    if blocked() then return end
    local room, roomId, variant, how = currentRoom()
    if not room then
        announce(('place: no room within 10m (you are at interior %d, %d rooms known)')
            :format(GetInteriorFromEntity(PlayerPedId()), Util.Count(CRooms)))
        return
    end
    announce(('matched %s (%s) by %s'):format(roomId, room.variant, how))

    local options = {}
    for _, kind in ipairs(KINDS) do
        local have = captured[room.variant] and captured[room.variant][kind]
        local cfg = variant.amenities and variant.amenities[kind]
        options[#options + 1] = {
            title = ('Place %s'):format(kind),
            description = have and ('captured: %.3f, %.3f, %.3f'):format(have.x, have.y, have.z)
                or (cfg and ('in config: %.3f, %.3f, %.3f'):format(cfg.x, cfg.y, cfg.z) or 'not set'),
            icon = 'location-dot',
            onSelect = function() placing = { kind = kind } end,
        }
    end
    options[#options + 1] = {
        title = 'Dump all captured offsets',
        icon = 'clipboard',
        onSelect = function()
            local any = false
            for v, kinds in pairs(captured) do
                for kind, off in pairs(kinds) do
                    any = true
                    announce(('%s %s = vec3(%.3f, %.3f, %.3f)'):format(v, kind, off.x, off.y, off.z))
                end
            end
            if not any then announce('nothing captured yet') end
        end,
    }

    lib.registerContext({
        id = RID('place'),
        title = ('You are in: %s (%s)'):format(room.variant, roomId),
        options = options,
    })
    lib.showContext(RID('place'))
end, false)

CreateThread(function()
    while true do
        if placing then
            local room = currentRoom()
            if not room then
                placing = nil
                lib.hideTextUI()
            else
                local camPos = GetGameplayCamCoord()
                local dest = camPos + rotationToDirection(GetGameplayCamRot(2)) * 10.0
                local ray = StartExpensiveSynchronousShapeTestLosProbe(
                    camPos.x, camPos.y, camPos.z, dest.x, dest.y, dest.z, -1, PlayerPedId(), 4)
                local _, hit, endCoords = GetShapeTestResult(ray)
                if hit == 1 or hit == true then
                    DrawMarker(28, endCoords.x, endCoords.y, endCoords.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        0.15, 0.15, 0.15, 80, 200, 120, 180, false, false, 2, false, nil, nil, false)
                    lib.showTextUI(('[E] save %s (%s)  |  [X] cancel'):format(placing.kind, room.variant))
                    if IsControlJustPressed(0, 38) then
                        local off = toLocal(room, endCoords)
                        captured[room.variant] = captured[room.variant] or {}
                        captured[room.variant][placing.kind] = off
                        announce(('%s %s = vec3(%.3f, %.3f, %.3f)')
                            :format(room.variant, placing.kind, off.x, off.y, off.z))
                        placing = nil
                        lib.hideTextUI()
                    elseif IsControlJustPressed(0, 73) then
                        placing = nil
                        lib.hideTextUI()
                    end
                else
                    lib.showTextUI('aim at a surface...')
                end
            end
            Wait(0)
        else
            Wait(250)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then lib.hideTextUI() end
end)
