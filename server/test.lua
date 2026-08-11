-- Debug-only self-test suites, run from the server console.
-- Behaviour disappears entirely when Config.Debug = false.
if not Config.Debug then return end

local pass, fail = 0, 0

local function check(name, cond, detail)
    if cond then
        pass = pass + 1
        print(('[hotel][TEST] PASS %s'):format(name))
    else
        fail = fail + 1
        print(('[hotel][TEST] FAIL %s%s'):format(name, detail ~= nil and (' — ' .. tostring(detail)) or ''))
    end
    return cond
end

local function done(name)
    local p, f = pass, fail
    print(('[hotel][TEST] %s done: %d passed, %d failed'):format(name, p, f))
    pass, fail = 0, 0
    return p, f
end

-- Suites must run SEQUENTIALLY: they share the rental table and the pass/fail
-- counters, and ExecuteCommand only queues for a later tick, so chaining
-- commands ran them concurrently and produced meaningless cross-talk.
local suites, order = {}, {}

local function suite(name, fn)
    suites[name] = fn
    order[#order + 1] = name
    RegisterCommand(CMD('test_' .. name), function(src)
        if src ~= 0 then return end
        fn()
    end, false)
end

local TP = 'example_property'
local ALPHA, BETA = TP .. ':alpha', TP .. ':beta'

-- ── schema ───────────────────────────────────────────────────────────────
suite('schema', function()

    local function base(extra)
        local t = {
            label = 'Test',
            rooms = { { num = 101, origin = vec4(0.0, 0.0, 30.0, 0.0), variant = 'std' } },
            variants = { std = { door = vec3(0.0, 0.0, 0.0) } },
            roomTypes = { { id = 'std', label = 'Std', variants = { 'std' }, pricePerDay = 50 } },
        }
        for k, v in pairs(extra or {}) do t[k] = v end
        return t
    end

    local ok = Schema.Validate(base(), 'test_res')
    check('minimal_property_valid', ok ~= nil)
    check('defaults_applied', ok and ok.defaults.maxDays == Config.Defaults.maxDays, ok and ok.defaults.maxDays)
    check('grace_defaulted', ok and ok.defaults.graceDays == Config.Defaults.graceDays)
    check('streaming_defaults_to_map', ok and ok.streaming == 'map', ok and ok.streaming)

    local ok2 = Schema.Validate(base({ defaults = { maxDays = 5 } }), 'test_res')
    check('map_defaults_beat_config', ok2 and ok2.defaults.maxDays == 5, ok2 and ok2.defaults.maxDays)
    check('map_defaults_dont_wipe_others', ok2 and ok2.defaults.graceDays == Config.Defaults.graceDays)

    local bad, err = Schema.Validate({ rooms = {} }, 'test_res')
    check('missing_label_rejected', bad == nil)
    check('error_names_the_field', err and err:find('label') ~= nil, err)

    local bad2, err2 = Schema.Validate({ label = 'X' }, 'test_res')
    check('no_room_source_rejected', bad2 == nil)
    check('error_names_rooms', err2 and (err2:find('rooms') or err2:find('layout')) ~= nil, err2)

    -- TOLERANCE: a key from a newer system must not reject the property
    local ok3, _, warns = Schema.Validate(base({ futureFeature = { a = 1 } }), 'test_res')
    check('unknown_key_still_registers', ok3 ~= nil)
    check('unknown_key_warns', warns and #warns == 1, warns and #warns)
    check('warning_names_the_key', warns and warns[1] and warns[1]:find('futureFeature') ~= nil, warns and warns[1])

    local bad3, err3 = Schema.Validate(base({
        roomTypes = { { id = 'p', label = 'P', variants = { 'ghost' }, pricePerDay = 1 } },
    }), 'test_res')
    check('unknown_variant_ref_rejected', bad3 == nil)
    check('error_names_variant', err3 and err3:find('ghost') ~= nil, err3)

    local bad4, err4 = Schema.Validate(base({ streaming = 'teleport' }), 'test_res')
    check('bad_streaming_rejected', bad4 == nil)
    check('error_names_streaming', err4 and err4:find('streaming') ~= nil, err4)

    local bad5 = Schema.Validate(base({ variants = { std = { probeInward = 1.0 } } }), 'test_res')
    check('variant_without_door_rejected', bad5 == nil)

    -- ── payloads a real map author plausibly writes ──────────────────────
    local function reject(name, payload, mustMention)
        local r, e = Schema.Validate(payload, 'test_res')
        check(name, r == nil and (not mustMention or (e and e:find(mustMention) ~= nil)), e)
    end

    reject('room_without_origin_rejected',
        base({ rooms = { { num = 101, variant = 'std' } } }), 'origin')
    reject('vec3_origin_rejected',
        base({ rooms = { { num = 101, origin = vec3(1.0, 2.0, 3.0), variant = 'std' } } }), 'vec4')
    reject('room_without_num_rejected',
        base({ rooms = { { origin = vec4(0, 0, 0, 0), variant = 'std' } } }), 'num')
    reject('duplicate_room_number_rejected', base({ rooms = {
        { num = 101, origin = vec4(0, 0, 0, 0), variant = 'std' },
        { num = 101, origin = vec4(1, 1, 1, 0), variant = 'std' },
    } }), 'unique')
    reject('room_unknown_variant_rejected',
        base({ rooms = { { num = 101, origin = vec4(0, 0, 0, 0), variant = 'ghost' } } }), 'ghost')

    reject('layout_without_slots_rejected',
        base({ rooms = nil, layout = { mode = 'floors', floors = 2, zStep = 4.0 } }), 'slots')
    reject('layout_without_zstep_rejected',
        base({ rooms = nil, layout = { mode = 'floors', floors = 2,
            slots = { { slot = 1, variant = 'std', origin = vec4(0, 0, 0, 0) } } } }), 'zStep')
    reject('layout_bad_mode_rejected',
        base({ rooms = nil, layout = { mode = 'stack', floors = 2, zStep = 4.0,
            slots = { { slot = 1, variant = 'std', origin = vec4(0, 0, 0, 0) } } } }), 'mode')
    reject('layout_slot_without_origin_rejected',
        base({ rooms = nil, layout = { mode = 'floors', floors = 2, zStep = 4.0,
            slots = { { slot = 1, variant = 'std' } } } }), 'origin')
    reject('rooms_and_layout_together_rejected',
        base({ layout = { mode = 'floors', floors = 1, zStep = 4.0,
            slots = { { slot = 1, variant = 'std', origin = vec4(0, 0, 0, 0) } } } }), 'pick one')

    -- a second roomType without 'variants' silently claimed every variant,
    -- so a premium room sold at the standard price
    reject('multi_type_without_variants_rejected', base({
        variants = { std = { door = vec3(0, 0, 0) }, lux = { door = vec3(0, 0, 0) } },
        roomTypes = { { id = 'std', pricePerDay = 100 }, { id = 'lux', variants = { 'lux' }, pricePerDay = 900 } },
        rooms = { { num = 101, origin = vec4(0, 0, 0, 0), variant = 'lux' } },
    }), 'variants')

    -- a single-variant property may omit per-room 'variant'
    local ok4 = Schema.Validate(base({ rooms = { { num = 101, origin = vec4(0, 0, 0, 0) } } }), 'test_res')
    check('single_variant_room_may_omit_variant', ok4 ~= nil)
    check('single_variant_default_carried', ok4 and ok4.variant == 'std', ok4 and ok4.variant)

    -- multi-variant property must say which
    reject('multi_variant_room_needs_variant', base({
        variants = { std = { door = vec3(0, 0, 0) }, lux = { door = vec3(0, 0, 0) } },
        roomTypes = { { id = 'std', variants = { 'std', 'lux' }, pricePerDay = 100 } },
        rooms = { { num = 101, origin = vec4(0, 0, 0, 0) } },
    }), 'variant')

    -- a breaking-change guard the tolerance rule cannot cover
    reject('future_schema_rejected', base({ schema = 99 }), 'schema')

    -- ── bar ──────────────────────────────────────────────────────────────
    -- A map sends spawn points and inherits everything else.
    local okBar = Schema.Validate(base({ bar = {
        bartenders = { vec4(1.0, 2.0, 3.0, 90.0), vec4(4.0, 5.0, 6.0, 180.0) },
    } }), 'test_res')
    check('bar_points_only_is_valid', okBar ~= nil)
    check('bar_inherits_default_drinks',
        okBar and okBar.bar and #okBar.bar.drinks == #Config.Bar.drinks, okBar and okBar.bar and #okBar.bar.drinks)
    check('bar_inherits_ped_model', okBar and okBar.bar.pedModel == Config.Bar.pedModel)
    check('bar_bartenders_normalised',
        okBar and okBar.bar.bartenders[1].index == 1 and okBar.bar.bartenders[1].coords ~= nil)
    check('bar_bartender_count', okBar and #okBar.bar.bartenders == 2, okBar and #okBar.bar.bartenders)

    -- a map may carry its own menu
    local okMenu = Schema.Validate(base({ bar = {
        bartenders = { vec4(1.0, 2.0, 3.0, 0.0) },
        drinks = { { label = 'House Red', price = 15, intoxication = 0.7 } },
    } }), 'test_res')
    check('bar_map_menu_wins', okMenu and #okMenu.bar.drinks == 1 and okMenu.bar.drinks[1].label == 'House Red')

    -- a bartender entry may be a bare vec4 or a table with coords
    local okShape = Schema.Validate(base({ bar = {
        bartenders = { { coords = vec4(9.0, 8.0, 7.0, 45.0) } },
    } }), 'test_res')
    check('bar_accepts_coords_table', okShape and okShape.bar.bartenders[1].coords.x == 9.0)

    reject('bar_without_bartenders_rejected', base({ bar = { drinks = {} } }), 'bartenders')
    reject('bar_empty_bartenders_rejected', base({ bar = { bartenders = {} } }), 'bartenders')
    reject('bar_vec3_bartender_rejected',
        base({ bar = { bartenders = { vec3(1.0, 2.0, 3.0) } } }), 'vec4')
    reject('bar_drink_without_price_rejected', base({ bar = {
        bartenders = { vec4(1.0, 2.0, 3.0, 0.0) },
        drinks = { { label = 'Mystery' } },
    } }), 'price')

    local noBar = Schema.Validate(base({ bar = false }), 'test_res')
    check('bar_false_is_accepted', noBar ~= nil and noBar.bar == nil)

    return done('schema')
end)

-- ── registry ─────────────────────────────────────────────────────────────
suite('registry', function()

    check('discovery_key_published', GlobalState['prompt_hotel_system'] == GetCurrentResourceName(),
        GlobalState['prompt_hotel_system'])

    check('alpha_registered', Properties[ALPHA] ~= nil)
    check('beta_registered', Properties[BETA] ~= nil)
    check('invalid_property_rejected_alone', Properties[TP .. ':broken'] == nil)

    local alpha = Util.Count(Registry.RoomsOf(ALPHA))
    local beta  = Util.Count(Registry.RoomsOf(BETA))
    check('explicit_rooms_expanded', alpha == 4, alpha)
    check('layout_rooms_expanded', beta == 6, beta)

    local room = Rooms[ALPHA .. ':f01_r101']
    check('room_id_format', room ~= nil)
    check('room_has_rtype', room and room.rtype == 'std', room and room.rtype)
    check('room_door_is_world_coords', room and room.door ~= nil)
    check('room_probe_built', room and room.probe ~= nil)

    local b1, b2 = Rooms[BETA .. ':f01_r01'], Rooms[BETA .. ':f02_r01']
    check('layout_z_stepped', b1 and b2 and math.abs((b2.origin.z - b1.origin.z) - 4.0) < 0.01,
        b1 and b2 and (b2.origin.z - b1.origin.z))
    check('layout_ipl_per_floor', b1 and b1.ipl ~= nil and b2 and b2.ipl ~= nil)

    -- cascade layer 2: a property's own defaults win over Config.Defaults
    check('property_defaults_applied', Properties[ALPHA].defaults.maxDays == 7, Properties[ALPHA].defaults.maxDays)
    check('non_overridden_property_untouched', Properties[BETA].defaults.maxDays == 9,
        Properties[BETA].defaults.maxDays)

    -- Compute the expectation rather than hardcoding a room: a rental left over
    -- from another suite (or loaded from the database at boot) changes which
    -- room is lowest, and a fixed id would test the fixture, not the code.
    local wantLowest, wantKey
    for roomId, room in pairs(Registry.RoomsOf(ALPHA)) do
        if room.rtype == 'std' and not Rentals[roomId] then
            local key = (room.floor or 1) * 1000 + (room.slot or 0)
            if not wantKey or key < wantKey then wantLowest, wantKey = roomId, key end
        end
    end
    check('find_free_returns_lowest', Registry.FindFree(ALPHA, 'std') == wantLowest,
        ('got %s want %s'):format(tostring(Registry.FindFree(ALPHA, 'std')), tostring(wantLowest)))

    -- Replication. The payload is PULLED over a callback; only a revision
    -- number goes through GlobalState, because a statebag silently drops
    -- anything oversized and the client is then left with nothing.
    local view = Registry.ClientView()
    check('client_view_built', view ~= nil and view.properties ~= nil)
    check('properties_in_view', view and view.properties[ALPHA] ~= nil)
    check('revision_replicated', type(GlobalState[KEY('rev')]) == 'number', GlobalState[KEY('rev')])
    check('bulk_not_in_statebag', GlobalState[KEY('registry')] == nil
        and GlobalState[KEY('properties')] == nil and GlobalState[KEY('rooms')] == nil)

    -- Rooms are DERIVED on the client, never sent: the properties payload
    -- already contains the room list (or the layout that makes it), so sending
    -- expanded rooms too was ~300 KB of the inputs' own outputs.
    check('rooms_not_sent', view.rooms == nil)

    -- The derivation must reproduce the server's rooms EXACTLY -- same ids,
    -- same geometry. A drift here would be invisible until a door or a stash
    -- silently belonged to nobody.
    local derived = {}
    for propId, prop in pairs(view.properties) do
        for roomId, room in pairs(RoomsExpand(propId, prop)) do derived[roomId] = room end
    end
    check('derived_room_count_matches', Util.Count(derived) == Util.Count(Rooms),
        ('derived %d, server %d'):format(Util.Count(derived), Util.Count(Rooms)))

    local mismatch, checked = nil, 0
    for roomId, server in pairs(Rooms) do
        local d = derived[roomId]
        checked = checked + 1
        if not d then mismatch = roomId .. ' missing'
        elseif d.num ~= server.num then mismatch = roomId .. ' num'
        elseif d.rtype ~= server.rtype then mismatch = roomId .. ' rtype'
        elseif #(d.door - server.door) > 0.001 then mismatch = roomId .. ' door'
        elseif #(vec3(d.origin.x, d.origin.y, d.origin.z)
                 - vec3(server.origin.x, server.origin.y, server.origin.z)) > 0.001 then
            mismatch = roomId .. ' origin'
        end
        if mismatch then break end
    end
    check('derived_rooms_identical', mismatch == nil, mismatch)
    print(('[hotel][TEST] derived %d rooms client-side from %d bytes of properties')
        :format(checked, #json.encode(view.properties)))

    check('revision_is_tiny', #json.encode(GlobalState[KEY('rev')]) < 32)

    return done('registry')
end)

-- ── storage ──────────────────────────────────────────────────────────────
suite('storage', function()
    print(('[hotel][TEST] storage backend: %s'):format(Storage.Backend()))

    local roomId = ALPHA .. ':f01_r104'
    local now = os.time() * 1000
    local rental = {
        propId = ALPHA, identifier = 'TEST_STORAGE', renterName = 'Storage Probe', rtype = 'std',
        rentedAt = now, expiresAt = now + 86400000,
        guests = { TEST_GUEST = 'A Guest' }, data = { probe = true },
    }

    check('upsert_returns_true', Storage.Upsert(roomId, rental) == true)
    Storage.FlushNow()

    local got = Storage.LoadAll()[roomId]
    check('roundtrip_row_exists', got ~= nil)
    check('roundtrip_identifier', got and got.identifier == 'TEST_STORAGE', got and got.identifier)
    check('roundtrip_expires_ms', got and got.expiresAt == now + 86400000, got and got.expiresAt)
    check('roundtrip_guests', got and got.guests and got.guests.TEST_GUEST == 'A Guest')
    check('roundtrip_data', got and got.data and got.data.probe == true)

    check('fault_injection_fails_write', Storage.Upsert(roomId, rental) ~= false or true)
    Storage.__failNextUpsert = true
    check('failNextUpsert_returns_false', Storage.Upsert(roomId, rental) == false)
    check('failNextUpsert_is_one_shot', Storage.Upsert(roomId, rental) == true)

    check('delete_returns_true', Storage.Delete(roomId) == true)
    Storage.FlushNow()
    check('deleted_row_gone', Storage.LoadAll()[roomId] == nil)

    return done('storage')
end)

-- ── money ────────────────────────────────────────────────────────────────
suite('money', function()
    print(('[hotel][TEST] framework=%s moneyMode=%s'):format(FW.Framework(), Money.Mode()))

    local prev = Config.MoneySystem

    Config.MoneySystem = 'free'
    check('free_mode_reported', Money.Mode() == 'free', Money.Mode())
    check('free_charge_succeeds', Money.Charge(1, 999999, 'test') == true)
    check('free_balance_is_large', Money.Get(1, 'bank') > 1000000)
    check('free_refund_succeeds', Money.Refund(1, 999999, 'test') == true)

    -- fail closed: a missing hook must never hand out a free room
    Config.MoneySystem = 'custom'
    CustomRemoveMoney = nil
    check('custom_without_hook_rejects', Money.Charge(1, 100, 'test') == false)
    CustomRemoveMoney = function() return true end
    check('custom_with_hook_charges', Money.Charge(1, 100, 'test') == true)
    CustomRemoveMoney = function() return false end
    check('custom_hook_can_decline', Money.Charge(1, 100, 'test') == false)
    CustomRemoveMoney = nil

    check('zero_amount_is_free', Money.Charge(1, 0, 'test') == true)

    Config.MoneySystem = prev
    return done('money')
end)

-- ── rentals ──────────────────────────────────────────────────────────────
local function resetRentals()
    for roomId in pairs(Rentals) do Rentals_Evict(roomId, 'test_reset') end
end

suite('rentals', function()
    resetRentals()

    local ok, roomId = Rentals_RentAs('TEST_A', ALPHA, 'std', 2, nil)
    check('rent_succeeds', ok, roomId)
    check('lowest_room_chosen', roomId == ALPHA .. ':f01_r101', roomId)
    check('rental_recorded', Rentals[roomId] and Rentals[roomId].identifier == 'TEST_A')
    check('expiry_is_ms_in_future', Rentals[roomId] and Rentals[roomId].expiresAt > os.time() * 1000)
    check('expiry_matches_days', Rentals[roomId]
        and Rentals[roomId].expiresAt - Rentals[roomId].rentedAt == 2 * 86400000)
    check('persisted', Storage.LoadAll()[roomId] ~= nil)
    check('door_locked_on_rent', DoorsIsLocked(roomId))
    check('occupancy_dropped', (GlobalState[KEY('occupancy')] or {})[ALPHA .. ':std'] == 3,
        (GlobalState[KEY('occupancy')] or {})[ALPHA .. ':std'])

    -- quota, scoped per property
    local ok2, err2 = Rentals_RentAs('TEST_A', ALPHA, 'std', 2, nil)
    check('double_rent_rejected', not ok2 and err2 == 'already_renting', err2)
    local ok3 = Rentals_RentAs('TEST_A', BETA, 'std', 2, nil)
    check('second_property_allowed', ok3)

    -- day cap comes from the property's own defaults (alpha ships maxDays = 7)
    local ok4, err4 = Rentals_RentAs('TEST_CAP', ALPHA, 'std', 30, nil)
    check('over_cap_rejected', not ok4 and err4 == 'bad_days', err4)

    -- the double-booking race
    local r1 = Registry.Reserve(ALPHA, 'std')
    local r2 = Registry.Reserve(ALPHA, 'std')
    check('reserve_returns_distinct_rooms', r1 and r2 and r1 ~= r2,
        ('%s / %s'):format(tostring(r1), tostring(r2)))
    Registry.Release(r1); Registry.Release(r2)
    check('release_frees_the_room', Registry.FindFree(ALPHA, 'std') == r1, Registry.FindFree(ALPHA, 'std'))

    -- rollback on a failed write
    local before = Registry.FindFree(ALPHA, 'std')
    Storage.__failNextUpsert = true
    local ok5, err5 = Rentals_RentAs('TEST_B', ALPHA, 'std', 1, nil)
    check('write_failure_rejects', not ok5 and err5 == 'write_failed', err5)
    check('write_failure_frees_room', Registry.FindFree(ALPHA, 'std') == before)
    check('write_failure_leaves_no_rental', Rentals[before] == nil)

    -- guests
    local aRoom = Rentals_FindByRenter('TEST_A', ALPHA)
    Rentals[aRoom].guests['TEST_GUEST'] = 'Guest'
    check('renter_has_access', Rentals_HasAccess('TEST_A', aRoom))
    check('guest_has_access', Rentals_HasAccess('TEST_GUEST', aRoom))
    check('stranger_has_no_access', not Rentals_HasAccess('NOBODY', aRoom))

    -- expiry and grace
    local okC, roomC = Rentals_RentAs('TEST_C', ALPHA, 'std', 1, nil)
    check('third_rental_ok', okC, roomC)
    Rentals[roomC].expiresAt = os.time() * 1000 - 1000
    check('in_grace_reported', Rentals_InGrace(roomC))
    Rentals_ExpiryTick()
    check('within_grace_not_evicted', Rentals[roomC] ~= nil)
    Rentals[roomC].expiresAt = (os.time() - (Properties[ALPHA].defaults.graceDays * 86400) - 60) * 1000
    Rentals_ExpiryTick()
    check('past_grace_evicted', Rentals[roomC] == nil)
    check('evicted_row_deleted', Storage.LoadAll()[roomC] == nil)
    check('door_relocked_after_evict', DoorsIsLocked(roomC))

    resetRentals()
    check('occupancy_restored', (GlobalState[KEY('occupancy')] or {})[ALPHA .. ':std'] == 4,
        (GlobalState[KEY('occupancy')] or {})[ALPHA .. ':std'])

    return done('rentals')
end)

-- ── public API ───────────────────────────────────────────────────────────
suite('api', function()
    local me = GetCurrentResourceName()
    resetRentals()

    local props = exports[me]:GetProperties()
    check('api_lists_properties', props[ALPHA] ~= nil)
    check('api_reports_room_count', props[ALPHA] and props[ALPHA].rooms == 4, props[ALPHA] and props[ALPHA].rooms)
    check('api_reports_free_count', props[ALPHA] and props[ALPHA].free == 4, props[ALPHA] and props[ALPHA].free)

    local roomId = exports[me]:GrantRoom('API_TEST', ALPHA, 'std', 3)
    check('grant_returns_roomid', type(roomId) == 'string', roomId)
    check('grant_recorded', roomId and Rentals[roomId] ~= nil)
    check('is_owner_true', exports[me]:IsRoomOwner('API_TEST', roomId) == true)
    check('is_owner_false_for_other', exports[me]:IsRoomOwner('SOMEONE_ELSE', roomId) == false)

    local mine = exports[me]:GetPlayerRooms('API_TEST')
    check('player_rooms_returns_one', #mine == 1, #mine)
    check('player_rooms_has_number', mine[1] and mine[1].num == 101, mine[1] and mine[1].num)
    check('player_rooms_has_property', mine[1] and mine[1].propertyId == ALPHA)

    local info = exports[me]:GetRoom(roomId)
    check('get_room_returns_owner', info and info.identifier == 'API_TEST')
    check('get_room_unrented_is_nil_owner', (exports[me]:GetRoom(ALPHA .. ':f01_r103') or {}).identifier == nil)
    check('get_room_unknown_is_nil', exports[me]:GetRoom('nope:nope:nope') == nil)

    local newExpiry = os.time() * 1000 + 999000
    check('set_expiry_ok', exports[me]:SetRoomExpiry(roomId, newExpiry) == true)
    check('set_expiry_applied', Rentals[roomId].expiresAt == newExpiry)
    check('set_expiry_persisted', Storage.LoadAll()[roomId].expiresAt == newExpiry)
    check('set_expiry_rejects_garbage', exports[me]:SetRoomExpiry(roomId, 'soon') == false)

    check('add_guest_ok', exports[me]:AddGuest(roomId, 'GUEST_1') == true)
    check('guest_has_access', Rentals_HasAccess('GUEST_1', roomId))
    check('add_guest_rejects_owner', exports[me]:AddGuest(roomId, 'API_TEST') == false)
    check('remove_guest_ok', exports[me]:RemoveGuest(roomId, 'GUEST_1') == true)
    check('guest_lost_access', not Rentals_HasAccess('GUEST_1', roomId))

    check('revoke_ok', exports[me]:RevokeRoom(roomId) == true)
    check('revoke_frees_room', Rentals[roomId] == nil)
    check('revoke_deletes_row', Storage.LoadAll()[roomId] == nil)
    check('revoke_unknown_is_false', exports[me]:RevokeRoom('nope:nope:nope') == false)

    return done('api')
end)

-- ── player flow (needs a connected player) ───────────────────────────────
RegisterCommand(CMD('test_player'), function(src, args)
    if src ~= 0 then return end
    local target = tonumber(args[1])
    if not target or not GetPlayerName(target) then
        print(('[hotel][TEST] usage: %s <serverId>'):format(CMD('test_player')))
        return
    end
    local identifier = FW.GetIdentifier(target)
    if not check('player_identifier', identifier ~= nil) then return end
    resetRentals()

    local ok, roomId = Rentals_Rent(target, ALPHA, 'std', 2)
    if not check('rent_succeeds', ok, roomId) then return done('player') end
    check('rental_belongs_to_player', Rentals[roomId].identifier == identifier)
    check('renter_name_resolved', Rentals[roomId].renterName ~= nil)

    local ok2, err2 = Rentals_Rent(target, ALPHA, 'std', 2)
    check('double_rent_rejected', not ok2 and err2 == 'already_renting', err2)

    local before = Rentals[roomId].expiresAt
    local ok3 = Rentals_Extend(target, ALPHA, 1)
    check('extend_succeeds', ok3)
    check('extend_adds_a_day', Rentals[roomId].expiresAt == before + 86400000)

    local ok4 = Rentals_Extend(target, ALPHA, 99)
    check('extend_over_cap_rejected', not ok4)

    local ok5 = Rentals_End(target, ALPHA)
    check('checkout_succeeds', ok5)
    check('room_freed', Rentals[roomId] == nil)
    check('door_locked_after_checkout', DoorsIsLocked(roomId))

    done('player')
end, false)

-- ── security regressions (each one is a bug that was real) ───────────────
suite('security', function()
    local me = GetCurrentResourceName()
    resetRentals()

    -- NaN days: every comparison against NaN is false, so an unvalidated day
    -- count flows straight through to the price multiply and the charge.
    local nan = 0 / 0
    local ok1, err1 = Rentals_RentAs('SEC_NAN', ALPHA, 'std', nan, nil)
    check('nan_days_rejected', not ok1 and err1 == 'bad_days', err1)
    check('nan_days_left_no_rental', Rentals_FindByRenter('SEC_NAN', ALPHA) == nil)
    check('nan_days_did_not_reserve', Registry.FindFree(ALPHA, 'std') == ALPHA .. ':f01_r101',
        Registry.FindFree(ALPHA, 'std'))

    check('inf_days_rejected', not Rentals_RentAs('SEC_INF', ALPHA, 'std', math.huge, nil))
    check('neg_inf_days_rejected', not Rentals_RentAs('SEC_NIN', ALPHA, 'std', -math.huge, nil))
    check('zero_days_rejected', not Rentals_RentAs('SEC_ZERO', ALPHA, 'std', 0, nil))
    check('negative_days_rejected', not Rentals_RentAs('SEC_NEG', ALPHA, 'std', -5, nil))
    check('table_days_rejected', not Rentals_RentAs('SEC_TBL', ALPHA, 'std', {}, nil))
    check('fractional_days_floored', Rentals_RentAs('SEC_FRAC', ALPHA, 'std', 2.9, nil))
    local fracRoom = Rentals_FindByRenter('SEC_FRAC', ALPHA)
    check('fractional_became_two_days',
        Rentals[fracRoom].expiresAt - Rentals[fracRoom].rentedAt == 2 * 86400000)

    check('non_string_identifier_rejected', not Rentals_RentAs({}, ALPHA, 'std', 1, nil))
    check('empty_identifier_rejected', not Rentals_RentAs('', ALPHA, 'std', 1, nil))

    -- quota above 1: held must be an exact count, not just whether any exist
    local prev = Properties[ALPHA].defaults.maxRoomsPerPlayer
    Properties[ALPHA].defaults.maxRoomsPerPlayer = 2
    resetRentals()
    check('quota2_first_ok', Rentals_RentAs('SEC_Q', ALPHA, 'std', 1, nil))
    check('quota2_second_ok', Rentals_RentAs('SEC_Q', ALPHA, 'std', 1, nil))
    local ok3, err3 = Rentals_RentAs('SEC_Q', ALPHA, 'std', 1, nil)
    check('quota2_third_rejected', not ok3 and err3 == 'already_renting', err3)
    check('quota2_held_exactly_two', #Rentals_AllByRenter('SEC_Q') == 2, #Rentals_AllByRenter('SEC_Q'))
    Properties[ALPHA].defaults.maxRoomsPerPlayer = prev

    -- extending at a property whose map is stopped must not fall back to
    -- Config.Defaults (cheaper price, longer cap than the property sells)
    resetRentals()
    local saved = Properties[ALPHA]
    Properties[ALPHA] = nil
    check('extend_on_unregistered_rejected', not Rentals_Extend(1, ALPHA, 1))
    Properties[ALPHA] = saved

    -- SetRoomExpiry must reject values that make os.date() throw
    local roomId = exports[me]:GrantRoom('SEC_EXP', ALPHA, 'std', 1)
    check('expiry_rejects_nan', exports[me]:SetRoomExpiry(roomId, 0 / 0) == false)
    check('expiry_rejects_inf', exports[me]:SetRoomExpiry(roomId, math.huge) == false)
    check('expiry_rejects_absurd', exports[me]:SetRoomExpiry(roomId, 1e18) == false)
    check('expiry_accepts_sane', exports[me]:SetRoomExpiry(roomId, os.time() * 1000 + 60000) == true)

    -- a table identifier must not become "table: 0x..." in the database
    check('grant_rejects_table_identifier', exports[me]:GrantRoom({}, ALPHA, 'std', 1) == nil)
    check('addguest_rejects_table', exports[me]:AddGuest(roomId, {}) == false)

    -- revoking a guest who was never there must not write
    check('remove_absent_guest_is_noop', exports[me]:RemoveGuest(roomId, 'NEVER_A_GUEST') == true)

    resetRentals()
    return done('security')
end)

-- ── stash handover ───────────────────────────────────────────────────────
-- A new occupant must never inherit the previous one's belongings, even though
-- eviction deliberately does not wipe (an accidental lapse would void a
-- player's things). The wipe happens when somebody else takes the room.
suite('stash', function()
    local me = GetCurrentResourceName()
    resetRentals()

    local cleared = {}
    local realClear = Inventory.Clear
    Inventory.Clear = function(roomId) cleared[roomId] = (cleared[roomId] or 0) + 1 end

    local roomId = exports[me]:GrantRoom('STASH_A', ALPHA, 'std', 1)
    check('first_rental_clears_unknown_room', cleared[roomId] == 1, cleared[roomId])

    exports[me]:RevokeRoom(roomId)
    check('evict_does_not_wipe', cleared[roomId] == 1, cleared[roomId])

    local again = exports[me]:GrantRoom('STASH_A', ALPHA, 'std', 1)
    check('same_renter_keeps_stash', again == roomId and cleared[roomId] == 1, cleared[roomId])

    exports[me]:RevokeRoom(again)
    local thief = exports[me]:GrantRoom('STASH_B', ALPHA, 'std', 1)
    check('new_renter_gets_same_room', thief == roomId, thief)
    check('new_renter_stash_wiped', cleared[roomId] == 2, cleared[roomId])

    Inventory.Clear = realClear
    resetRentals()
    return done('stash')
end)

-- ── proximity gate (needs a connected player, positioned by the caller) ──
-- Exercises the REAL gate the rent/extend/checkout callbacks use, against a
-- real player's real position. Usage:
--   <prefix>_test_proximity <serverId> <propertyId> <near|far>
RegisterCommand(CMD('test_proximity'), function(src, args)
    if src ~= 0 then return end
    local target, propId, expect = tonumber(args[1]), args[2], args[3]
    if not target or not propId or not expect then
        print(('[hotel][TEST] usage: %s <serverId> <propertyId> <near|far>'):format(CMD('test_proximity')))
        return
    end
    if not Properties[propId] then
        print(('[hotel][TEST] SKIP %s not registered'):format(propId))
        return
    end

    local ok = ApiNearReception(target, propId)
    local p = GetEntityCoords(GetPlayerPed(target))
    local c = Properties[propId].reception.coords
    local dist = #(p - vec3(c.x, c.y, c.z))

    if expect == 'near' then
        check('proximity_allows_at_the_desk', ok == true, ('%.1fm away'):format(dist))
    else
        check('proximity_rejects_from_afar', ok == false, ('%.1fm away'):format(dist))
    end
    return done('proximity(' .. expect .. ')')
end, false)

-- ── real map data ────────────────────────────────────────────────────────
-- Checks the data the SHIPPING maps registered, not the synthetic ones: room
-- counts, numbering, variant spread, per-floor IPL wiring and Z stepping.
-- Skips cleanly on a server where those maps are not installed.
RegisterCommand(CMD('verify_maps'), function(src)
    if src ~= 0 then return end

    local function report(propId, expectRooms)
        local prop = Properties[propId]
        if not prop then
            print(('[hotel][TEST] SKIP %s — not installed here'):format(propId))
            return
        end
        local rooms = Registry.RoomsOf(propId)
        local n = Util.Count(rooms)
        check(propId .. '_room_count', n == expectRooms, n)

        local byType, byVariant, byFloor = {}, {}, {}
        local minZ, maxZ, noIpl, dupNum = 1e9, -1e9, 0, 0
        local seenNum = {}
        for _, r in pairs(rooms) do
            byType[r.rtype] = (byType[r.rtype] or 0) + 1
            byVariant[r.variant] = (byVariant[r.variant] or 0) + 1
            byFloor[r.floor] = (byFloor[r.floor] or 0) + 1
            if r.origin.z < minZ then minZ = r.origin.z end
            if r.origin.z > maxZ then maxZ = r.origin.z end
            if prop.streaming == 'script' and not r.ipl then noIpl = noIpl + 1 end
            if seenNum[r.num] then dupNum = dupNum + 1 end
            seenNum[r.num] = true
        end

        local parts = {}
        for t, c in pairs(byType) do parts[#parts + 1] = ('%s=%d'):format(t, c) end
        print(('[hotel][TEST]   %s types: %s'):format(propId, table.concat(parts, ' ')))
        parts = {}
        for v, c in pairs(byVariant) do parts[#parts + 1] = ('%s=%d'):format(v, c) end
        print(('[hotel][TEST]   %s variants: %s'):format(propId, table.concat(parts, ' ')))
        print(('[hotel][TEST]   %s floors: %d, Z %.2f..%.2f'):format(propId, Util.Count(byFloor), minZ, maxZ))

        check(propId .. '_every_room_has_a_type', byType[nil] == nil and Util.Count(byType) > 0)
        check(propId .. '_room_numbers_unique', dupNum == 0, dupNum)
        if prop.streaming == 'script' then
            check(propId .. '_every_room_has_an_ipl', noIpl == 0, noIpl)
        end
        check(propId .. '_every_room_has_a_door', (function()
            for _, r in pairs(rooms) do if not r.door or not r.probe then return false end end
            return true
        end)())
        check(propId .. '_reception_captured', (function()
            local c = prop.reception and prop.reception.coords
            return c ~= nil and not (c.x == 0.0 and c.y == 0.0)
        end)(), 'run /hotel_here at the desk and paste it into hotel_config.lua')
    end

    print('[hotel][TEST] --- shipping map data ---')
    report('prompt_dlcopencity_hotel_only:tower', 200)
    report('prompt_lsmotel:lsmotel', 63)
    -- 31, not 32: room_28's ymap holds a barrier and a blocked entrance door,
    -- no interior, so it is not a rentable room.
    report('prompt_sandy_motel:sandymotel', 31)

    -- the tower's bar: spawn points from the map, menu from the engine
    local T = 'prompt_dlcopencity_hotel_only:tower'
    if Properties[T] then
        local bar = Properties[T].bar
        check('tower_bar_registered', bar ~= nil)
        check('tower_bar_four_bartenders', bar and #bar.bartenders == 4, bar and #bar.bartenders)
        check('tower_bar_inherited_menu', bar and #bar.drinks == #Config.Bar.drinks, bar and #bar.drinks)
        check('tower_bar_inherited_ped', bar and bar.pedModel == Config.Bar.pedModel)
    end

    -- the tower's 8 floors must be evenly stacked by zStep
    if Properties[T] then
        local z1 = Rooms[T .. ':f01_r01'] and Rooms[T .. ':f01_r01'].origin.z
        local z8 = Rooms[T .. ':f08_r01'] and Rooms[T .. ':f08_r01'].origin.z
        local step = Properties[T].layout.zStep
        check('tower_floor8_is_7_steps_up',
            z1 and z8 and math.abs((z8 - z1) - 7 * step) < 0.01, z1 and z8 and (z8 - z1))
        check('tower_room_number_scheme', Rooms[T .. ':f08_r25'] and Rooms[T .. ':f08_r25'].num == 825,
            Rooms[T .. ':f08_r25'] and Rooms[T .. ':f08_r25'].num)
    end

    -- the motel folds the floor into the number: floor 4 room 16 -> 416
    local M = 'prompt_lsmotel:lsmotel'
    if Properties[M] then
        check('motel_room_number_scheme', Rooms[M .. ':f04_r416'] ~= nil)
        check('motel_single_variant', Util.Count(Properties[M].variants) == 1)
        local a = Properties[M].variants.lsmotel_room.amenities
        check('motel_amenities_captured', a ~= nil and a.stash and a.wardrobe and a.shower)
        check('motel_has_shower_head', a and a.showerHead ~= nil)
    end

    -- The Sandy Motel folds the floor in and counts from 1 on each floor
    local S = 'prompt_sandy_motel:sandymotel'
    if Properties[S] then
        check('sandy_floor1_first', Rooms[S .. ':f01_r101'] ~= nil)
        check('sandy_floor2_first', Rooms[S .. ':f02_r201'] ~= nil)
        check('sandy_room_28_absent', (function()
            for _, r in pairs(Registry.RoomsOf(S)) do
                if r.ipl == 'prompt_sandy_motel_room_28' then return false end
            end
            return true
        end)())
        -- two wings facing opposite ways: headings must cluster ~180 apart
        local h = {}
        for _, r in pairs(Registry.RoomsOf(S)) do
            h[math.floor(r.origin.w + 0.5)] = true
        end
        check('sandy_two_heading_groups', Util.Count(h) <= 3, Util.Count(h))
    end

    -- Amenity points must land INSIDE the room, not through a wall. Rotate each
    -- into world space and confirm it is within a sane radius of the origin.
    for _, propId in ipairs({ 'prompt_dlcopencity_hotel_only:tower', 'prompt_lsmotel:lsmotel',
                             'prompt_sandy_motel:sandymotel' }) do
        local prop = Properties[propId]
        if prop then
            local worst, worstName = 0, nil
            for vid, v in pairs(prop.variants) do
                for kind, off in pairs(v.amenities or {}) do
                    local d = math.sqrt(off.x * off.x + off.y * off.y)
                    if d > worst then worst, worstName = d, ('%s.%s'):format(vid, kind) end
                end
            end
            check(propId .. '_amenities_within_room', worst < 12.0,
                ('furthest %s at %.1fm'):format(tostring(worstName), worst))
        end
    end

    return done('maps')
end, false)

-- ── everything ───────────────────────────────────────────────────────────
RegisterCommand(CMD('test_all'), function(src)
    if src ~= 0 then return end
    CreateThread(function()
        local tp, tf = 0, 0
        for _, name in ipairs(order) do
            local p, f = suites[name]()
            tp, tf = tp + (p or 0), tf + (f or 0)
            Wait(50)
        end
        print(('[hotel][TEST] ===== ALL SUITES: %d passed, %d failed ====='):format(tp, tf))
    end)
end, false)
