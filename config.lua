-- prompt_hotel_system — POLICY ONLY. There is deliberately no property data
-- here: rooms, coordinates, doors, IPLs and elevators all live in the MAP
-- that owns them and arrive at runtime through RegisterProperty(). Adding a
-- hotel therefore never requires editing this resource.
Config = {}

Config.Debug         = GetConvar('hotel_debug', '0') == '1'   -- setr hotel_debug 1
Config.CommandPrefix = 'hotel'
Config.Locale        = 'en'

-- ── bridge selection ─────────────────────────────────────────────────────
-- Every bridge takes the same shape: 'auto' detects, a named value forces a
-- backend, 'custom' routes to your own hooks, 'none' disables the feature.
Config.Framework   = 'auto'   -- 'auto' | 'qbcore' | 'qbox' | 'esx' | 'standalone'
Config.MoneySystem = 'auto'   -- 'auto' | 'bigdaddy' | 'custom' | 'free'
Config.MoneyType   = 'bank'   -- 'bank' | 'cash'
Config.Inventory   = 'auto'   -- 'auto' | 'ox' | 'qb' | 'custom' | 'none'
Config.Persistence = 'auto'   -- 'auto' | 'mysql' | 'json' | 'custom'
Config.Notify      = 'auto'   -- 'auto' | 'oxlib' | 'qb' | 'esx' | 'custom' | 'chat'
Config.Target      = 'auto'   -- 'auto' | 'ox' | 'qb' | 'none'
Config.Appearance  = 'auto'   -- 'auto' | 'illenium' | 'fivem-appearance' | 'qb' | 'custom' | 'none'

-- ── layer 1: fallbacks for anything a map did not specify ────────────────
Config.Defaults = {
    maxDays              = 14,
    graceDays            = 1,
    maxRoomsPerPlayer    = 1,
    maxGuests            = 4,
    clearStashOnEviction = false,   -- wiping dumps a player's props into the void
    pricePerDay          = 100,
}

-- 'property' = one room at each hotel. 'global' = one room across the server.
Config.RoomQuotaScope = 'property'

-- ── layer 3: server-owner overrides ──────────────────────────────────────
-- SHIPS EMPTY, ON PURPOSE. Anything set here wins over the map's own settings
-- and survives map updates. A new hotel needs no entry at all.
Config.Overrides = {
    -- ['prompt_lsmotel:lsmotel'] = { pricePerDay = 250, maxDays = 7, blip = false },
    -- ['prompt_lsmotel:lsmotel'] = { prices = { standard = 250, premium = 500 } },
}

Config.Stash = { slots = 50, maxWeight = 100000 }

-- ── amenities (generic behaviour; the POINTS come from each map) ─────────
Config.EnableShower   = true
Config.EnableWardrobe = true
Config.Shower = {
    duration     = 8000,
    ptfxAsset    = 'core',
    ptfxName     = 'ent_sht_water',
    ptfxScale    = 1.0,
    -- ent_sht_* effects are bursts: set ptfxRepeat (ms) to re-fire for the whole
    -- shower, or nil for a genuinely looped effect (ent_amb_* family).
    ptfxRepeat   = 2500,
    stressRelief = 20,          -- qb-hud only; ignored elsewhere
}
Config.RoomActivationRadius = 22.0

-- ── bar ──────────────────────────────────────────────────────────────────
-- A map supplies only bartender spawn points -- everything else here is the
-- inherited default. Drinks are an animation + drunk effect, no inventory
-- item, so no inventory script is required.
Config.Bar = {
    enable        = true,
    payFrom       = 'cash',            -- 'cash' or 'bank'
    pedModel      = 'a_m_y_business_01',
    spawnDistance = 40.0,
    idleAnim      = { dict = 'anim@amb@casino@mini@drinking@bar@drink@heels@idle_a',
                      clip = 'idle_a_bartender' },
    drinks = {
        { label = 'Beer',        price = 20,  intoxication = 0.8,
          model = `ba_prop_battle_beer_bottle`,          glass = `p_cs_shot_glass_2_s` },
        { label = 'Vodka',       price = 30,  intoxication = 1.0,
          model = `ba_Prop_Battle_Decanter_02_S`,        glass = `ba_prop_battle_shot_glass_01` },
        { label = 'Whiskey',     price = 40,  intoxication = 1.3,
          model = `p_whiskey_bottle_s`,                  glass = `p_cs_shot_glass_2_s` },
        { label = 'Bourbon',     price = 60,  intoxication = 1.5,
          model = `ba_prop_battle_whiskey_bottle_s`,     glass = `p_cs_shot_glass_2_s` },
        { label = 'Single Malt', price = 100, intoxication = 2.0,
          model = `ba_prop_battle_whiskey_bottle_2_s`,   glass = `p_cs_shot_glass_2_s` },
    },
}
