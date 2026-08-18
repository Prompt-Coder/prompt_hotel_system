-- Client callbacks + the public API for other resources.
-- Every mutating path: rate limit, then server-side ACL, then act.

-- ── rate limiting ────────────────────────────────────────────────────────
local lastAction = {}

local function limited(src, key, ms)
    local k = tostring(src) .. ':' .. key
    local now = GetGameTimer()
    if (lastAction[k] or 0) + ms > now then return true end
    lastAction[k] = now
    return false
end

AddEventHandler('playerDropped', function()
    local prefix = tostring(source) .. ':'
    for k in pairs(lastAction) do
        if k:sub(1, #prefix) == prefix then lastAction[k] = nil end
    end
end)

-- The rent/extend events are callable from anywhere, so verify the player is
-- actually standing at this property's desk.
--
-- FAILS CLOSED: reception.coords is optional, so a property with no desk
-- captured yet has no ped to rent from either -- treating that as "anywhere is
-- fine" would let a player rent the building from across the map.
-- Server-side GrantRoom is unaffected.
--
-- must stay looser than ox_target's 7m default reach or there is a
-- clickable-but-refused dead band
local RECEPTION_RANGE = 8.0

local function gateLog(fmt, ...)
    if Config.Debug then print(('[prompt_hotel_system] ' .. fmt):format(...)) end
end

-- global so tests hit the real gate
function ApiNearReception(src, propId)
    local prop = Properties[propId]
    if not prop then
        gateLog('desk gate: %s is not a registered property', tostring(propId))
        return false
    end
    local c = prop.reception and prop.reception.coords
    if not c then
        gateLog('desk gate: %s has no reception.coords', propId)
        return false
    end
    local d = #(GetEntityCoords(GetPlayerPed(src)) - vec3(c.x, c.y, c.z))
    if d >= RECEPTION_RANGE then
        gateLog('desk gate: player %d is %.1fm from the %s desk (limit %.1f)',
            src, d, propId, RECEPTION_RANGE)
        return false
    end
    return true
end

-- ── client callbacks ─────────────────────────────────────────────────────
lib.callback.register(EV('menuData'), function(src, propId)
    -- Rate limited: without it this is a free, unlimited oracle on which rooms
    -- just came free, which is exactly what makes sniping a vacated room easy.
    if limited(src, 'menu', 500) then return { types = {} } end
    local prop = Properties[propId]
    if not prop then return { types = {} } end

    local identifier = FW.GetIdentifier(src)
    local free = GlobalState[KEY('occupancy')] or {}
    local d = prop.defaults

    local types = {}
    for _, t in ipairs(prop.roomTypes) do
        types[#types + 1] = {
            id    = t.id,
            label = t.label,
            price = t.pricePerDay or d.pricePerDay,
            free  = free[propId .. ':' .. t.id] or 0,
        }
    end

    local myRoom
    local roomId = identifier and Rentals_FindByRenter(identifier, propId)
    if roomId then
        local r, info = Rentals[roomId], Rooms[roomId]
        local guests = {}
        for gid, name in pairs(r.guests) do guests[#guests + 1] = { id = gid, name = name } end
        myRoom = {
            roomId    = roomId,
            floor     = info and info.floor,
            slot      = info and info.slot,
            number    = info and info.num,
            rtype     = r.rtype,
            expiresAt = r.expiresAt,
            expiresText = os.date('%d.%m %H:%M', math.floor(r.expiresAt / 1000)),
            inGrace   = Rentals_InGrace(roomId),
            guests    = guests,
        }
    end

    return { types = types, myRoom = myRoom, maxDays = d.maxDays, label = prop.label }
end)

lib.callback.register(EV('rent'), function(src, propId, rtype, days)
    if limited(src, 'rent', 3000) then return false, 'slow_down' end
    if not ApiNearReception(src, propId) then return false, 'too_far_desk' end
    return Rentals_Rent(src, propId, rtype, days)
end)

lib.callback.register(EV('extend'), function(src, propId, days)
    if limited(src, 'rent', 3000) then return false, 'slow_down' end
    if not ApiNearReception(src, propId) then return false, 'too_far_desk' end
    return Rentals_Extend(src, propId, days)
end)

lib.callback.register(EV('endRent'), function(src, propId)
    if limited(src, 'rent', 3000) then return false, 'slow_down' end
    if not ApiNearReception(src, propId) then return false, 'too_far_desk' end
    return Rentals_End(src, propId)
end)

lib.callback.register(EV('addGuest'), function(src, propId, targetServerId)
    if limited(src, 'guest', 1000) then return false, 'slow_down' end
    local target = tonumber(targetServerId)
    if not target or not GetPlayerName(target) then return false, 'no_access' end
    local tp = GetEntityCoords(GetPlayerPed(target))
    local sp = GetEntityCoords(GetPlayerPed(src))
    if #(tp - sp) > 5.0 then return false, 'no_access' end
    return Rentals_AddGuest(src, propId, target)
end)

lib.callback.register(EV('removeGuest'), function(src, propId, identifier)
    if limited(src, 'guest', 1000) then return false, 'slow_down' end
    return Rentals_RemoveGuest(src, propId, tostring(identifier))
end)

lib.callback.register(EV('nearbyPlayers'), function(src)
    if limited(src, 'nearby', 1000) then return {} end
    local sp = GetEntityCoords(GetPlayerPed(src))
    local out = {}
    for _, pidStr in ipairs(GetPlayers()) do
        local pid = tonumber(pidStr)
        if pid ~= src and #(GetEntityCoords(GetPlayerPed(pid)) - sp) < 5.0 then
            out[#out + 1] = { serverId = pid, name = FW.GetName(pid) }
        end
    end
    return out
end)

RegisterNetEvent(EV('server:toggleDoor'), function(roomId)
    local src = source
    if limited(src, 'door', 800) then return end
    if type(roomId) ~= 'string' or not Rooms[roomId] then return end
    local identifier = FW.GetIdentifier(src)
    if not identifier or not Rentals_HasAccess(identifier, roomId) then
        TriggerClientEvent(EV('client:notify'), src, 'no_access', 'error')
        return
    end
    local newLocked = not DoorsIsLocked(roomId)
    DoorsSetLocked(roomId, newLocked)
    TriggerClientEvent(EV('client:notify'), src, newLocked and 'door_locked' or 'door_unlocked', 'inform')
end)

RegisterNetEvent(EV('server:openStash'), function(roomId)
    local src = source
    if limited(src, 'stash', 800) then return end
    if type(roomId) ~= 'string' or not Rooms[roomId] then return end
    local identifier = FW.GetIdentifier(src)
    if not identifier or not Rentals_HasAccess(identifier, roomId) then return end
    local room = Rooms[roomId]
    local ppos = GetEntityCoords(GetPlayerPed(src))
    if #(ppos - vec3(room.origin.x, room.origin.y, room.origin.z)) > 15.0 then return end
    Inventory.Open(src, roomId)
end)

RegisterNetEvent(EV('server:requestAccessList'), function()
    Rentals_SendAccessListWhenReady(source)
end)

-- Published for third-party resources (presence, logging, rest/regen), so it
-- must be trustworthy: verify access AND proximity, not just that the room id
-- exists. Otherwise a client can claim to be in any room on the server.
RegisterNetEvent(EV('server:roomEntered'), function(roomId)
    local src = source
    if type(roomId) ~= 'string' then return end
    local room = Rooms[roomId]
    if not room then return end
    if limited(src, 'entered', 2000) then return end

    local identifier = FW.GetIdentifier(src)
    if not identifier or not Rentals_HasAccess(identifier, roomId) then return end

    local ppos = GetEntityCoords(GetPlayerPed(src))
    if #(ppos - vec3(room.origin.x, room.origin.y, room.origin.z)) > 30.0 then return end

    TriggerEvent(EV('roomEntered'), src, roomId)
end)

-- ── public API ───────────────────────────────────────────────────────────
-- Reads and writes accept a server id OR a stored identifier, so an admin
-- panel or web backend can act on a player who is offline.
local function resolve(v)
    if type(v) == 'number' then return FW.GetIdentifier(v) end
    -- Reject rather than tostring(): a table would become "table: 0x..." and be
    -- happily written to the database as somebody's identifier.
    if type(v) == 'string' and v ~= '' then return v end
    return nil
end

exports('GetProperties', function()
    local out = {}
    for propId, p in pairs(Properties) do
        local total, free = 0, 0
        for roomId, room in pairs(Rooms) do
            if room.propId == propId then
                total = total + 1
                if not Rentals[roomId] then free = free + 1 end
            end
        end
        out[propId] = { label = p.label, rooms = total, free = free, streaming = p.streaming }
    end
    return out
end)

exports('GetPlayerRooms', function(v)
    local identifier = resolve(v)
    if not identifier then return {} end
    local out = {}
    for _, roomId in ipairs(Rentals_AllByRenter(identifier)) do
        local room, r = Rooms[roomId], Rentals[roomId]
        out[#out + 1] = {
            roomId = roomId, propertyId = r.propId, num = room.num, type = r.rtype,
            expiresAt = r.expiresAt, inGrace = Rentals_InGrace(roomId),
        }
    end
    return out
end)

-- Filters on Rooms for the same reason GetPlayerRooms does. Without it the API
-- contradicted itself while a map was down: GetPlayerRooms said the player had
-- nothing, IsRoomOwner still said yes.
exports('IsRoomOwner', function(v, roomId)
    local r = Rentals[roomId]
    if not r or not Rooms[roomId] then return false end
    return r.identifier == resolve(v)
end)

exports('GetRoom', function(roomId)
    local room = Rooms[roomId]
    if not room then return nil end
    local r = Rentals[roomId]
    return {
        propertyId = room.propId, num = room.num, type = room.rtype,
        identifier = r and r.identifier, expiresAt = r and r.expiresAt,
        guests = r and r.guests or {},
    }
end)

exports('GrantRoom', function(identifier, propId, rtype, days)
    local ok, res = Rentals_RentAs(resolve(identifier), propId, rtype, days, nil)
    if not ok then return nil, res end
    return res
end)

exports('RevokeRoom', function(roomId)
    if not Rentals[roomId] then return false end
    return Rentals_Evict(roomId, 'revoked')
end)

-- 100 years. An unbounded value makes os.date() in menuData throw
-- ("number has no integer representation") and wedges that player's menu.
local MAX_EXPIRY_MS = 3155760000000

-- All three take the same per-room lock the internal paths use, so an admin
-- panel cannot interleave with a player's extend and erase it.
exports('SetRoomExpiry', function(roomId, expiresAtMs)
    if not Rentals[roomId] then return false end
    local v = tonumber(expiresAtMs)
    if not v or v ~= v or v == math.huge or v == -math.huge then return false end
    v = math.floor(v)
    if v <= 0 or v > MAX_EXPIRY_MS then return false end

    return Rentals_WithLock(roomId, function()
        local r = Rentals[roomId]
        if not r then return false end
        local prev = r.expiresAt
        r.expiresAt = v
        if not Storage.Upsert(roomId, r) then
            r.expiresAt = prev
            return false
        end
        return true
    end) == true
end)

exports('AddGuest', function(roomId, identifier)
    if not Rentals[roomId] then return false end
    local id = resolve(identifier)
    if not id then return false end

    return Rentals_WithLock(roomId, function()
        local r = Rentals[roomId]
        if not r or id == r.identifier then return false end
        local max = (Properties[r.propId] and Properties[r.propId].defaults.maxGuests)
            or Config.Defaults.maxGuests
        if Util.Count(r.guests) >= max then return false end
        r.guests[id] = id
        if not Storage.Upsert(roomId, r) then
            r.guests[id] = nil
            return false
        end
        return true
    end) == true
end)

exports('RemoveGuest', function(roomId, identifier)
    if not Rentals[roomId] then return false end
    local id = resolve(identifier)
    if not id then return false end

    return Rentals_WithLock(roomId, function()
        local r = Rentals[roomId]
        if not r then return false end
        local prev = r.guests[id]
        if prev == nil then return true end
        r.guests[id] = nil
        if not Storage.Upsert(roomId, r) then
            r.guests[id] = prev
            return false
        end
        return true
    end) == true
end)
