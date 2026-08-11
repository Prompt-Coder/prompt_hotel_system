-- Reception ped + booking menus (ox_lib context), one per registered property.
local peds = {}     -- [propId] = ped
local spots = {}    -- [propId] = lib.points object

local function openGuestMenu(propId, myRoom)
    local options = {{
        title = '+ Give guest key', icon = 'user-plus',
        onSelect = function()
            lib.callback(EV('nearbyPlayers'), false, function(players)
                local popts = {}
                for _, p in ipairs(players or {}) do
                    popts[#popts + 1] = {
                        title = p.name,
                        onSelect = function()
                            lib.callback(EV('addGuest'), false, function(ok, err)
                                lib.notify({
                                    description = ok and L('guest_added') or L(err or 'no_access'),
                                    type = ok and 'success' or 'error',
                                })
                            end, propId, p.serverId)
                        end,
                    }
                end
                if #popts == 0 then popts[1] = { title = 'Nobody nearby', disabled = true } end
                lib.registerContext({ id = RID('guest_add'), title = 'Nearby players', menu = RID('guests'), options = popts })
                lib.showContext(RID('guest_add'))
            end)
        end,
    }}

    for _, g in ipairs(myRoom.guests or {}) do
        options[#options + 1] = {
            title = ('Revoke: %s'):format(g.name), icon = 'user-minus',
            onSelect = function()
                lib.callback(EV('removeGuest'), false, function(ok)
                    lib.notify({
                        description = ok and L('guest_removed') or L('no_access'),
                        type = ok and 'success' or 'error',
                    })
                end, propId, g.id)
            end,
        }
    end

    lib.registerContext({ id = RID('guests'), title = 'Guest keys', options = options })
    lib.showContext(RID('guests'))
end

local function openMenu(propId)
    lib.callback(EV('menuData'), false, function(data)
        local options = {}

        if data.myRoom then
            local m = data.myRoom
            options[#options + 1] = {
                title = ('Your room: %s'):format(m.number or m.slot),
                description = m.inGrace
                    and ('EXPIRED %s — extend now or lose it'):format(m.expiresText or '?')
                    or ('Paid until %s'):format(m.expiresText or '?'),
                icon = 'bed', readOnly = true,
            }
            options[#options + 1] = {
                title = 'Extend rent', icon = 'calendar-plus',
                onSelect = function()
                    local input = lib.inputDialog('Extend rent', {
                        { type = 'number', label = 'Days', min = 1, max = data.maxDays or 14, required = true },
                    })
                    if input and input[1] then
                        lib.callback(EV('extend'), false, function(ok, err)
                            lib.notify({
                                description = ok and L('extended') or L(err or 'no_access'),
                                type = ok and 'success' or 'error',
                            })
                        end, propId, input[1])
                    end
                end,
            }
            options[#options + 1] = {
                title = 'Guest keys', icon = 'users',
                onSelect = function() openGuestMenu(propId, m) end,
            }
            options[#options + 1] = {
                title = 'Check out', icon = 'door-open',
                onSelect = function()
                    local confirm = lib.alertDialog({
                        header = 'Check out?', content = 'Your room will be released.', cancel = true,
                    })
                    if confirm == 'confirm' then
                        lib.callback(EV('endRent'), false, function(ok, err)
                            lib.notify({
                                description = ok and L('rent_ended') or L(err or 'no_access'),
                                type = ok and 'success' or 'error',
                            })
                        end, propId)
                    end
                end,
            }
        else
            for _, t in ipairs(data.types or {}) do
                options[#options + 1] = {
                    title = t.label,
                    description = ('$%d/day — %d free'):format(t.price, t.free),
                    icon = 'bed',
                    disabled = t.free == 0,
                    onSelect = function()
                        local input = lib.inputDialog(t.label, {
                            { type = 'number', label = ('Days (max %d)'):format(data.maxDays or 14),
                              min = 1, max = data.maxDays or 14, required = true },
                        })
                        if input and input[1] then
                            lib.callback(EV('rent'), false, function(ok, res)
                                if ok then
                                    local room = CRooms[res]
                                    lib.notify({
                                        description = L('rented', room and room.floor or 1, room and room.num or 0),
                                        type = 'success', duration = 8000,
                                    })
                                else
                                    lib.notify({ description = L(res or 'no_access'), type = 'error' })
                                end
                            end, propId, t.id, input[1])
                        end
                    end,
                }
            end
            if #options == 0 then
                options[1] = { title = 'No rooms for rent here', disabled = true }
            end
        end

        lib.registerContext({
            id = RID('reception'),
            title = (data.label or 'Hotel') .. ' Reception',
            options = options,
        })
        lib.showContext(RID('reception'))
    end, propId)
end

local function spawnPed(propId, prop)
    if peds[propId] and DoesEntityExist(peds[propId]) then return end
    local cfg = prop.reception
    local model = joaat(cfg.model)
    RequestModel(model)
    local tries = 0
    while not HasModelLoaded(model) and tries < 50 do Wait(100); tries = tries + 1 end
    if not HasModelLoaded(model) then return end

    local c = cfg.coords
    local ped = CreatePed(0, model, c.x, c.y, c.z - 1.0, c.w, false, false)
    peds[propId] = ped
    SetModelAsNoLongerNeeded(model)
    SetEntityInvincible(ped, true)
    SetPedCanRagdoll(ped, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    FreezeEntityPosition(ped, true)
    if cfg.scenario then TaskStartScenarioInPlace(ped, cfg.scenario, 0, true) end

    TargetAddLocalEntity(ped, {{
        label = L('talk_receptionist'), icon = 'fa-solid fa-bell-concierge',
        onSelect = function() openMenu(propId) end,
    }})
end

local function teardown()
    for _, p in pairs(spots) do p:remove() end
    spots = {}
    for propId, ped in pairs(peds) do
        -- Drop the target entry before deleting the ped: GTA recycles handles, so a stale entry could end up on the wrong entity.
        TargetRemoveLocalEntity(ped)
        if DoesEntityExist(ped) then DeleteEntity(ped) end
        peds[propId] = nil
    end
    lib.hideTextUI()
end

local function build()
    teardown()
    for propId, prop in pairs(CProperties) do
        local cfg = prop.reception
        local c = cfg and cfg.coords
        -- A property whose reception spot has not been captured yet is skipped
        -- rather than dropping a ped at the world origin.
        if c and cfg.model ~= false and not (c.x == 0.0 and c.y == 0.0) then
            spots[propId] = lib.points.new({
                coords = vec3(c.x, c.y, c.z),
                distance = 50.0,
                onEnter = function() spawnPed(propId, prop) end,
            })
        end
    end
end

AddEventHandler(EV('client:registryChanged'), build)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then teardown() end
end)
