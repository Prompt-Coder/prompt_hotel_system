-- Runtime property registration.
--
-- This file knows the SHAPE of a property. It must never know a specific one:
-- no coordinates, no map names, no room lists. Everything concrete arrives
-- through RegisterProperty() from the map that owns it.
Properties = {}   -- [propId] = resolved property
Rooms      = {}   -- [roomId] = { propId, floor, slot, num, variant, rtype, origin, door, ipl }

Registry = {}

-- Well-known discovery key. Maps read this instead of guessing our resource
-- name: escrow renames resources and customers rename folders, so any
-- name-matching scheme eventually picks the wrong resource or none at all.
local DISCOVERY_KEY = 'prompt_hotel_system'

local reserved = {}   -- [roomId] = expiry (GetGameTimer ms)

local function log(fmt, ...) print(('[prompt_hotel_system] ' .. fmt):format(...)) end

-- Expansion lives in shared/rooms.lua so the client derives exactly the same
-- rooms from the same property data, instead of us shipping both the inputs
-- and the outputs.
local function expand(propId, prop)
    for roomId, room in pairs(RoomsExpand(propId, prop, log)) do
        Rooms[roomId] = room
    end
end

local function clearRooms(propId)
    for roomId, room in pairs(Rooms) do
        if room.propId == propId then Rooms[roomId] = nil end
    end
end

-- Replication.
--
-- The registry never travels in a statebag: at ~340KB FiveM silently drops the
-- value. A revision counter replicates; clients pull the payload via callback.
local revision = 0
local clientView = { rev = 0, properties = {} }

-- Only properties go over the wire; rooms are derived client-side from
-- shared/rooms.lua -- sending both was ~300KB of the inputs' own outputs.
function Registry.Replicate()
    revision = revision + 1
    clientView = { rev = revision, properties = Properties }
    GlobalState[KEY('rev')] = revision
end

function Registry.ClientView() return clientView end

lib.callback.register(EV('getRegistry'), function()
    return clientView
end)

-- ── reservations ─────────────────────────────────────────────────────────
-- A short-lived claim taken BEFORE money moves. Two rent calls in the same
-- tick therefore cannot both be handed room 101.
function Registry.IsReserved(roomId)
    local until_ = reserved[roomId]
    if not until_ then return false end
    if GetGameTimer() > until_ then
        reserved[roomId] = nil
        return false
    end
    return true
end

-- Must outlive the database deadline in bridges/persistence.lua, or a slow
-- write can time out just as the claim expires and double-book the room.
local RESERVE_TTL_MS = 45000

function Registry.Reserve(propId, rtype)
    local roomId = Registry.FindFree(propId, rtype)
    if not roomId then return nil end
    reserved[roomId] = GetGameTimer() + RESERVE_TTL_MS
    return roomId
end

function Registry.Release(roomId)
    if roomId then reserved[roomId] = nil end
end

-- lowest floor / lowest number first, so early guests get the easy rooms
function Registry.FindFree(propId, rtype)
    local best, bestKey
    for roomId, room in pairs(Rooms) do
        if room.propId == propId and room.rtype == rtype
           and not (Rentals and Rentals[roomId]) and not Registry.IsReserved(roomId) then
            local key = (room.floor or 1) * 1000 + (room.slot or 0)
            if not bestKey or key < bestKey then best, bestKey = roomId, key end
        end
    end
    return best
end

function Registry.RoomsOf(propId)
    local out = {}
    for roomId, room in pairs(Rooms) do
        if room.propId == propId then out[roomId] = room end
    end
    return out
end

-- ── registration ─────────────────────────────────────────────────────────
local function register(id, payload)
    local caller = GetInvokingResource() or GetCurrentResourceName()
    if type(id) ~= 'string' or id == '' then
        log('RegisterProperty from %s: id must be a non-empty string', caller)
        return false, 'bad id'
    end
    local propId = ('%s:%s'):format(caller, id)

    local resolved, errStr, warnings = Schema.Validate(payload, caller)
    for _, w in ipairs(warnings or {}) do log('%s: %s', propId, w) end
    if not resolved then
        log('^3REJECTED %s: %s^0', propId, errStr)
        return false, errStr
    end

    if resolved.requires and GetResourceState(resolved.requires) ~= 'started' then
        log("%s skipped — required resource '%s' is not started", propId, resolved.requires)
        return false, 'requires not started'
    end

    -- cascade layer 3: the server owner's word wins over the map's
    local ov = Config.Overrides[propId]
    if ov then
        for k, v in pairs(ov) do
            if k == 'prices' then
                -- per-room-type: prices = { standard = 250, premium = 500 }
                for _, t in ipairs(resolved.roomTypes) do
                    if v[t.id] then t.pricePerDay = v[t.id] end
                end
            elseif k == 'pricePerDay' then
                -- blanket price. Also stamped onto every roomType, because a
                -- roomType's own price wins at charge time -- without this the
                -- documented one-liner would silently do nothing.
                resolved.defaults.pricePerDay = v
                for _, t in ipairs(resolved.roomTypes) do t.pricePerDay = v end
            elseif k == 'bar' and type(v) == 'table' and type(resolved.bar) == 'table' then
                -- MERGE: an owner changing only drink prices must not lose the
                -- map's bartender positions.
                for bk, bv in pairs(v) do resolved.bar[bk] = bv end
            elseif k == 'reception' and type(v) == 'table' and type(resolved.reception) == 'table' then
                -- MERGE, don't replace. An owner moving the desk writes only
                -- `reception = { coords = ... }`; replacing wholesale drops the
                -- ped model and joaat(nil) then throws client-side.
                for rk, rv in pairs(v) do resolved.reception[rk] = rv end
            elseif k == 'streaming' then
                if v == 'map' or v == 'script' or v == 'none' then
                    resolved.streaming = v
                else
                    log("^3override for %s: streaming '%s' is not valid — ignored^0", propId, tostring(v))
                end
            elseif resolved[k] ~= nil or k == 'blip' or k == 'rentedBlip' or k == 'reception' then
                resolved[k] = v
            else
                resolved.defaults[k] = v
            end
        end
    end

    -- Expand BEFORE publishing. Publishing first left a zombie property with
    -- zero rooms visible to every client if expansion then failed.
    clearRooms(propId)
    local okExpand, expandErr = pcall(expand, propId, resolved)
    if not okExpand then
        clearRooms(propId)
        log('^1REJECTED %s: %s^0', propId, tostring(expandErr))
        return false, tostring(expandErr)
    end

    local n = Util.Count(Registry.RoomsOf(propId))
    if n == 0 then
        clearRooms(propId)
        log('^3REJECTED %s: it produced 0 rooms — check every room\'s variant^0', propId)
        return false, 'no rooms'
    end

    Properties[propId] = resolved
    log("registered '%s' (%s) — %d rooms, streaming=%s", resolved.label, propId, n, resolved.streaming)

    Registry.Replicate()
    TriggerEvent(EV('propertyRegistered'), propId, resolved.label, n)
    return true
end

-- The export wrapper. A map calling this must never receive an error, or an
-- exception here aborts every later RegisterProperty call from that map.
exports('RegisterProperty', function(id, payload)
    local ok, a, b = pcall(register, id, payload)
    if ok then return a, b end
    log('^1RegisterProperty(%s) crashed: %s^0', tostring(id), tostring(a))
    log('^1The property was not registered. Every other property is unaffected.^0')
    return false, tostring(a)
end)

exports('AddRooms', function(id, rooms)
    local caller = GetInvokingResource() or GetCurrentResourceName()
    local propId = ('%s:%s'):format(caller, id)
    local prop = Properties[propId]
    if not prop then return false, 'property not registered' end
    if type(rooms) ~= 'table' then return false, 'rooms must be a list' end

    -- Mirrors RegisterProperty's validation: this path doesn't go through
    -- Schema, so the same bad payloads must be caught here too.
    for i, r in ipairs(rooms) do
        if type(r) ~= 'table' then return false, ('room #%d must be a table'):format(i) end
        if tonumber(r.num) == nil then return false, ("room #%d needs a numeric 'num'"):format(i) end
        local o = r.origin
        if type(o) ~= 'table' and type(o) ~= 'vector4' then
            return false, ("room #%d needs a vec4 'origin'"):format(i)
        end
        if o.x == nil or o.y == nil or o.z == nil or o.w == nil then
            return false, ("room #%d: 'origin' must be a vec4 with a heading"):format(i)
        end
        local variant = r.variant or prop.variant
        if not variant or not prop.variants[variant] then
            return false, ("room #%d uses unknown variant '%s'"):format(i, tostring(variant))
        end
    end

    local ok, e = pcall(function()
        for _, r in ipairs(rooms) do
            local floor = r.floor or 1
            addRoom(propId, prop, ('f%02d_r%s'):format(floor, tostring(r.num)), {
                floor = floor, slot = r.num, num = r.num,
                variant = r.variant or prop.variant, origin = r.origin, ipl = r.ipl,
            })
        end
    end)
    if not ok then
        log('^1AddRooms(%s) crashed: %s^0', tostring(id), tostring(e))
        return false, tostring(e)
    end

    Registry.Replicate()
    TriggerEvent(EV('propertyRegistered'), propId, prop.label, Util.Count(Registry.RoomsOf(propId)))
    return true
end)

exports('SetProperty', function(id, partial)
    local caller = GetInvokingResource() or GetCurrentResourceName()
    local propId = ('%s:%s'):format(caller, id)
    local prop = Properties[propId]
    if not prop then return false, 'property not registered' end
    for k, v in pairs(partial or {}) do prop[k] = v end
    Registry.Replicate()
    return true
end)

exports('UnregisterProperty', function(id)
    local caller = GetInvokingResource() or GetCurrentResourceName()
    local propId = ('%s:%s'):format(caller, id)
    if not Properties[propId] then return false end
    Properties[propId] = nil
    clearRooms(propId)
    Registry.Replicate()
    log('unregistered %s (rentals kept in storage)', propId)
    TriggerEvent(EV('propertyUnregistered'), propId)
    return true
end)

-- A map stopping drops its property but NEVER its rentals: restarting a map
-- must not evict anybody.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then
        GlobalState[DISCOVERY_KEY] = nil
        return
    end
    local dropped = false
    for propId, prop in pairs(Properties) do
        if prop.source == res then
            Properties[propId] = nil
            clearRooms(propId)
            dropped = true
            log('unregistered %s — %s stopped (rentals kept)', propId, res)
            TriggerEvent(EV('propertyUnregistered'), propId)
        end
    end
    if dropped then Registry.Replicate() end
end)

CreateThread(function()
    -- Clear keys from older builds so a stale value cannot be mistaken for live
    -- data after an update.
    GlobalState[KEY('registry')] = nil
    GlobalState[KEY('properties')] = nil
    GlobalState[KEY('rooms')] = nil

    Registry.Replicate()

    -- Published last, so a map that reads it can register immediately.
    GlobalState[DISCOVERY_KEY] = GetCurrentResourceName()
    log('ready — discovery key GlobalState[\'%s\'] = %s', DISCOVERY_KEY, GetCurrentResourceName())

    -- Also announced as an event: a poller can miss a fast restart, since the
    -- key clears and republishes within the same second. The event name is a
    -- fixed literal, not namespaced, so a map can listen without knowing ours.
    TriggerEvent('prompt_hotel_system:coreReady', GetCurrentResourceName())
end)
