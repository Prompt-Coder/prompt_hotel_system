-- Particle browser, for picking the shower effect.
--
--   /<prefix>_ptfx           start at the shower point of the room you are in
--                            (or 1.5m in front of you if you are not in one)
--   /<prefix>_ptfx <name>    jump straight to one effect
--
--   [E] next   [Q] previous   [UP]/[DOWN] scale   [ENTER] print   [X] exit
--
-- Every name below exists in core.ypt -- scr_apartment_mp and scr_safehouse
-- ship no shower effect.

if not Config.Debug then return end

local ASSET = 'core'

local CANDIDATES = {
    -- pours: the stream itself
    'ent_amb_water_roof_pour',
    'ent_amb_water_roof_pour_long',
    'ent_amb_roof_water_pour',
    'ent_sht_water_pour',
    'ent_sht_water',
    'ent_amb_int_waterfall_runoff',
    'ent_amb_sprinkler_city_water',
    'ent_amb_sprinkler_city_water2',
    'ent_amb_sprinkler_golf_water',
    -- lighter: drips
    'ent_amb_water_roof_drips',
    'ent_amb_water_roof_drips_thin',
    'ent_amb_water_drips_lg',
    'ent_amb_water_drips_med',
    'ent_amb_water_drips_sm',
    -- splash, for the floor
    'ent_amb_water_splash_wide',
    'ent_amb_waterfall_splash',
    'ent_amb_waterfall_splash_spray',
    'ent_dst_water_spray_fine',
    'ent_anim_bm_water_mist',
    'ent_anim_bm_water_spray',
    -- steam, to fog the bathroom
    'ent_amb_steam',
    'ent_amb_steam_open_lgt',
    'ent_amb_steam_open_hvy',
    'ent_amb_steam_round',
    'ent_amb_steam_rnd_hvy',
}

local idx, scale, fx, anchor = 1, 1.0, nil, nil

-- ent_sht_* are bursts: repeat mode re-fires on an interval instead of looping
local repeating, interval = false, 2500

local function say(msg)
    print(('[prompt_hotel_system] %s'):format(msg))
    TriggerEvent('chat:addMessage',
        { color = { 120, 200, 255 }, args = { Config.CommandPrefix or 'hotel', msg } })
end

local function stop()
    if fx then StopParticleFxLooped(fx, false) end
    fx = nil
end

local function spawn()
    stop()
    if not HasNamedPtfxAssetLoaded(ASSET) then return end
    if repeating then return end        -- the repeat thread fires it instead
    UseParticleFxAsset(ASSET)
    fx = StartParticleFxLoopedAtCoord(CANDIDATES[idx],
        anchor.x, anchor.y, anchor.z, 0.0, 0.0, 0.0, scale, false, false, false, false)
end

CreateThread(function()
    while true do
        if anchor and repeating and HasNamedPtfxAssetLoaded(ASSET) then
            UseParticleFxAsset(ASSET)
            StartParticleFxNonLoopedAtCoord(CANDIDATES[idx],
                anchor.x, anchor.y, anchor.z, 0.0, 0.0, 0.0, scale, false, false, false)
            Wait(interval)
        else
            Wait(200)
        end
    end
end)

-- Anchor on the room's showerHead when there is one: judging a shower effect
-- anywhere else tells you nothing about how it sits under the head.
local function pickAnchor()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    for _, room in pairs(CRooms) do
        local v = HotelRoomVariant(room)
        local head = v and v.amenities and v.amenities.showerHead
        if head then
            local w = Util.RotateOffset(room.origin, head)
            if #(pos - w) < 12.0 then return w, 'showerHead' end
        end
    end
    local fwd = GetEntityForwardVector(ped)
    return pos + vec3(fwd.x * 1.5, fwd.y * 1.5, 0.6), 'in front of you'
end

RegisterCommand(CMD('ptfx'), function(_, args)
    if fx or anchor then
        stop(); anchor = nil; lib.hideTextUI(); say('ptfx browser off')
        return
    end

    if args[1] then
        local want = args[1]
        local found
        for i, n in ipairs(CANDIDATES) do if n == want then found = i end end
        if found then idx = found else CANDIDATES[#CANDIDATES + 1] = want; idx = #CANDIDATES end
    end

    RequestNamedPtfxAsset(ASSET)
    local tries = 0
    while not HasNamedPtfxAssetLoaded(ASSET) and tries < 50 do Wait(100); tries = tries + 1 end
    if not HasNamedPtfxAssetLoaded(ASSET) then say("could not load the '" .. ASSET .. "' ptfx asset"); return end

    local where
    anchor, where = pickAnchor()
    say(('ptfx browser on — anchored %s, %d effects'):format(where, #CANDIDATES))
    spawn()
end, false)

CreateThread(function()
    while true do
        if anchor then
            lib.showTextUI(('%d/%d  %s  (scale %.2f)  %s\n[E] next  [Q] prev  [UP/DOWN] scale  [R] repeat  [LEFT/RIGHT] interval  [ENTER] print  [X] exit')
                :format(idx, #CANDIDATES, CANDIDATES[idx], scale,
                    repeating and ('REPEAT %dms'):format(interval) or 'looped'))
            DrawMarker(28, anchor.x, anchor.y, anchor.z, 0, 0, 0, 0, 0, 0,
                0.08, 0.08, 0.08, 255, 180, 60, 140, false, false, 2, false, nil, nil, false)

            if IsControlJustPressed(0, 38) then
                idx = idx % #CANDIDATES + 1; spawn(); say(CANDIDATES[idx])
            elseif IsControlJustPressed(0, 44) then
                idx = (idx - 2) % #CANDIDATES + 1; spawn(); say(CANDIDATES[idx])
            elseif IsControlJustPressed(0, 172) then
                scale = math.min(scale + 0.25, 10.0); spawn()
            elseif IsControlJustPressed(0, 173) then
                scale = math.max(scale - 0.25, 0.25); spawn()
            elseif IsControlJustPressed(0, 45) then
                repeating = not repeating; spawn()
                say(repeating and ('repeat mode ON (%dms)'):format(interval) or 'repeat mode OFF (looped)')
            elseif IsControlJustPressed(0, 174) then
                interval = math.max(interval - 250, 250)
            elseif IsControlJustPressed(0, 175) then
                interval = math.min(interval + 250, 10000)
            elseif IsControlJustPressed(0, 191) then
                say(("ptfxName = '%s',   ptfxScale = %.2f,   ptfxRepeat = %s,")
                    :format(CANDIDATES[idx], scale, repeating and tostring(interval) or 'nil'))
            elseif IsControlJustPressed(0, 73) then
                stop(); anchor = nil; lib.hideTextUI(); say('ptfx browser off')
            end
            Wait(0)
        else
            Wait(300)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then stop(); lib.hideTextUI() end
end)
