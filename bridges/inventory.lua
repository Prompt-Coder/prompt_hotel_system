-- Stash bridge: Config.Inventory override -> ox_inventory -> qb-inventory ->
-- none (the option is hidden client-side when there is no backend).
Inventory = { backend = 'none' }

local function log(fmt, ...) print(('[prompt_hotel_system] ' .. fmt):format(...)) end

local function detect()
    local want = Config.Inventory or 'auto'
    if want == 'none' then return 'none' end
    if want == 'custom' then return 'custom' end
    if want ~= 'auto' then return want end
    if CustomInventory then return 'custom' end
    if GetResourceState('ox_inventory') == 'started' then return 'ox' end
    if GetResourceState('qb-inventory') == 'started' then return 'qb' end
    return 'none'
end

CreateThread(function()
    Wait(600)
    Inventory.backend = detect()
    GlobalState[KEY('stash_enabled')] = Inventory.backend ~= 'none'
    log('inventory backend: %s', Inventory.backend)

    -- Properties registered before this bridge resolved still need stashes.
    for propId in pairs(Properties or {}) do Inventory.RegisterProperty(propId) end
end)

-- ox_inventory needs every stash declared before it can be opened. Rooms appear
-- when a property registers, not at boot, so this is driven by the event.
function Inventory.RegisterProperty(propId)
    if Inventory.backend ~= 'ox' then return end
    for roomId, room in pairs(Registry.RoomsOf(propId)) do
        exports.ox_inventory:RegisterStash(RID(roomId), ('%s %s'):format(L('stash'), room.num or roomId),
            Config.Stash.slots, Config.Stash.maxWeight, false)
    end
end

AddEventHandler(EV('propertyRegistered'), function(propId)
    Inventory.RegisterProperty(propId)
end)

function Inventory.Open(src, roomId)
    local id = RID(roomId)
    if Inventory.backend == 'custom' then
        CustomInventory.open(src, roomId, L('stash'))
    elseif Inventory.backend == 'ox' then
        exports.ox_inventory:forceOpenInventory(src, 'stash', id)
    elseif Inventory.backend == 'qb' then
        exports['qb-inventory']:OpenInventory(src, id, {
            label = L('stash'), maxweight = Config.Stash.maxWeight, slots = Config.Stash.slots,
        })
    end
end

function Inventory.Clear(roomId)
    local id = RID(roomId)
    if Inventory.backend == 'custom' then
        pcall(CustomInventory.clear, roomId)
    elseif Inventory.backend == 'ox' then
        pcall(function() exports.ox_inventory:ClearInventory(id) end)
    elseif Inventory.backend == 'qb' then
        pcall(function() exports['qb-inventory']:ClearStash(id) end)
    end
end
