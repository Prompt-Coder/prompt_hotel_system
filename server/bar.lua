-- Bar. One bartender serves one player at a time: pay, then broadcast the
-- synced pour sequence to everyone nearby.
--
-- No inventory item is created -- the drink IS the animation plus a drunk
-- effect -- so this works on a server with no inventory script at all.
local busy = {}     -- [barId] = src

-- barId is 'propId#index': stable across restarts and unique across properties,
-- so two hotels' bars can never block each other.
local function barId(propId, index) return ('%s#%d'):format(propId, index) end

local function resolve(propId, index)
    local prop = Properties[propId]
    if not prop or not prop.bar or prop.bar.enable == false then return nil end
    for _, b in ipairs(prop.bar.bartenders) do
        if b.index == index then return prop.bar, b end
    end
end

local function release(src)
    for id, holder in pairs(busy) do
        if holder == src then busy[id] = nil end
    end
end

lib.callback.register(EV('buyDrink'), function(src, propId, barIndex, drinkIndex)
    barIndex = tonumber(barIndex)
    drinkIndex = tonumber(drinkIndex)
    if not barIndex or not drinkIndex then return false, 'no_access' end

    local bar, spot = resolve(propId, barIndex)
    if not bar or not spot then return false, 'bar_closed' end

    local drink = bar.drinks[drinkIndex]
    if not drink then return false, 'invalid_drink' end

    local id = barId(propId, barIndex)
    if busy[id] then return false, 'bar_busy' end

    -- Must actually be standing at that bar -- must stay looser than ox_target's
    -- 7m default reach or there is a clickable-but-refused dead band.
    local ppos = GetEntityCoords(GetPlayerPed(src))
    local d = #(ppos - vec3(spot.coords.x, spot.coords.y, spot.coords.z))
    if d > 8.0 then
        if Config.Debug then
            print(('[prompt_hotel_system] bar gate: player %d is %.1fm from %s bartender %d (limit 8.0)')
                :format(src, d, propId, barIndex))
        end
        return false, 'too_far_bar'
    end

    -- price is read here, never sent by the client
    local prev = Config.MoneyType
    Config.MoneyType = bar.payFrom == 'bank' and 'bank' or 'cash'
    local paid = Money.Charge(src, drink.price, 'hotel-bar')
    Config.MoneyType = prev
    if not paid then return false, 'no_money' end

    busy[id] = src
    TriggerClientEvent(EV('client:barDrink'), -1, {
        propId       = propId,
        bar          = barIndex,
        target       = src,
        model        = drink.model,
        glass        = drink.glass,
        intoxication = drink.intoxication or 1.0,
    })

    -- watchdog: never leave a bar stuck if the client dies mid-sequence
    SetTimeout(30000, function()
        if busy[id] == src then busy[id] = nil end
    end)
    return true
end)

RegisterNetEvent(EV('server:barFree'), function()
    release(source)
end)

AddEventHandler('playerDropped', function()
    release(source)
end)

-- A property being unregistered must not leave its bars marked busy forever.
AddEventHandler(EV('propertyUnregistered'), function(propId)
    local prefix = propId .. '#'
    for id in pairs(busy) do
        if id:sub(1, #prefix) == prefix then busy[id] = nil end
    end
end)
