-- Teleport elevators. A property registers one or more shafts; each shaft has
-- fixed stops (lobby, bar, roof, …) plus an optional generated stop per floor.
-- Order matters end to end: fade -> freeze -> hop to lobby if mid-floor (never
-- RemoveIpl an occupied MLO) -> swap floor -> teleport -> wait solid -> fade in.
local FADE_MS  = 500
local HOLD_MS  = 400

local busy = false
local menuOpen = false
local active = nil          -- { propId, shaftId }
local zones = {}

function HotelElevatorBusy() return busy end

local function shaftOf(propId, shaftId)
    local prop = CProperties[propId]
    for _, s in ipairs((prop and prop.elevators) or {}) do
        if s.id == shaftId then return s end
    end
end

local function destPoint(propId, shaftId, dest)
    local s = shaftOf(propId, shaftId)
    if not s then return nil end
    if type(dest) == 'string' then
        for _, stop in ipairs(s.stops or {}) do
            if stop.id == dest then return stop.coords end
        end
        return nil
    end
    local L = CProperties[propId] and CProperties[propId].layout
    if not s.floors or not L or not L.ipls or not L.ipls[dest] then return nil end
    local b = s.floors.base
    return vec4(b.x, b.y, b.z + (dest - 1) * L.zStep, b.w)
end

local function waitSolid(ped, point)
    RequestCollisionAtCoord(point.x, point.y, point.z)
    local deadline = GetGameTimer() + 6000
    while GetGameTimer() < deadline do
        RequestCollisionAtCoord(point.x, point.y, point.z)
        local interior = GetInteriorAtCoords(point.x, point.y, point.z)
        if HasCollisionLoadedAroundEntity(ped) and interior ~= 0 and IsInteriorReady(interior) then break end
        Wait(25)
    end
    Wait(300)   -- the collision flag can lead actual solid physics by a few frames
end

function TeleportToHotelFloor(propId, shaftId, dest)
    if busy then return end
    local point = destPoint(propId, shaftId, dest)
    if not point then return end

    busy = true
    local ped = PlayerPedId()
    local targetFloor = type(dest) == 'number' and dest or nil

    DoScreenFadeOut(FADE_MS)
    while not IsScreenFadedOut() do Wait(10) end
    FreezeEntityPosition(ped, true)

    -- Never RemoveIpl the floor the player is standing in.
    if GetCurrentHotelFloor() then
        local hold = destPoint(propId, shaftId, 'lobby')
        if hold then
            SetEntityCoords(ped, hold.x, hold.y, hold.z, false, false, false, false)
            Wait(200)
        end
    end

    UnloadHotelFloor()
    if targetFloor then
        Wait(300)   -- let the streamer finish tearing down before loading the new floor
        LoadHotelFloor(propId, targetFloor)
    end

    SetEntityCoords(ped, point.x, point.y, point.z, false, false, false, false)
    SetEntityHeading(ped, point.w)

    if targetFloor then
        waitSolid(ped, point)
    else
        RequestCollisionAtCoord(point.x, point.y, point.z)
        Wait(200)   -- lobby/bar/roof are base map, always solid
    end

    FreezeEntityPosition(ped, false)

    -- fall guard: if the floor still is not solid, snap back up once
    CreateThread(function()
        local guard = GetGameTimer() + 2000
        while GetGameTimer() < guard do
            Wait(100)
            if not DoesEntityExist(ped) then return end
            if GetEntityCoords(ped).z < point.z - 3.0 then
                FreezeEntityPosition(ped, true)
                SetEntityCoords(ped, point.x, point.y, point.z, false, false, false, false)
                waitSolid(ped, point)
                FreezeEntityPosition(ped, false)
                return
            end
        end
    end)

    Wait(HOLD_MS)
    DoScreenFadeIn(FADE_MS)
    busy = false
end

-- ── the menu ─────────────────────────────────────────────────────────────
local function buildStops(propId, shaftId, origin)
    local prop = CProperties[propId]
    local s = shaftOf(propId, shaftId)
    local mine = MyRooms[propId]
    local out = {}

    for _, stop in ipairs((s and s.stops) or {}) do
        out[#out + 1] = {
            id = stop.id, label = stop.label, sub = stop.sub, badge = stop.badge,
            current = stop.id == origin, mine = false,
        }
    end

    local L = prop and prop.layout
    if s and s.floors and L then
        for f = 1, L.floors do
            local isMine = mine ~= nil and mine.floor == f
            out[#out + 1] = {
                id = tostring(f),
                label = (s.floors.label or 'Floor %d'):format(f),
                sub = isMine and ('Your room %s'):format(mine.num) or nil,
                badge = tostring(f),
                current = origin == f,
                mine = isMine,
            }
        end
    end
    return out, mine
end

local function openMenu(propId, shaftId, origin)
    if menuOpen or busy then return end
    local stops, mine = buildStops(propId, shaftId, origin)
    if #stops == 0 then return end

    local hereLabel = 'Elevator'
    for _, s in ipairs(stops) do
        if s.current then hereLabel = s.label end
    end

    if TargetBackend() == 'fallback' and not CProperties[propId].elevatorNui then
        -- ox_lib fallback menu, for servers without the NUI page
        local options = {}
        for _, s in ipairs(stops) do
            if not s.current then
                options[#options + 1] = {
                    title = s.label, description = s.sub,
                    onSelect = function()
                        TeleportToHotelFloor(propId, shaftId, tonumber(s.id) or s.id)
                    end,
                }
            end
        end
        lib.registerContext({ id = RID('elevator'), title = L('use_elevator'), options = options })
        lib.showContext(RID('elevator'))
        return
    end

    menuOpen = true
    active = { propId = propId, shaftId = shaftId }
    SetNuiFocus(true, true)
    SendNUIMessage({
        action = 'open',
        stops = stops,
        hereLabel = hereLabel,
        room = mine and mine.num or nil,
    })
end

RegisterNUICallback('select', function(data, cb)
    cb({})
    menuOpen = false
    SetNuiFocus(false, false)
    local id = data and data.id
    if not id or not active then return end
    local a = active
    -- Must run in its own thread: TeleportToHotelFloor yields (fades, stream
    -- waits) and an NUI callback cannot yield across the C-call boundary.
    CreateThread(function()
        TeleportToHotelFloor(a.propId, a.shaftId, tonumber(id) or id)
    end)
end)

RegisterNUICallback('close', function(_, cb)
    cb({})
    menuOpen = false
    SetNuiFocus(false, false)
end)

-- ── walk-in zones ([E] prompt) ───────────────────────────────────────────
local function addZone(box, propId, shaftId, origin, available)
    zones[#zones + 1] = lib.zones.box({
        coords = box.center, size = box.size, rotation = box.rotation or 0.0,
        inside = function()
            if menuOpen or busy then return end
            if available and not available() then return end
            lib.showTextUI(('[E]  %s'):format(L('use_elevator')), { position = 'left-center' })
            if IsControlJustPressed(0, 38) then
                lib.hideTextUI()
                openMenu(propId, shaftId, origin)
            end
        end,
        onExit = function() lib.hideTextUI() end,
    })
end

local function teardown()
    for _, z in ipairs(zones) do z:remove() end
    zones = {}
end

local function build()
    teardown()
    for propId, prop in pairs(CProperties) do
        for _, s in ipairs(prop.elevators or {}) do
            for _, stop in ipairs(s.stops or {}) do
                if stop.zone then addZone(stop.zone, propId, s.id, stop.id) end
            end
            local L = prop.layout
            if s.floors and s.floors.zone and L then
                local fz = s.floors.zone
                for f = 1, L.floors do
                    local z = s.floors.base.z + (f - 1) * L.zStep + 1.0
                    addZone({
                        center = vec3(fz.center.x, fz.center.y, z),
                        size = fz.size, rotation = fz.rotation,
                    }, propId, s.id, f, function() return GetCurrentHotelFloor() == f end)
                end
            end
        end
    end
end

AddEventHandler(EV('client:registryChanged'), build)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    teardown()
    if menuOpen then SetNuiFocus(false, false) end
end)

if Config.Debug then
    -- /<prefix>_floor <propertyId> <shaft> <floor|stopId>
    RegisterCommand(CMD('floor'), function(_, args)
        if not HotelDebugAllowed() then return end
        local propId, shaftId, arg = args[1], args[2], args[3]
        if not propId or not shaftId or not arg then
            print(('[prompt_hotel_system] usage: /%s <propertyId> <shaftId> <floor|lobby|bar|roof>'):format(CMD('floor')))
            return
        end
        TeleportToHotelFloor(propId, shaftId, tonumber(arg) or arg)
    end, false)

    RegisterCommand(CMD('here'), function()
        if not HotelDebugAllowed() then return end
        local ped = PlayerPedId()
        local p = GetEntityCoords(ped)
        local msg = ('here = vec4(%.3f, %.3f, %.3f, %.1f)'):format(p.x, p.y, p.z, GetEntityHeading(ped))
        print(msg)
        TriggerEvent('chat:addMessage', { color = { 120, 200, 255 }, args = { Config.CommandPrefix or 'hotel', msg } })
    end, false)
end
