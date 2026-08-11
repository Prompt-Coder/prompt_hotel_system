-- The RegisterProperty contract: validation is TOLERANT. An unknown key is
-- a warning, never a rejection, so a map built for a newer prompt_hotel_system
-- still works on an older one, minus the new feature. Only a genuinely
-- unusable property is rejected, and only that property.
Schema = {}

-- Highest payload version this engine understands. Tolerance covers additive
-- change; it cannot cover a genuine breaking one, so a map that declares a
-- newer schema is rejected with a reason rather than producing broken rooms.
Schema.MAX = 1

local KNOWN = {
    schema = true, label = true, requires = true, blip = true, rentedBlip = true,
    reception = true, streaming = true, rooms = true, layout = true, variants = true,
    roomTypes = true, elevators = true, defaults = true, bar = true,
}

-- Accepted so a map can ship them ahead of engine support, but they do nothing
-- yet. Silently ignoring a documented key is worse than saying so once.
local NOT_YET_IMPLEMENTED = {}

local STREAMING = { map = true, script = true, none = true }

local function err(fmt, ...) return nil, fmt:format(...) end

-- Returns: resolved | nil, errString, warnings[]
function Schema.Validate(raw, sourceResource)
    if type(raw) ~= 'table' then
        return err('property payload must be a table, got %s', type(raw))
    end

    local warnings = {}
    for k in pairs(raw) do
        if NOT_YET_IMPLEMENTED[k] then
            warnings[#warnings + 1] = ("'%s' is accepted but not implemented yet — it does nothing"):format(k)
        elseif not KNOWN[k] then
            warnings[#warnings + 1] =
                ("unknown key '%s' ignored (this map may expect a newer prompt_hotel_system)"):format(k)
        end
    end

    if type(raw.label) ~= 'string' or raw.label == '' then
        return err("missing required field 'label' (string)")
    end

    local schemaVer = tonumber(raw.schema) or 1
    if schemaVer > Schema.MAX then
        return err("property '%s' declares schema %d but this prompt_hotel_system understands up to %d — update the script",
            raw.label, schemaVer, Schema.MAX)
    end
    if not raw.rooms and not raw.layout then
        return err("property '%s' needs either 'rooms' (list) or 'layout' (generator)", raw.label)
    end
    if raw.rooms ~= nil and type(raw.rooms) ~= 'table' then
        return err("property '%s': 'rooms' must be a list", raw.label)
    end
    if raw.rooms and not raw.layout and #raw.rooms == 0 then
        return err("property '%s': 'rooms' is empty and no 'layout' was given", raw.label)
    end

    if type(raw.variants) ~= 'table' or next(raw.variants) == nil then
        return err("property '%s' needs at least one entry in 'variants'", raw.label)
    end
    for vid, v in pairs(raw.variants) do
        if type(v) ~= 'table' or v.door == nil then
            return err("variant '%s' needs a 'door' offset (vec3)", tostring(vid))
        end
    end

    if type(raw.roomTypes) ~= 'table' or #raw.roomTypes == 0 then
        return err("property '%s' needs at least one entry in 'roomTypes'", raw.label)
    end
    for _, t in ipairs(raw.roomTypes) do
        if type(t.id) ~= 'string' or t.id == '' then
            return err("property '%s': every roomType needs a string 'id'", raw.label)
        end
        -- 'variants' may only be omitted on a single-type property. With two or
        -- more types the first one without it silently claims every variant, so
        -- a premium room quietly sells at the standard price.
        if t.variants == nil then
            if #raw.roomTypes > 1 then
                return err("roomType '%s' has no 'variants' — required when a property sells more than one type", t.id)
            end
        elseif type(t.variants) ~= 'table' or #t.variants == 0 then
            return err("roomType '%s': 'variants' must be a non-empty list", t.id)
        else
            for _, vid in ipairs(t.variants) do
                if not raw.variants[vid] then
                    return err("roomType '%s' references unknown variant '%s'", t.id, tostring(vid))
                end
            end
        end
    end

    -- Exactly one variant means rooms may omit 'variant'.
    local onlyVariant
    for vid in pairs(raw.variants) do
        if onlyVariant then onlyVariant = nil break end
        onlyVariant = vid
    end

    -- Room-level checks. These exist because the alternative is an uncaught
    -- error inside RotateOffset that aborts the map's whole registration run
    -- and prints nothing anybody can act on.
    local function checkOrigin(where, o)
        if type(o) ~= 'vector4' and type(o) ~= 'table' then
            return err("%s: 'origin' must be a vec4(x, y, z, heading), got %s", where, type(o))
        end
        if o.x == nil or o.y == nil or o.z == nil or o.w == nil then
            return err("%s: 'origin' must be a vec4 with a heading — vec3 has no .w", where)
        end
        return true
    end

    local seen = {}
    for i, r in ipairs(raw.rooms or {}) do
        local where = ("property '%s' room #%d"):format(raw.label, i)
        if type(r) ~= 'table' then return err('%s must be a table', where) end
        if tonumber(r.num) == nil then return err("%s needs a numeric 'num'", where) end
        local ok, e = checkOrigin(where, r.origin)
        if not ok then return nil, e end

        local variant = r.variant or onlyVariant
        if not variant then
            return err("%s needs a 'variant' (the property defines more than one)", where)
        end
        if not raw.variants[variant] then
            return err("%s uses unknown variant '%s'", where, tostring(variant))
        end

        local key = ('%s_%s'):format(r.floor or 1, r.num)
        if seen[key] then
            return err("%s duplicates floor %s room %s — room numbers must be unique",
                where, tostring(r.floor or 1), tostring(r.num))
        end
        seen[key] = true
    end

    local L = raw.layout
    if L ~= nil then
        if type(L) ~= 'table' then return err("property '%s': 'layout' must be a table", raw.label) end
        if L.mode ~= 'floors' then
            return err("property '%s': layout.mode must be 'floors' (got '%s')", raw.label, tostring(L.mode))
        end
        if tonumber(L.floors) == nil or L.floors < 1 then
            return err("property '%s': layout.floors must be a positive number", raw.label)
        end
        if tonumber(L.zStep) == nil then
            return err("property '%s': layout.zStep must be a number (metres between floors)", raw.label)
        end
        if type(L.slots) ~= 'table' or #L.slots == 0 then
            return err("property '%s': layout.slots must be a non-empty list", raw.label)
        end
        for i, s in ipairs(L.slots) do
            local where = ("property '%s' slot #%d"):format(raw.label, i)
            if type(s) ~= 'table' then return err('%s must be a table', where) end
            if tonumber(s.slot) == nil then return err("%s needs a numeric 'slot'", where) end
            local ok, e = checkOrigin(where, s.origin)
            if not ok then return nil, e end
            local variant = s.variant or onlyVariant
            if not variant then
                return err("%s needs a 'variant' (the property defines more than one)", where)
            end
            if not raw.variants[variant] then
                return err("%s uses unknown variant '%s'", where, tostring(variant))
            end
        end
        if raw.rooms and #raw.rooms > 0 then
            return err("property '%s' declares both 'rooms' and 'layout' — pick one, "
                .. 'or the generated rooms are silently overwritten', raw.label)
        end
    end

    if raw.streaming ~= nil and not STREAMING[raw.streaming] then
        return err("streaming must be 'map', 'script' or 'none', got '%s'", tostring(raw.streaming))
    end

    -- ── bar ──────────────────────────────────────────────────────────────
    -- The map supplies spawn points; everything else falls back to Config.Bar,
    -- so a hotel gets a working bar by sending coordinates and nothing else.
    local bar
    if raw.bar ~= nil and raw.bar ~= false then
        if type(raw.bar) ~= 'table' then
            return err("property '%s': 'bar' must be a table (or false)", raw.label)
        end
        if type(raw.bar.bartenders) ~= 'table' or #raw.bar.bartenders == 0 then
            return err("property '%s': bar.bartenders must be a non-empty list of vec4 spawn points",
                raw.label)
        end

        bar = {}
        for k, v in pairs(Config.Bar) do bar[k] = v end          -- engine defaults
        for k, v in pairs(raw.bar) do bar[k] = v end             -- the map's own

        -- Normalise to { index, coords }: a map may send a bare vec4 or a
        -- table carrying a coords field.
        local list = {}
        for i, t in ipairs(raw.bar.bartenders) do
            local c = (type(t) == 'table' and t.coords) or t
            if c == nil or c.x == nil or c.w == nil then
                return err("property '%s': bar.bartenders[%d] must be a vec4 (x, y, z, heading)",
                    raw.label, i)
            end
            list[i] = { index = i, coords = c }
        end
        bar.bartenders = list

        if type(bar.drinks) ~= 'table' or #bar.drinks == 0 then
            return err("property '%s': bar.drinks must be a non-empty list", raw.label)
        end
        for i, d in ipairs(bar.drinks) do
            if type(d) ~= 'table' or type(d.label) ~= 'string' or tonumber(d.price) == nil then
                return err("property '%s': bar.drinks[%d] needs a string 'label' and a numeric 'price'",
                    raw.label, i)
            end
        end
    end

    -- cascade layers 1 and 2. Layer 3 (Config.Overrides) is applied in
    -- server/registry.lua, because it is keyed by the final namespaced id.
    local defaults = {}
    for k, v in pairs(Config.Defaults) do defaults[k] = v end
    for k, v in pairs(raw.defaults or {}) do defaults[k] = v end

    return {
        schema     = schemaVer,
        label      = raw.label,
        variant    = onlyVariant,       -- default for rooms that omit one
        source     = sourceResource,
        requires   = raw.requires,
        streaming  = raw.streaming or 'map',
        blip       = raw.blip,
        rentedBlip = raw.rentedBlip,
        reception  = raw.reception,
        rooms      = raw.rooms,
        layout     = raw.layout,
        variants   = raw.variants,
        roomTypes  = raw.roomTypes,
        elevators  = raw.elevators or {},
        bar        = bar,
        defaults   = defaults,
    }, nil, warnings
end
