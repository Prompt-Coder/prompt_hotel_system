-- Interaction bridge: ox_target -> qb-target -> lib.zones + [E] fallback.
-- Option shape (shared by all backends):
--   { label, icon, onSelect = fn, canInteract = fn|nil }
local backend = 'fallback'
local fallbackZones = {}

CreateThread(function()
    Wait(200)
    local want = Config.Target or 'auto'
    if want == 'none' then
        backend = 'fallback'
    elseif want ~= 'auto' then
        backend = want
    elseif GetResourceState('ox_target') == 'started' then
        backend = 'ox'
    elseif GetResourceState('qb-target') == 'started' then
        backend = 'qb'
    end
    if Config.Debug then print(('[prompt_hotel_system] target backend: %s'):format(backend)) end
end)

function TargetBackend() return backend end

function TargetAddBoxZone(id, coords, size, heading, options)
    if backend == 'ox' then
        exports.ox_target:addBoxZone({
            name = id, coords = coords, size = size, rotation = heading, options = options,
        })
    elseif backend == 'qb' then
        local opts = {}
        for i, o in ipairs(options) do
            opts[i] = { label = o.label, icon = o.icon, action = o.onSelect, canInteract = o.canInteract }
        end
        exports['qb-target']:AddBoxZone(id, coords, size.x, size.y, {
            name = id, heading = heading,
            minZ = coords.z - size.z / 2, maxZ = coords.z + size.z / 2,
        }, { options = opts, distance = 2.0 })
    else
        fallbackZones[id] = lib.zones.box({
            coords = coords, size = size, rotation = heading,
            inside = function()
                local o = options[1]
                if o.canInteract and not o.canInteract() then return end
                lib.showTextUI(('[E] %s'):format(o.label))
                if IsControlJustPressed(0, 38) then o.onSelect() end
            end,
            onExit = function() lib.hideTextUI() end,
        })
    end
end

function TargetAddLocalEntity(entity, options)
    if backend == 'ox' then
        exports.ox_target:addLocalEntity(entity, options)
    elseif backend == 'qb' then
        local opts = {}
        for i, o in ipairs(options) do
            opts[i] = { label = o.label, icon = o.icon, action = o.onSelect, canInteract = o.canInteract }
        end
        exports['qb-target']:AddTargetEntity(entity, { options = opts, distance = 2.5 })
    else
        local pos = GetEntityCoords(entity)
        TargetAddBoxZone('ent_' .. tostring(entity), pos, vec3(1.8, 1.8, 2.2), 0.0, options)
    end
end

-- Must be called before the entity is deleted: GTA recycles handles, so a
-- leaked entry can inherit onto an unrelated ped, or leak a zone on fallback.
function TargetRemoveLocalEntity(entity)
    if backend == 'ox' then
        pcall(function() exports.ox_target:removeLocalEntity(entity) end)
    elseif backend == 'qb' then
        pcall(function() exports['qb-target']:RemoveTargetEntity(entity) end)
    else
        TargetRemoveZone('ent_' .. tostring(entity))
    end
end

function TargetRemoveZone(id)
    if backend == 'ox' then
        pcall(function() exports.ox_target:removeZone(id) end)
    elseif backend == 'qb' then
        pcall(function() exports['qb-target']:RemoveZone(id) end)
    elseif fallbackZones[id] then
        fallbackZones[id]:remove()
        fallbackZones[id] = nil
    end
end
