-- Persistence bridge: oxmysql when available, JSON otherwise, custom hooks if
-- you want your own layer.
--
-- fxmanifest has no `server_script '@oxmysql/lib/MySQL.lua'` on purpose: that
-- would make oxmysql a hard dependency, breaking standalone support. Exports
-- resolve at call time instead, so no database is not a startup failure.
--
-- `ready` gates every booking. Before storage finishes loading, a booking can
-- land in JSON and then get overwritten by the mysql load -- paid, "success", gone.
--
-- `healthy` is false only when the initial load failed, not when it came back
-- empty. Conflating the two frees every occupied room for the next renter.
Storage = { backend = 'json', ready = false, healthy = true }

local JSON_FILE = 'data/rooms.json'
local TABLE     = 'prompt_hotel_rentals'

local cache = {}      -- [roomId] = rental (authoritative in-memory copy)
local dirty = false

local DDL = [[
CREATE TABLE IF NOT EXISTS `prompt_hotel_rentals` (
  `room_id`     VARCHAR(128) NOT NULL,
  `property_id` VARCHAR(96) NOT NULL,
  `identifier`  VARCHAR(64) NOT NULL,
  `renter_name` VARCHAR(64)     NULL,
  `room_type`   VARCHAR(32)     NULL,
  `rented_at`   BIGINT      NOT NULL,
  `expires_at`  BIGINT      NOT NULL,
  `guests`      LONGTEXT        NULL,
  `data`        LONGTEXT        NULL,
  PRIMARY KEY (`room_id`),
  KEY `idx_prompt_hotel_identifier` (`identifier`),
  KEY `idx_prompt_hotel_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
]]

local function log(fmt, ...) print(('[prompt_hotel_system][storage] ' .. fmt):format(...)) end

-- Await wrapper over oxmysql's callback API.
--
-- The timeout isn't padding: oxmysql skips the callback on a query error (it
-- just prints), so without a deadline this coroutine would wedge forever.
--
-- Returns the query result on success, or nil on error/timeout.
local QUERY_TIMEOUT_MS = 10000

local function sql(query, params)
    local p = promise.new()
    local settled = false

    local function settle(v)
        if settled then return end
        settled = true
        p:resolve(v)
    end

    SetTimeout(QUERY_TIMEOUT_MS, function() settle({ failed = true }) end)

    local ok = pcall(function()
        exports.oxmysql:execute(query, params or {}, function(result)
            settle({ value = result })
        end)
    end)
    if not ok then return nil end

    local res = Citizen.Await(p)
    if res.failed or res.value == nil then
        log('^1query failed: %s^0', (query:gsub('%s+', ' ')):sub(1, 100))
        return nil
    end
    return res.value
end

-- ── json backend ─────────────────────────────────────────────────────────
local function jsonLoad()
    local raw = LoadResourceFile(GetCurrentResourceName(), JSON_FILE)
    if not raw then return {} end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then return {} end
    return data.rentals or {}
end

local function jsonSave()
    SaveResourceFile(GetCurrentResourceName(), JSON_FILE, json.encode({ rentals = cache }), -1)
end

-- ── mysql backend ────────────────────────────────────────────────────────
local function rowToRental(r)
    local guests = {}
    local data = {}
    if r.guests then local ok, v = pcall(json.decode, r.guests); if ok and type(v) == 'table' then guests = v end end
    if r.data   then local ok, v = pcall(json.decode, r.data);   if ok and type(v) == 'table' then data = v end end
    return {
        propId     = r.property_id,
        identifier = r.identifier,
        renterName = r.renter_name,
        rtype      = r.room_type,
        rentedAt   = tonumber(r.rented_at),
        expiresAt  = tonumber(r.expires_at),
        guests     = guests,
        data       = data,
    }
end

local function dbUpsert(roomId, r)
    local res = sql(([[
        INSERT INTO `%s` (room_id, property_id, identifier, renter_name, room_type,
                          rented_at, expires_at, guests, data)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE
            property_id = VALUES(property_id), identifier = VALUES(identifier),
            renter_name = VALUES(renter_name), room_type  = VALUES(room_type),
            rented_at   = VALUES(rented_at),   expires_at = VALUES(expires_at),
            guests      = VALUES(guests),      data       = VALUES(data)
    ]]):format(TABLE), {
        roomId, r.propId, r.identifier, r.renterName, r.rtype,
        r.rentedAt, r.expiresAt, json.encode(r.guests or {}), json.encode(r.data or {}),
    })
    return res ~= nil
end

-- ── boot ─────────────────────────────────────────────────────────────────
CreateThread(function()
    Wait(400)
    local want = Config.Persistence or 'auto'

    -- Waits for oxmysql instead of probing once: a single check at +400ms can miss
    -- a late `ensure oxmysql`, silently running the session on JSON -- and the next
    -- boot then finds mysql rows, skips migration, and discards what got booked.
    if want == 'auto' or want == 'mysql' then
        local waited = 0
        while GetResourceState('oxmysql') ~= 'started'
              and GetResourceState('oxmysql') ~= 'missing' and waited < 60000 do
            Wait(1000)
            waited = waited + 1000
        end
    end

    if want == 'custom' then
        Storage.backend = 'custom'
    elseif (want == 'auto' or want == 'mysql') and GetResourceState('oxmysql') == 'started' then
        sql(DDL)
        -- Verify with a real read. CREATE can silently no-op for a DB user that
        -- lacks the privilege, and a write-time failure is far worse than this.
        local probe = sql(('SELECT 1 AS ok FROM `%s` LIMIT 1'):format(TABLE))
        if probe ~= nil then
            Storage.backend = 'mysql'
        else
            log('^3could not create or read `%s`.^0', TABLE)
            log('Import prompt_hotel_system.sql into your database by hand, then restart.')
            log('Falling back to JSON so the hotel still works.')
            Storage.backend = 'json'
        end
    elseif want == 'mysql' then
        log("^3Persistence='mysql' but oxmysql is not started — using JSON^0")
    end

    if Storage.backend == 'mysql' then
        -- nil means the read FAILED. Treating that as "no rentals" marks every
        -- occupied room free and lets the next renter overwrite a live row.
        local rows = sql(('SELECT * FROM `%s`'):format(TABLE))
        if rows == nil then
            Storage.healthy = false
            log('^1could not read `%s` at boot. Renting is DISABLED until the next restart^0', TABLE)
            log('^1so that existing rentals are not overwritten. Check your database and restart.^0')
            TriggerEvent(EV('storageReady'))
            return
        end
        for _, r in ipairs(rows) do cache[r.room_id] = rowToRental(r) end

        -- One-time migration off the JSON file so nobody loses live rentals.
        if #rows == 0 then
            local old, n, skipped = jsonLoad(), 0, 0
            for roomId, r in pairs(old) do
                local ident = r.identifier or r.renter
                -- Room ids are 'resource:property:room'. Older builds wrote a bare 'f01_r22'
                -- with no property -- those can't be placed, so they're skipped, not failed.
                local propId = r.propId or r.loc
                if not propId then
                    local res, prop = roomId:match('^([^:]+):([^:]+):')
                    if res then propId = res .. ':' .. prop end
                end

                if ident and propId then
                    cache[roomId] = {
                        propId     = propId,
                        identifier = ident,
                        renterName = r.renterName,
                        rtype      = r.rtype,
                        rentedAt   = r.rentedAt or (os.time() * 1000),
                        expiresAt  = r.expiresAt or ((r.paidUntil or os.time()) * 1000),
                        guests     = type(r.guests) == 'table' and r.guests or {},
                        data       = r.data or {},
                    }
                    if dbUpsert(roomId, cache[roomId]) then
                        n = n + 1
                    else
                        cache[roomId] = nil
                        skipped = skipped + 1
                    end
                elseif ident then
                    skipped = skipped + 1
                end
            end

            if n > 0 or skipped > 0 then
                SaveResourceFile(GetCurrentResourceName(), JSON_FILE .. '.imported',
                    json.encode({ rentals = old }), -1)
                SaveResourceFile(GetCurrentResourceName(), JSON_FILE, json.encode({ rentals = {} }), -1)
                log('migrated %d rental(s) from JSON into `%s`', n, TABLE)
                if skipped > 0 then
                    log('^3skipped %d legacy rental(s) with no property id — kept in %s.imported^0',
                        skipped, JSON_FILE)
                end
            end
        end
    elseif Storage.backend == 'json' then
        cache = jsonLoad()
    elseif Storage.backend == 'custom' then
        if CustomStorage and CustomStorage.load then
            cache = CustomStorage.load() or {}
        else
            log("^1Persistence='custom' but CustomStorage.load is not defined — starting empty^0")
        end
    end

    Storage.ready = true
    log('backend=%s, %d rental(s) loaded', Storage.backend, Util.Count(cache))
    TriggerEvent(EV('storageReady'))
end)

function Storage.Backend() return Storage.backend end
function Storage.LoadAll() return cache end

-- Bookings are refused until this is true.
function Storage.Ready() return Storage.ready and Storage.healthy end

function Storage.Upsert(roomId, rental)
    -- debug-only fault injection, so the rollback path is testable
    if Config.Debug and Storage.__failNextUpsert then
        Storage.__failNextUpsert = nil
        return false
    end

    if Storage.backend == 'mysql' then
        if not dbUpsert(roomId, rental) then return false end
        cache[roomId] = rental
        return true
    end
    if Storage.backend == 'custom' then
        if not (CustomStorage and CustomStorage.save) then
            log("^1Persistence='custom' but CustomStorage.save is not defined — rental NOT saved^0")
            return false
        end
        if CustomStorage.save(roomId, rental) ~= true then return false end
        cache[roomId] = rental
        return true
    end
    cache[roomId] = rental
    dirty = true
    return true
end

function Storage.Delete(roomId)
    cache[roomId] = nil
    if Storage.backend == 'mysql' then
        if sql(('DELETE FROM `%s` WHERE room_id = ?'):format(TABLE), { roomId }) ~= nil then
            return true
        end
        -- The row may still be there. Say so loudly -- silently succeeding means the
        -- "evicted" player gets the room back next restart, or collides with the next renter.
        log('^1DELETE failed for %s — the row may still exist. '
            .. 'Remove it by hand if the room comes back after a restart.^0', roomId)
        return false
    end
    if Storage.backend == 'custom' then
        if not (CustomStorage and CustomStorage.delete) then return false end
        return CustomStorage.delete(roomId) == true
    end
    dirty = true
    return true
end

function Storage.FlushNow()
    if Storage.backend == 'json' and dirty then
        jsonSave()
        dirty = false
    end
end

CreateThread(function()
    while true do
        Wait(5000)
        Storage.FlushNow()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and Storage.backend == 'json' then jsonSave() end
end)
