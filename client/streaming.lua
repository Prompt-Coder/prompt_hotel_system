-- Per-floor IPL streaming for streaming='script' properties (inert for
-- map-streamed ones). Invariant: never more than one floor loaded at a time.
-- RequestIpl/RemoveIpl ONLY -- PinInteriorInMemory/RefreshInterior/probes can
-- mutate the wrong interior mid-stream and hard-crash the game.
local current = nil     -- { propId, floor }

local function scripted(propId)
    local p = CProperties[propId]
    if not p or p.streaming ~= 'script' or not p.layout then return nil end
    return p.layout
end

-- The one property this client is currently near, if any.
local function nearestScripted()
    local pos = GetEntityCoords(PlayerPedId())
    for propId, prop in pairs(CProperties) do
        local L = scripted(propId)
        local z = L and L.zone
        if z and z.center and #(pos.xy - vec2(z.center.x, z.center.y)) < (z.radius or 90.0) then
            return propId, L
        end
    end
end

function GetCurrentHotelFloor()
    return current and current.floor or nil
end

function GetCurrentHotelProperty()
    return current and current.propId or nil
end

-- Read-only readiness poll: wait until the map data at the landing resolves to
-- a valid, ready interior (or time out — the collision wait still follows).
local function waitFloorInterior(coords)
    if not coords then return 0 end
    local deadline = GetGameTimer() + 5000
    while GetGameTimer() < deadline do
        local interior = GetInteriorAtCoords(coords.x, coords.y, coords.z)
        if interior ~= 0 and IsInteriorReady(interior) then return interior end
        Wait(50)
    end
    return 0
end

-- Unloads from the list captured at LOAD time, not a fresh property lookup:
-- if the map already stopped, that lookup returns nil and the IPLs leak forever.
function UnloadHotelFloor()
    if not current then return end
    for _, ipl in ipairs(current.ipls or {}) do RemoveIpl(ipl) end
    current = nil
    LocalPlayer.state:set(KEY('floor'), 0, true)
end

-- Callers must unload the previous floor first (after moving the player away
-- from it); the guard here is a fallback only.
function LoadHotelFloor(propId, floor)
    if current and current.propId == propId and current.floor == floor then return true end
    local L = scripted(propId)
    if not L or not L.ipls or not L.ipls[floor] then return false end
    if current then UnloadHotelFloor() end
    for _, ipl in ipairs(L.ipls[floor]) do RequestIpl(ipl) end
    waitFloorInterior(L.landings and L.landings[floor])
    current = { propId = propId, floor = floor, ipls = L.ipls[floor] }
    LocalPlayer.state:set(KEY('floor'), floor, true)
    TriggerEvent(EV('client:floorLoaded'), propId, floor)
    return true
end

-- FLOOR WATCHER: position-based safety net for reaching floor height WITHOUT
-- the elevator (spawn, admin tp, noclip, fall). Detects the floor from Z,
-- loads it, and freezes the ped until solid; skipped while the elevator runs.
CreateThread(function()
    while true do
        Wait(500)
        if not (HotelElevatorBusy and HotelElevatorBusy()) then
            local propId, L = nearestScripted()
            local target
            if L then
                local ped = PlayerPedId()
                local p = GetEntityCoords(ped)
                local baseZ = L.landings and L.landings[1] and L.landings[1].z
                if baseZ and p.z >= baseZ - 0.7 and p.z <= baseZ + (L.floors - 1) * L.zStep + 3.5 then
                    target = math.floor((p.z - baseZ) / L.zStep + 0.5) + 1
                    if target < 1 then target = 1 elseif target > L.floors then target = L.floors end
                end
            end

            local changed = (target or 0) ~= (current and current.floor or 0)
                or (current and propId ~= current.propId)
            if changed then
                if not target then
                    UnloadHotelFloor()
                else
                    -- Arrived at floor height by external means: hold the ped
                    -- until the floor is genuinely under their feet.
                    local ped = PlayerPedId()
                    local p = GetEntityCoords(ped)
                    FreezeEntityPosition(ped, true)
                    UnloadHotelFloor()
                    LoadHotelFloor(propId, target)
                    local deadline = GetGameTimer() + 4000
                    while GetGameTimer() < deadline do
                        RequestCollisionAtCoord(p.x, p.y, p.z)
                        local interior = GetInteriorAtCoords(p.x, p.y, p.z)
                        if HasCollisionLoadedAroundEntity(ped) and interior ~= 0 and IsInteriorReady(interior) then break end
                        Wait(50)
                    end
                    FreezeEntityPosition(ped, false)
                end
            end
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then UnloadHotelFloor() end
end)

if Config.Debug then
    -- Crash bisect: request a floor's IPLs ONE AT A TIME (400ms apart, each
    -- printed). If the game crashes, the last printed name in CitizenFX_log is
    -- the culprit or its immediate neighbour.
    RegisterCommand(CMD('ipl_test'), function(_, args)
        if not HotelDebugAllowed() then return end
        local propId, floor = args[1], tonumber(args[2])
        local L = propId and scripted(propId)
        local list = L and L.ipls and floor and L.ipls[floor]
        if not list then
            print(('[prompt_hotel_system] usage: /%s <propertyId> <floor> [count]'):format(CMD('ipl_test')))
            return
        end
        local count = math.min(tonumber(args[3]) or #list, #list)
        UnloadHotelFloor()
        CreateThread(function()
            for i = 1, count do
                print(('[ipl_test] %d/%d requesting %s'):format(i, count, list[i]))
                RequestIpl(list[i])
                Wait(400)
            end
            print(('[ipl_test] done — /%s %s %d to clean up'):format(CMD('ipl_clear'), propId, floor))
        end)
    end, false)

    RegisterCommand(CMD('ipl_clear'), function(_, args)
        if not HotelDebugAllowed() then return end
        local propId, floor = args[1], tonumber(args[2])
        local L = propId and scripted(propId)
        local list = L and L.ipls and floor and L.ipls[floor]
        if not list then return end
        for _, ipl in ipairs(list) do RemoveIpl(ipl) end
        print(('[ipl_test] cleared %s floor %d'):format(propId, floor))
    end, false)
end
