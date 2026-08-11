-- Property blips (one per registered property) and the rented-room blip
-- (client-only, and only for the room YOU rent).
local propBlips = {}    -- [propId] = blip
local roomBlips = {}    -- [propId] = blip

-- 475 = "Hotel" in the GTA V blip sprite set. Any property may override it.
local DEFAULT_PROPERTY_SPRITE = 475
local DEFAULT_ROOM_SPRITE     = 475

local function makeBlip(coords, cfg, fallbackLabel, fallbackSprite, shortRange)
    local b = AddBlipForCoord(coords.x, coords.y, coords.z)
    SetBlipSprite(b, (cfg and cfg.sprite) or fallbackSprite)
    SetBlipColour(b, (cfg and cfg.color) or 4)
    SetBlipScale(b, (cfg and cfg.scale) or 0.8)
    SetBlipAsShortRange(b, cfg and cfg.shortRange ~= nil and cfg.shortRange or shortRange)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName((cfg and cfg.label) or fallbackLabel)
    EndTextCommandSetBlipName(b)
    return b
end

local function clear(t)
    for k, b in pairs(t) do
        if DoesBlipExist(b) then RemoveBlip(b) end
        t[k] = nil
    end
end

local function rebuildPropertyBlips()
    clear(propBlips)
    for propId, prop in pairs(CProperties) do
        if prop.blip ~= false then
            local c = (prop.blip and prop.blip.coords) or (prop.reception and prop.reception.coords)
            -- a property whose reception spot has not been captured yet gets no blip
            if c and not (c.x == 0.0 and c.y == 0.0) then
                propBlips[propId] = makeBlip(c, prop.blip, prop.label, DEFAULT_PROPERTY_SPRITE, true)
            end
        end
    end
end

local function rebuildRoomBlips()
    clear(roomBlips)
    for propId, mine in pairs(MyRooms) do
        local room = CRooms[mine.roomId]
        local prop = CProperties[propId]
        if room and prop and prop.rentedBlip ~= false then
            local label = (prop.rentedBlip and prop.rentedBlip.label) or L('room_blip')
            roomBlips[propId] = makeBlip(room.door, prop.rentedBlip,
                ('%s %s'):format(label, room.num or ''), DEFAULT_ROOM_SPRITE, false)
        end
    end
end

AddEventHandler(EV('client:registryChanged'), function()
    rebuildPropertyBlips()
    rebuildRoomBlips()
end)

AddEventHandler(EV('client:accessChanged'), rebuildRoomBlips)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clear(propBlips)
    clear(roomBlips)
end)
