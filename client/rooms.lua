-- Rooms: doors, proximity activation, and in-room amenities.
-- One lib.points per room keeps target zones to nearby rooms, not all 200 at
-- once -- same code path whether the property streams as a map or a script.
local DEFAULT_DOOR_MODEL = `ex_p_mp_door_apart_door_black`

local doorZones = {}    -- [roomId] = zoneId
local amenZones = {}    -- [roomId] = { zoneId, ... }
local points    = {}    -- [roomId] = lib.points object
local registered = {}   -- [roomId] = true   (added to the door system)

local function doorHash(roomId) return joaat(RID(roomId)) end

local function isLocked(roomId)
    local doors = GlobalState[KEY('doors')]
    return not doors or doors[roomId] ~= false
end

local function applyLocked(roomId, locked)
    local h = doorHash(roomId)
    if locked then
        DoorSystemSetDoorState(h, 4, false, false)   -- slam shut
        DoorSystemSetDoorState(h, 1, false, false)   -- locked
    else
        DoorSystemSetDoorState(h, 0, false, false)   -- unlocked
    end
end

function HotelApplyDoorState(roomId)
    applyLocked(roomId, isLocked(roomId))
end

-- ── amenities ────────────────────────────────────────────────────────────
local function doShower(room, variant)
    local ped = PlayerPedId()
    local female = GetEntityModel(ped) == `mp_f_freemode_01`
    local dict = female and 'mp_safehouseshower@female@' or 'mp_safehouseshower@male@'
    local anim = female and 'shower_idle_a' or 'male_shower_idle_a'

    RequestAnimDict(dict)
    local tries = 0
    while not HasAnimDictLoaded(dict) and tries < 50 do Wait(100); tries = tries + 1 end
    if HasAnimDictLoaded(dict) then
        TaskPlayAnim(ped, dict, anim, 4.0, -4.0, -1, 1, 0.0, false, false, false)
    end

    -- running water, only where a shower head point exists (tubs have none)
    local S = Config.Shower
    local fx, pouring = nil, false
    local head = variant.amenities and variant.amenities.showerHead
    if head then
        local w = Util.RotateOffset(room.origin, head)
        RequestNamedPtfxAsset(S.ptfxAsset)
        tries = 0
        while not HasNamedPtfxAssetLoaded(S.ptfxAsset) and tries < 30 do Wait(100); tries = tries + 1 end
        if HasNamedPtfxAssetLoaded(S.ptfxAsset) then
            if S.ptfxRepeat then
                -- burst effect: re-fire it until the shower ends
                pouring = true
                CreateThread(function()
                    while pouring do
                        UseParticleFxAsset(S.ptfxAsset)
                        StartParticleFxNonLoopedAtCoord(S.ptfxName,
                            w.x, w.y, w.z, 0.0, 0.0, 0.0, S.ptfxScale, false, false, false)
                        Wait(S.ptfxRepeat)
                    end
                end)
            else
                UseParticleFxAsset(S.ptfxAsset)
                fx = StartParticleFxLoopedAtCoord(S.ptfxName,
                    w.x, w.y, w.z, 0.0, 0.0, 0.0, S.ptfxScale, false, false, false, false)
            end
        end
    end

    local ok = lib.progressBar({
        duration = Config.Shower.duration,
        label = head and L('use_shower') or L('use_bath'),
        useWhileDead = false, canCancel = true,
        disable = { move = true, car = true, combat = true },
    })

    pouring = false
    if fx then StopParticleFxLooped(fx, false) end
    ClearPedTasks(ped)
    RemoveAnimDict(dict)
    if ok and GetResourceState('qb-hud') == 'started' then
        TriggerServerEvent('hud:server:RelieveStress', Config.Shower.stressRelief)
    end
end

local function activateAmenities(roomId, room)
    if amenZones[roomId] then return end
    local variant = HotelRoomVariant(room)
    if not variant then return end
    local a = variant.amenities
    if not a then return end

    local ids = {}
    local stashEnabled = GlobalState[KEY('stash_enabled')] == true

    local function zone(kind, off, label, icon, onSelect)
        if not off then return end
        local id = RID(('%s_%s'):format(kind, roomId))
        ids[#ids + 1] = id
        TargetAddBoxZone(id, Util.RotateOffset(room.origin, off), vec3(1.4, 1.4, 2.0), room.origin.w, {{
            label = label, icon = icon,
            canInteract = function() return HotelAccess[roomId] == true end,
            onSelect = onSelect,
        }})
    end

    if stashEnabled then
        zone('stash', a.stash, L('open_stash'), 'fa-solid fa-box-open', function()
            TriggerServerEvent(EV('server:openStash'), roomId)
        end)
    end
    if Config.EnableWardrobe and Appearance.Available() then
        zone('wardrobe', a.wardrobe, L('use_wardrobe'), 'fa-solid fa-shirt', Appearance.OpenWardrobe)
    end
    if Config.EnableShower then
        zone('shower', a.shower, a.showerHead and L('use_shower') or L('use_bath'),
            'fa-solid fa-shower', function() doShower(room, variant) end)
    end

    amenZones[roomId] = ids
end

local function deactivateAmenities(roomId)
    local ids = amenZones[roomId]
    if not ids then return end
    for _, id in ipairs(ids) do TargetRemoveZone(id) end
    amenZones[roomId] = nil
end

-- ── door zone ────────────────────────────────────────────────────────────
local function activateDoor(roomId, room)
    if doorZones[roomId] then return end
    local id = RID('door_' .. roomId)
    doorZones[roomId] = id
    applyLocked(roomId, isLocked(roomId))
    TargetAddBoxZone(id, room.door, vec3(1.6, 1.6, 2.4), room.origin.w, {{
        label = L('lock_toggle'), icon = 'fa-solid fa-key',
        canInteract = function() return HotelAccess[roomId] == true end,
        onSelect = function() TriggerServerEvent(EV('server:toggleDoor'), roomId) end,
    }})
end

local function deactivateDoor(roomId)
    local id = doorZones[roomId]
    if not id then return end
    TargetRemoveZone(id)
    doorZones[roomId] = nil
end

-- ── lifecycle ────────────────────────────────────────────────────────────
local function teardown()
    for roomId in pairs(doorZones) do deactivateDoor(roomId) end
    for roomId in pairs(amenZones) do deactivateAmenities(roomId) end
    for _, p in pairs(points) do p:remove() end
    points = {}
end

local function build()
    teardown()
    for roomId, room in pairs(CRooms) do
        -- AddDoorToSystem works before the door streams in, so this latches on
        -- the RESOLVED model, not "seen once" -- else a late-resolving room stays unlockable.
        local variant = HotelRoomVariant(room)
        local model = (variant and variant.doorModel and joaat(variant.doorModel)) or DEFAULT_DOOR_MODEL
        if registered[roomId] ~= model then
            AddDoorToSystem(doorHash(roomId), model, room.door.x, room.door.y, room.door.z, false, false, false)
            registered[roomId] = model
        end
        applyLocked(roomId, isLocked(roomId))

        points[roomId] = lib.points.new({
            coords = vec3(room.origin.x, room.origin.y, room.origin.z),
            distance = Config.RoomActivationRadius,
            onEnter = function()
                activateDoor(roomId, room)
                activateAmenities(roomId, room)
                TriggerServerEvent(EV('server:roomEntered'), roomId)
            end,
            onExit = function()
                deactivateDoor(roomId)
                deactivateAmenities(roomId)
            end,
        })
    end
end

AddEventHandler(EV('client:registryChanged'), build)

-- Clients act on the BROADCAST value: GlobalState has not replicated yet here.
RegisterNetEvent(EV('client:doorState'), function(roomId, locked)
    if doorZones[roomId] then applyLocked(roomId, locked == true) end
end)

-- A script-streamed floor re-asserts its locks once its IPLs exist: GTA only applies a lock after the door's physics load.
AddEventHandler(EV('client:floorLoaded'), function(propId, floor)
    SetTimeout(600, function()
        for roomId, room in pairs(CRooms) do
            if room.propId == propId and room.floor == floor then
                applyLocked(roomId, isLocked(roomId))
            end
        end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    teardown()
    lib.hideTextUI()
end)
