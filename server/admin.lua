-- Admin commands. Console (src 0) always allowed; in-game needs hotel.admin.
local function allowed(src)
    return src == 0 or IsPlayerAceAllowed(src, 'hotel.admin')
end

-- Client-side debug commands (floor teleport, IPL bisect, point capture) can't
-- check an ace themselves, so the client gates them on this flag -- without it,
-- any player on a Config.Debug server could teleport to any floor of any property.
local function publishDebugFlag(src)
    Player(src).state:set(KEY('debug'), Config.Debug and IsPlayerAceAllowed(src, 'hotel.admin') or false, true)
end

AddEventHandler('playerJoining', function()
    publishDebugFlag(source)
end)

RegisterNetEvent(EV('server:requestDebugFlag'), function()
    publishDebugFlag(source)
end)

local function reply(src, msg)
    if src == 0 then print('[prompt_hotel_system] ' .. msg)
    else TriggerClientEvent('chat:addMessage', src, { args = { 'Hotel', msg } }) end
end

RegisterCommand(CMD('properties'), function(src)
    if not allowed(src) then return end
    if Util.Count(Properties) == 0 then
        reply(src, 'no properties registered — is a hotel map running?')
        return
    end
    for propId, p in pairs(Properties) do
        local total, free = 0, 0
        for roomId, room in pairs(Rooms) do
            if room.propId == propId then
                total = total + 1
                if not Rentals[roomId] then free = free + 1 end
            end
        end
        reply(src, ("%s  '%s'  %d/%d free  streaming=%s  source=%s")
            :format(propId, p.label, free, total, p.streaming, p.source))
    end
end, false)

-- <prefix>_grant <serverId|identifier> <propId> <type> <days>
RegisterCommand(CMD('grant'), function(src, args)
    if not allowed(src) then return end
    local who, propId, rtype, days = args[1], args[2], args[3], tonumber(args[4]) or 1
    if not who or not propId or not rtype then
        reply(src, ('usage: %s <serverId|identifier> <propertyId> <roomType> [days]'):format(CMD('grant')))
        return
    end
    local identifier = tonumber(who) and FW.GetIdentifier(tonumber(who)) or who
    if not identifier then
        reply(src, 'could not resolve an identifier for ' .. tostring(who))
        return
    end
    local ok, res = Rentals_RentAs(identifier, propId, rtype, days, nil)
    if ok then
        reply(src, ('granted %s to %s for %d day(s)'):format(res, identifier, days))
    else
        reply(src, 'grant failed: ' .. tostring(res))
    end
end, false)

RegisterCommand(CMD('revoke'), function(src, args)
    if not allowed(src) then return end
    local roomId = args[1]
    if not roomId or not Rentals[roomId] then
        reply(src, ('usage: %s <roomId>  (see %s)'):format(CMD('revoke'), CMD('rentals')))
        return
    end
    Rentals_Evict(roomId, 'revoked')
    reply(src, 'revoked ' .. roomId)
end, false)

RegisterCommand(CMD('rentals'), function(src)
    if not allowed(src) then return end
    if Util.Count(Rentals) == 0 then
        reply(src, 'no active rentals')
        return
    end
    for roomId, r in pairs(Rentals) do
        reply(src, ('%s  %s  until %s%s'):format(roomId, r.identifier,
            os.date('%d.%m %H:%M', math.floor(r.expiresAt / 1000)),
            Rentals_InGrace(roomId) and '  (GRACE)' or ''))
    end
end, false)

-- Rentals whose room no longer exists: a map that renumbered its rooms, or one
-- that is simply not running. Never cleaned up automatically.
RegisterCommand(CMD('orphans'), function(src)
    if not allowed(src) then return end
    local list = Rentals_Orphans()
    if #list == 0 then
        reply(src, 'no orphaned rentals')
        return
    end
    reply(src, ('%d orphaned rental(s) — the room id no longer exists:'):format(#list))
    for _, o in ipairs(list) do
        reply(src, ('  %s  %s  (property %s)'):format(o.roomId, o.identifier,
            o.registered and 'IS registered — the room was renumbered' or 'is not running'))
    end
    reply(src, ('use %s <roomId> to release one'):format(CMD('revoke')))
end, false)

-- <prefix>_evictall <propId>
RegisterCommand(CMD('evictall'), function(src, args)
    if not allowed(src) then return end
    local propId = args[1]
    if not propId or not Properties[propId] then
        reply(src, ('usage: %s <propertyId>'):format(CMD('evictall')))
        return
    end
    local n = 0
    for roomId, r in pairs(Rentals) do
        if r.propId == propId then
            Rentals_Evict(roomId, 'revoked')
            n = n + 1
        end
    end
    reply(src, ('evicted %d rental(s) at %s'):format(n, propId))
end, false)
