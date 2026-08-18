-- Rental lifecycle. Knows booking rules; knows no map.
--
-- Rental shape (identical to the storage row):
--   { propId, identifier, renterName, rtype, rentedAt, expiresAt,
--     guests = { [identifier] = name }, data = {} }
-- All timestamps are unix MILLISECONDS.
Rentals = {}

local DAY_MS = 86400000

local function propDefaults(propId)
    local p = Properties[propId]
    return (p and p.defaults) or Config.Defaults
end

local function typeCfg(propId, rtype)
    local p = Properties[propId]
    if not p then return nil end
    for _, t in ipairs(p.roomTypes) do
        if t.id == rtype then return t end
    end
end

local function nowMs() return os.time() * 1000 end

-- Sanitise a client-supplied day count.
--
-- NaN is why this exists: every comparison against NaN is false, so a naive
-- `days < 1 or days > maxDays` guard waves it through, and QBCore's balance
-- checks are comparisons too -- an unrejected NaN sets the bank to NaN for good.
local function sanitiseDays(v)
    v = tonumber(v)
    if not v then return nil end
    if v ~= v then return nil end                       -- NaN
    if v == math.huge or v == -math.huge then return nil end
    v = math.floor(v)
    if v < 1 then return nil end
    return v
end

-- In-flight bookings, so the quota cannot be beaten by a second request landing
-- while the first is still yielding inside the database write.
local pending = {}   -- [identifier] = count

local function pendingCount(identifier)
    return pending[identifier] or 0
end

local function pendingAdd(identifier, n)
    pending[identifier] = math.max(0, pendingCount(identifier) + n)
    if pending[identifier] == 0 then pending[identifier] = nil end
end

-- Who last held each room, so a new renter never inherits the previous
-- occupant's stash. Empty after a restart, which fails in the safe direction:
-- the next rental clears.
local lastRenter = {}

-- Per-room write lock. Every mutation restores the pre-yield value on a failed
-- write; two overlapping mutations on the same room can otherwise lose a paid
-- extension (a rollback erasing the other's write) or resurrect a deleted row.
local writing = {}

local function withRoomLock(roomId, fn)
    local deadline = GetGameTimer() + 15000
    while writing[roomId] and GetGameTimer() < deadline do Wait(50) end
    if writing[roomId] then return false, 'busy' end

    writing[roomId] = true
    local ok, a, b = pcall(fn)
    writing[roomId] = nil

    if not ok then
        print(('[prompt_hotel_system] ^1write on %s crashed: %s^0'):format(roomId, tostring(a)))
        return false, 'write_failed'
    end
    return a, b
end

-- ── queries ──────────────────────────────────────────────────────────────
-- Every query filters on Rooms[roomId], including the quota count: an orphaned
-- rental (room renumbered, or its map not running) must not occupy a quota
-- slot for a room the player can no longer reach. See Rentals_Orphans.
function Rentals_FindByRenter(identifier, propId)
    for roomId, r in pairs(Rentals) do
        if r.identifier == identifier and Rooms[roomId] then
            if not propId or r.propId == propId then return roomId end
        end
    end
end

function Rentals_AllByRenter(identifier)
    local out = {}
    for roomId, r in pairs(Rentals) do
        if r.identifier == identifier and Rooms[roomId] then out[#out + 1] = roomId end
    end
    return out
end

function Rentals_HasAccess(identifier, roomId)
    local r = Rentals[roomId]
    if not r then return false end
    return r.identifier == identifier or r.guests[identifier] ~= nil
end

-- Expired but still inside the grace window: the room is yours, and the
-- reception menu leads with Extend.
function Rentals_InGrace(roomId)
    local r = Rentals[roomId]
    return r ~= nil and nowMs() > r.expiresAt
end

function Rentals_SyncOccupancy()
    local free = {}
    for propId, prop in pairs(Properties) do
        for _, t in ipairs(prop.roomTypes) do free[propId .. ':' .. t.id] = 0 end
    end
    for roomId, room in pairs(Rooms) do
        if not Rentals[roomId] and room.rtype then
            local k = room.propId .. ':' .. room.rtype
            free[k] = (free[k] or 0) + 1
        end
    end
    GlobalState[KEY('occupancy')] = free
end

function Rentals_SendAccessList(src, identifier)
    local map, mine = {}, {}
    for roomId, r in pairs(Rentals) do
        if r.identifier == identifier then
            map[roomId] = true
            mine[#mine + 1] = roomId
        elseif r.guests[identifier] then
            map[roomId] = true
        end
    end
    TriggerClientEvent(EV('client:accessList'), src, map, mine)
end

function Rentals_ClearAccess(src)
    TriggerClientEvent(EV('client:accessList'), src, {}, {})
end

-- The client asks for its keys as soon as it has the registry, which on any
-- framework with character selection is before the player object exists. Reading
-- that nil as "no rooms" left a renter with no door, no stash and no room blip
-- for the whole session -- restarting the resource was the only cure, because
-- that re-ran the client's one and only request.
local awaitingAccess = {}

function Rentals_SendAccessListWhenReady(src)
    local identifier = FW.GetIdentifier(src)
    if identifier then return Rentals_SendAccessList(src, identifier) end

    if awaitingAccess[src] then return end   -- the request event is client-callable
    awaitingAccess[src] = true
    CreateThread(function()
        local id = FW.AwaitIdentifier(src)
        awaitingAccess[src] = nil
        if id then
            Rentals_SendAccessList(src, id)
        elseif FW.Connected(src) then
            print(('[prompt_hotel_system] ^3player %d never got an identity from \'%s\' — '
                .. 'their room keys are missing^0'):format(src, FW.Framework()))
        end
    end)
end

AddEventHandler('playerDropped', function()
    awaitingAccess[source] = nil
end)

-- Character switching never restarts the client, so it never asks again: these
-- are the only signal that identity changed under a connected player.
AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    local src = player and player.PlayerData and player.PlayerData.source
    if src then Rentals_SendAccessListWhenReady(src) end
end)

AddEventHandler('esx:playerLoaded', function(src)
    if src then Rentals_SendAccessListWhenReady(src) end
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    if src then Rentals_ClearAccess(src) end
end)

local function broadcastAccessTo(identifier)
    for _, srcStr in ipairs(GetPlayers()) do
        local psrc = tonumber(srcStr)
        if FW.GetIdentifier(psrc) == identifier then Rentals_SendAccessList(psrc, identifier) end
    end
end

-- ── booking ──────────────────────────────────────────────────────────────
-- The single booking path. `src` may be nil (an API grant, or an offline
-- grant from a web panel), in which case no money changes hands. Requires
-- storage loaded AND the framework bound -- either race can silently lose
-- a booking or store it against the wrong identity.
function Rentals_Ready()
    return Storage.Ready() and FW.Bound()
end

function Rentals_RentAs(identifier, propId, rtype, days, src)
    if not Rentals_Ready() then return false, 'not_ready' end
    if type(identifier) ~= 'string' or identifier == '' then return false, 'no_access' end
    local prop = Properties[propId]
    if not prop then return false, 'no_access' end

    local d = propDefaults(propId)
    days = sanitiseDays(days)
    if not days or days > d.maxDays then return false, 'bad_days' end

    local t = typeCfg(propId, rtype)
    if not t then return false, 'no_access' end

    -- quota. Counts real rentals AND in-flight ones: the write below yields, and
    -- the rate limiter's window is shorter than the database deadline, so a
    -- second request can otherwise arrive while the first has committed nothing.
    local limit = d.maxRoomsPerPlayer or 1
    local scoped = Config.RoomQuotaScope ~= 'global' and propId or nil
    local held = 0
    for roomId, r in pairs(Rentals) do
        if r.identifier == identifier and Rooms[roomId]
           and (not scoped or r.propId == scoped) then held = held + 1 end
    end
    -- counts only rooms that still exist; orphans must not block a new rental
    if held + pendingCount(identifier) >= limit then return false, 'already_renting' end

    -- 6. RESERVE, before any money moves
    local roomId = Registry.Reserve(propId, rtype)
    if not roomId then return false, 'no_room_free' end

    -- 7. PRICE, computed here and only here
    local price = (t.pricePerDay or d.pricePerDay) * days

    pendingAdd(identifier, 1)

    -- 8. CHARGE
    if src and not Money.Charge(src, price, 'hotel-rent') then
        pendingAdd(identifier, -1)
        Registry.Release(roomId)
        return false, 'no_money'
    end

    -- 9. COMMIT
    local ts = nowMs()
    local rental = {
        propId     = propId,
        identifier = identifier,
        renterName = src and FW.GetName(src) or identifier,
        rtype      = rtype,
        rentedAt   = ts,
        expiresAt  = ts + days * DAY_MS,
        guests     = {},
        data       = {},
    }
    if not Storage.Upsert(roomId, rental) then
        -- 10. ROLLBACK — never take money for a room nobody got
        if src and not Money.Refund(src, price, 'hotel-rent-failed') then
            print(('[prompt_hotel_system] ^1REFUND FAILED — %s charged %d for %s but got no room. Refund by hand.^0')
                :format(identifier, price, roomId))
        end
        pendingAdd(identifier, -1)
        Registry.Release(roomId)
        return false, 'write_failed'
    end

    Rentals[roomId] = rental
    pendingAdd(identifier, -1)
    Registry.Release(roomId)

    -- A new occupant must never inherit the last one's belongings. Eviction does
    -- not wipe by default (an accidental lapse would dump a player's things into
    -- the void) -- the wipe happens here, when someone else actually takes it.
    if lastRenter[roomId] ~= identifier then Inventory.Clear(roomId) end
    lastRenter[roomId] = identifier

    -- 11. PUBLISH
    DoorsSetLocked(roomId, true)
    Rentals_SyncOccupancy()
    if src then Rentals_SendAccessList(src, identifier) else broadcastAccessTo(identifier) end
    TriggerEvent(EV('roomRented'), identifier, roomId, propId, days, price)
    return true, roomId
end

function Rentals_Rent(src, propId, rtype, days)
    return Rentals_RentAs(FW.GetIdentifier(src), propId, rtype, days, src)
end

-- ── extend ───────────────────────────────────────────────────────────────
function Rentals_Extend(src, propId, days)
    if not Rentals_Ready() then return false, 'not_ready' end
    -- An unregistered property (its map is mid-restart) would otherwise fall
    -- back to Config.Defaults: a cheaper price and a longer cap than the
    -- property actually sells.
    if not Properties[propId] then return false, 'no_access' end

    local identifier = FW.GetIdentifier(src)
    local roomId = identifier and Rentals_FindByRenter(identifier, propId)
    if not roomId then return false, 'not_renting' end

    local r = Rentals[roomId]
    local d = propDefaults(propId)
    days = sanitiseDays(days)
    if not days then return false, 'bad_days' end

    -- The cap is measured from now, so a lapsed rental can always be revived.
    local maxUntil = nowMs() + d.maxDays * DAY_MS
    local base = math.max(r.expiresAt, nowMs())
    local newExpiry = base + days * DAY_MS
    if newExpiry > maxUntil then return false, 'max_days' end

    local t = typeCfg(propId, r.rtype)
    local price = ((t and t.pricePerDay) or d.pricePerDay) * days

    return withRoomLock(roomId, function()
        -- Re-read inside the lock: a concurrent extend may have moved it, and
        -- rolling back to a value captured outside would erase their paid days.
        local cur = Rentals[roomId]
        if not cur then return false, 'not_renting' end

        local base2 = math.max(cur.expiresAt, nowMs())
        local target = base2 + days * DAY_MS
        if target > nowMs() + d.maxDays * DAY_MS then return false, 'max_days' end

        if not Money.Charge(src, price, 'hotel-rent') then return false, 'no_money' end

        local prev = cur.expiresAt
        cur.expiresAt = target
        if not Storage.Upsert(roomId, cur) then
            cur.expiresAt = prev
            if not Money.Refund(src, price, 'hotel-extend-failed') then
                print(('[prompt_hotel_system] ^1REFUND FAILED — %s charged %d to extend %s but the write failed. Refund by hand.^0')
                    :format(identifier, price, roomId))
            end
            return false, 'write_failed'
        end
        TriggerEvent(EV('roomExtended'), identifier, roomId, propId, days, price)
        return true, roomId
    end)
end

-- ── eviction ─────────────────────────────────────────────────────────────
function Rentals_Evict(roomId, reason)
    if not Rentals[roomId] then return false end

    -- Under the lock: an eviction overlapping an in-flight Upsert could delete
    -- the row and then have the completing write re-insert it.
    local r = withRoomLock(roomId, function()
        local cur = Rentals[roomId]
        if not cur then return nil end
        Rentals[roomId] = nil
        Storage.Delete(roomId)
        return cur
    end)
    if not r or r == false then return false end

    DoorsSetLocked(roomId, true)

    if propDefaults(r.propId).clearStashOnEviction then Inventory.Clear(roomId) end

    Rentals_SyncOccupancy()

    for _, srcStr in ipairs(GetPlayers()) do
        local psrc = tonumber(srcStr)
        local pid = FW.GetIdentifier(psrc)
        if pid == r.identifier then
            if reason == 'expired' then TriggerClientEvent(EV('client:notify'), psrc, 'evicted', 'error') end
            Rentals_SendAccessList(psrc, pid)
        elseif pid and r.guests[pid] then
            Rentals_SendAccessList(psrc, pid)
        end
    end

    TriggerEvent(EV('roomEvicted'), r.identifier, roomId, r.propId, reason)
    return true
end

function Rentals_End(src, propId)
    local identifier = FW.GetIdentifier(src)
    local roomId = identifier and Rentals_FindByRenter(identifier, propId)
    if not roomId then return false, 'not_renting' end
    Rentals_Evict(roomId, 'checkout')
    return true, roomId
end

function Rentals_ExpiryTick()
    local now = nowMs()
    for roomId, r in pairs(Rentals) do
        -- Only sweep rentals whose property is actually registered. A map
        -- stopped for maintenance would otherwise fall back to Config.Defaults
        -- and mass-evict its renters under the wrong grace period.
        if Properties[r.propId] then
            local grace = (propDefaults(r.propId).graceDays or 0) * DAY_MS
            if now > r.expiresAt + grace then Rentals_Evict(roomId, 'expired') end
        end
    end
end

-- Public wrapper so server/api.lua's write exports serialise on the same lock
-- as the internal paths, instead of racing them.
function Rentals_WithLock(roomId, fn)
    return withRoomLock(roomId, fn)
end

-- Rentals pointing at rooms that no longer exist. Reported, never auto-deleted:
-- the usual cause is a map that is simply not running right now, and silently
-- destroying paid rentals is far worse than leaving a row alone.
function Rentals_Orphans()
    local out = {}
    for roomId, r in pairs(Rentals) do
        if not Rooms[roomId] then
            out[#out + 1] = { roomId = roomId, propId = r.propId, identifier = r.identifier,
                              registered = Properties[r.propId] ~= nil }
        end
    end
    return out
end

-- ── guests ───────────────────────────────────────────────────────────────
function Rentals_AddGuest(src, propId, targetSrc)
    local identifier = FW.GetIdentifier(src)
    local roomId = identifier and Rentals_FindByRenter(identifier, propId)
    if not roomId then return false, 'not_renting' end

    local tid = FW.GetIdentifier(targetSrc)
    if not tid or tid == identifier then return false, 'no_access' end
    local name = FW.GetName(targetSrc)

    return withRoomLock(roomId, function()
        local r = Rentals[roomId]
        if not r then return false, 'not_renting' end
        if Util.Count(r.guests) >= propDefaults(propId).maxGuests then return false, 'guest_limit' end

        r.guests[tid] = name
        if not Storage.Upsert(roomId, r) then
            r.guests[tid] = nil
            return false, 'write_failed'
        end
        Rentals_SendAccessList(targetSrc, tid)
        return true, roomId
    end)
end

function Rentals_RemoveGuest(src, propId, guestIdentifier)
    local identifier = FW.GetIdentifier(src)
    local roomId = identifier and Rentals_FindByRenter(identifier, propId)
    if not roomId then return false, 'not_renting' end

    return withRoomLock(roomId, function()
        local r = Rentals[roomId]
        if not r then return false, 'not_renting' end

        -- No such guest: succeed without a database write. Otherwise a client
        -- can drive one write per second, forever, by revoking nobody.
        local prev = r.guests[guestIdentifier]
        if prev == nil then return true, roomId end

        r.guests[guestIdentifier] = nil
        if not Storage.Upsert(roomId, r) then
            r.guests[guestIdentifier] = prev
            return false, 'write_failed'
        end
        broadcastAccessTo(guestIdentifier)
        return true, roomId
    end)
end

-- ── boot ─────────────────────────────────────────────────────────────────
-- Driven by the storage event, not a fixed Wait: the DB read is async and a
-- timing guess here silently starts the server with zero rentals.
AddEventHandler(EV('storageReady'), function()
    for roomId, r in pairs(Storage.LoadAll()) do Rentals[roomId] = r end
    for roomId in pairs(Rentals) do DoorsSetLocked(roomId, true) end
    Rentals_SyncOccupancy()
    print(('[prompt_hotel_system] %d rental(s) active'):format(Util.Count(Rentals)))
end)

AddEventHandler(EV('propertyRegistered'), function() Rentals_SyncOccupancy() end)
AddEventHandler(EV('propertyUnregistered'), function() Rentals_SyncOccupancy() end)

CreateThread(function()
    while true do
        Wait(60000)
        Rentals_ExpiryTick()
    end
end)
