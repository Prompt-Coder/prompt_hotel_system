-- Hotel bar: a bartender ped per registered spawn point, one target option per
-- drink, and the casino's synced pour sequence plus GTA drunk effects.
-- Timings below are load-bearing, not decorative -- every Wait() is measured
-- against the anim lengths; attach early and the props float or vanish.
local peds  = {}    -- [barKey] = ped
local props = {}    -- [barKey] = { drink = ent, glass = ent }
local spots = {}    -- lib.points
local busyLocal = false

local function barKey(propId, index) return ('%s#%d'):format(propId, index) end

-- ── drunk fx ─────────────────────────────────────────────────────────────
local MAX_DRUNK = 5.0
local CLIPSET   = 'move_m@drunk@verydrunk'
local POSTFX    = 'DrunkBeerStrong'
local drunkLevel, drunkWalk, decayRunning = 0.0, false, false

local function stopDrunk()
    ClearTimecycleModifier()
    StopGameplayCamShaking(true)
    AnimpostfxStop(POSTFX)
    if drunkWalk then
        ResetPedMovementClipset(PlayerPedId(), 0.0)
        SetPedConfigFlag(PlayerPedId(), 100, false)
        drunkWalk = false
    end
end

local function applyDrunk(level)
    SetTimecycleModifier('Drunk')
    SetTimecycleModifierStrength(math.min((level / MAX_DRUNK) * 2.0, 1.0))
    if level >= 3.5 then
        ShakeGameplayCam('DRUNK_SHAKE', 0.45)
        AnimpostfxPlay(POSTFX, 0, true)
        if not drunkWalk then
            RequestAnimSet(CLIPSET)
            local t = 0
            while not HasAnimSetLoaded(CLIPSET) and t < 30 do Wait(50); t = t + 1 end
            if HasAnimSetLoaded(CLIPSET) then
                SetPedMovementClipset(PlayerPedId(), CLIPSET, 1.0)
                SetPedConfigFlag(PlayerPedId(), 100, true)
                drunkWalk = true
            end
        end
    elseif level >= 2.5 then
        ShakeGameplayCam('DRUNK_SHAKE', 0.25)
        AnimpostfxPlay(POSTFX, 0, true)
    elseif level >= 1.5 then
        ShakeGameplayCam('DRUNK_SHAKE', 0.1)
        AnimpostfxStop(POSTFX)
    elseif level >= 0.5 then
        StopGameplayCamShaking(true)
        AnimpostfxStop(POSTFX)
    else
        stopDrunk()
    end
end

local function addDrunk(amount)
    drunkLevel = math.min(MAX_DRUNK, drunkLevel + (amount or 1.0))
    applyDrunk(drunkLevel)
    if decayRunning then return end
    decayRunning = true
    CreateThread(function()
        while drunkLevel > 0.0 do
            Wait(3000)
            drunkLevel = math.max(0.0, drunkLevel - 0.025)
            applyDrunk(drunkLevel)
        end
        decayRunning = false
        stopDrunk()
    end)
end

-- ── pour sequence ────────────────────────────────────────────────────────
local ANIM = {
    intro = { dict = 'anim@amb@casino@mini@drinking@bar@drink_v2@heels@base',
              ped = 'intro_bartender', drink = 'intro_whiskey', glass = 'intro_shot_glass' },
    pour  = { dict = 'anim@amb@casino@mini@drinking@bar@drink@heels@one',
              ped = 'one_bartender', player = 'one_player', drink = 'one_whiskey', glass = 'one_shot_glass' },
    outro = { dict = 'anim@amb@casino@mini@drinking@bar@drink_v2@heels@base',
              ped = 'outro_bartender', drink = 'outro_whiskey', glass = 'outro_shot_glass' },
}
local BONE_HAND, BONE_GRIP = 28422, 60309

-- Detach and leave the prop exactly where it is (the casino's
-- detachAndSaveCurrentPosition). onlyHeading keeps pitch and roll flat.
local function parkProp(ent, dz, onlyHeading)
    if not DoesEntityExist(ent) then return end
    local c = GetEntityCoords(ent)
    local rot = onlyHeading and vec3(0.0, 0.0, GetEntityHeading(ent)) or GetEntityRotation(ent)
    DetachEntity(ent, true, true)
    SetEntityCoords(ent, c.x, c.y, c.z + (dz or 0.0), false, false, false, true)
    SetEntityRotation(ent, rot.x, rot.y, rot.z, 2, true)
    FreezeEntityPosition(ent, true)
end

local function cleanupProps(key)
    local p = props[key]
    if not p then return end
    if p.drink and DoesEntityExist(p.drink) then DeleteEntity(p.drink) end
    if p.glass and DoesEntityExist(p.glass) then DeleteEntity(p.glass) end
    props[key] = nil
end

RegisterNetEvent(EV('client:barDrink'), function(data)
    local key = barKey(data.propId, data.bar)
    local ped = peds[key]
    if not ped or not DoesEntityExist(ped) then return end

    local prop = CProperties[data.propId]
    local idle = (prop and prop.bar and prop.bar.idleAnim) or Config.Bar.idleAnim
    local isLocal = GetPlayerServerId(PlayerId()) == data.target
    local targetPed = GetPlayerPed(GetPlayerFromServerId(data.target))

    for _, a in pairs(ANIM) do RequestAnimDict(a.dict) end
    local t = 0
    while (not HasAnimDictLoaded(ANIM.intro.dict) or not HasAnimDictLoaded(ANIM.pour.dict)) and t < 60 do
        Wait(50); t = t + 1
    end
    RequestModel(data.model); RequestModel(data.glass)
    t = 0
    while (not HasModelLoaded(data.model) or not HasModelLoaded(data.glass)) and t < 60 do Wait(50); t = t + 1 end
    if not HasModelLoaded(data.model) or not HasModelLoaded(data.glass) then
        if isLocal then
            FreezeEntityPosition(PlayerPedId(), false)
            busyLocal = false
            TriggerServerEvent(EV('server:barFree'))
        end
        return
    end

    cleanupProps(key)
    -- the casino creates these networked (true, true, true)
    local bottle = CreateObject(data.model, 0.0, 0.0, 0.0, true, true, true)
    local glass  = CreateObject(data.glass, 0.0, 0.0, 0.0, true, true, true)
    props[key] = { drink = bottle, glass = glass }
    SetModelAsNoLongerNeeded(data.model); SetModelAsNoLongerNeeded(data.glass)

    TaskPlayAnim(ped, ANIM.intro.dict, ANIM.intro.ped, 3.0, 3.0, -1, 1, 0.0, false, false, false)

    -- The props only go into the bartender's hands 2.8s in (he reaches for
    -- them); attaching at t=0 is what made them float and jump.
    SetTimeout(2800, function()
        if DoesEntityExist(bottle) and DoesEntityExist(ped) then
            AttachEntityToEntity(bottle, ped, GetPedBoneIndex(ped, BONE_HAND), 0.0,0.0,0.0, 0.0,0.0,0.0, true, true, false, true, 1, true)
        end
        if DoesEntityExist(glass) and DoesEntityExist(ped) then
            AttachEntityToEntity(glass, ped, GetPedBoneIndex(ped, BONE_GRIP), 0.0,0.0,0.0, 0.0,0.0,0.0, true, true, false, true, 1, true)
        end
    end)

    PlayEntityAnim(bottle, ANIM.intro.drink, ANIM.intro.dict, 1000.0, false, true, false, 0.0, 0.0)
    PlayEntityAnim(glass, ANIM.intro.glass, ANIM.intro.dict, 1000.0, false, true, false, 0.0, 0.0)

    Wait(GetAnimDuration(ANIM.intro.dict, ANIM.intro.ped) * 1000 - 1100)

    parkProp(bottle, -0.02); parkProp(glass, 0.05)
    TaskPlayAnim(ped, ANIM.pour.dict, ANIM.pour.ped, 3.0, 3.0, -1, 0, 0.0, false, false, false)
    PlayEntityAnim(bottle, ANIM.pour.drink, ANIM.pour.dict, 1000.0, false, true, false, 0.0, 0.0)
    PlayEntityAnim(glass, ANIM.pour.glass, ANIM.pour.dict, 1000.0, false, true, false, 0.0, 0.0)
    if isLocal then
        TaskPlayAnim(PlayerPedId(), ANIM.pour.dict, ANIM.pour.player, 1.0, 1.0, -1, 0, 0.0, false, false, false)
    end

    Wait(1000)
    -- glass into the customer's hand
    if DoesEntityExist(glass) and DoesEntityExist(targetPed) then
        AttachEntityToEntity(glass, targetPed, GetPedBoneIndex(targetPed, BONE_HAND),
            0.0,0.0,0.0, 0.0,0.0,0.0, true, true, false, true, 1, true)
    end
    Wait(800)
    -- bottle re-seated in the bartender's grip (the one offset attach in the sequence)
    if DoesEntityExist(bottle) and DoesEntityExist(ped) then
        AttachEntityToEntity(bottle, ped, GetPedBoneIndex(ped, BONE_HAND),
            0.235, -0.08, -0.14, 78.0, -7.0, 34.5, false, false, false, false, 0, true)
    end
    Wait(1800)
    parkProp(bottle, -0.02, true)   -- heading only, as the casino does here

    Wait(3000)
    if isLocal then addDrunk(data.intoxication) end
    Wait(3400)                      -- 9000 - 1800 - 800 - 3000

    if DoesEntityExist(glass) then DetachEntity(glass, true, true) end
    if DoesEntityExist(ped) then
        TaskPlayAnim(ped, ANIM.outro.dict, ANIM.outro.ped, 3.0, 3.0, -1, 0, 0.0, false, false, false)
    end
    if DoesEntityExist(bottle) then PlayEntityAnim(bottle, ANIM.outro.drink, ANIM.outro.dict, 1000.0, false, true, false, 0.0, 0.0) end
    if DoesEntityExist(glass) then PlayEntityAnim(glass, ANIM.outro.glass, ANIM.outro.dict, 1000.0, false, true, false, 0.0, 0.0) end

    -- both props return to the bartender before they are removed
    Wait(1000)
    if DoesEntityExist(bottle) and DoesEntityExist(ped) then
        AttachEntityToEntity(bottle, ped, GetPedBoneIndex(ped, BONE_HAND), 0.0,0.0,0.0, 0.0,0.0,0.0, false, false, false, true, 2, true)
    end
    Wait(1200)
    if DoesEntityExist(glass) and DoesEntityExist(ped) then
        AttachEntityToEntity(glass, ped, GetPedBoneIndex(ped, BONE_GRIP), 0.0,0.0,0.0, 0.0,0.0,0.0, false, false, false, true, 2, true)
    end
    Wait(2000)

    cleanupProps(key)
    for _, a in pairs(ANIM) do RemoveAnimDict(a.dict) end
    if DoesEntityExist(ped) then
        TaskPlayAnim(ped, idle.dict, idle.clip, 3.0, 3.0, -1, 1, 0.0, false, false, false)
    end
    if isLocal then
        ClearPedTasks(PlayerPedId())
        FreezeEntityPosition(PlayerPedId(), false)
        busyLocal = false
        TriggerServerEvent(EV('server:barFree'))
    end
end)

-- ── ordering ─────────────────────────────────────────────────────────────
local function orderDrink(propId, spot, drinkIndex)
    if busyLocal then return end
    busyLocal = true
    local ped = PlayerPedId()
    local c = spot.coords

    -- step to the customer side of the counter, facing the bartender
    local rad = math.rad(c.w)
    local px = c.x + (-math.sin(rad) * 1.8) + (math.cos(rad) * 0.15)
    local py = c.y + (math.cos(rad) * 1.8) + (math.sin(rad) * 0.15)
    local cur = GetEntityCoords(ped)
    if #(cur - vec3(px, py, cur.z)) > 1.0 then
        TaskGoStraightToCoord(ped, px, py, cur.z, 1.0, 3000, (c.w + 180.0) % 360.0, 0.0)
        local deadline = GetGameTimer() + 3500
        while GetScriptTaskStatus(ped, 'SCRIPT_TASK_GO_STRAIGHT_TO_COORD') ~= 7 and GetGameTimer() < deadline do
            Wait(200)
        end
    end
    SetEntityCoordsNoOffset(ped, px, py, cur.z, false, false, false)
    SetEntityHeading(ped, (c.w + 180.0) % 360.0)
    FreezeEntityPosition(ped, true)

    lib.callback(EV('buyDrink'), false, function(ok, err)
        if not ok then
            FreezeEntityPosition(ped, false)
            busyLocal = false
            lib.notify({ description = L(err or 'no_access'), type = 'error' })
        end
        -- on success the sequence unfreezes when it finishes
    end, propId, spot.index, drinkIndex)
end

local function spawnBartender(propId, bar, spot)
    local key = barKey(propId, spot.index)
    if peds[key] and DoesEntityExist(peds[key]) then return end

    local model = joaat(bar.pedModel)
    RequestModel(model)
    local t = 0
    while not HasModelLoaded(model) and t < 50 do Wait(100); t = t + 1 end
    if not HasModelLoaded(model) then return end

    local c = spot.coords
    local ped = CreatePed(0, model, c.x, c.y, c.z - 1.0, c.w, false, false)
    SetModelAsNoLongerNeeded(model)
    peds[key] = ped
    SetEntityCanBeDamaged(ped, false)
    SetPedAsEnemy(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetPedCanBeTargetted(ped, false)
    FreezeEntityPosition(ped, true)

    RequestAnimDict(bar.idleAnim.dict)
    t = 0
    while not HasAnimDictLoaded(bar.idleAnim.dict) and t < 40 do Wait(50); t = t + 1 end
    if HasAnimDictLoaded(bar.idleAnim.dict) then
        TaskPlayAnim(ped, bar.idleAnim.dict, bar.idleAnim.clip, 3.0, 3.0, -1, 1, 0.0, false, false, false)
    end

    local options = {}
    for i, d in ipairs(bar.drinks) do
        options[#options + 1] = {
            label = ('%s ($%d)'):format(d.label, d.price),
            icon = 'fa-solid fa-martini-glass',
            onSelect = function() orderDrink(propId, spot, i) end,
        }
    end
    TargetAddLocalEntity(ped, options)
end

-- ── lifecycle ────────────────────────────────────────────────────────────
local function teardown()
    for _, p in pairs(spots) do p:remove() end
    spots = {}
    for key, ped in pairs(peds) do
        TargetRemoveLocalEntity(ped)
        if DoesEntityExist(ped) then DeleteEntity(ped) end
        peds[key] = nil
        cleanupProps(key)
    end
end

local function build()
    teardown()
    for propId, prop in pairs(CProperties) do
        local bar = prop.bar
        if bar and bar.enable ~= false then
            for _, spot in ipairs(bar.bartenders or {}) do
                local c = spot.coords
                spots[#spots + 1] = lib.points.new({
                    coords = vec3(c.x, c.y, c.z),
                    distance = bar.spawnDistance or 40.0,
                    onEnter = function() spawnBartender(propId, bar, spot) end,
                })
            end
        end
    end
end

AddEventHandler(EV('client:registryChanged'), build)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    teardown()
    stopDrunk()
    FreezeEntityPosition(PlayerPedId(), false)
end)
