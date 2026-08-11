-- Reference implementation of the registration stub every hotel/motel map
-- ships: an explicit room list, a generated layout, and one deliberately
-- invalid property. Copy this file into a map and replace the payloads --
-- it has no hard dependency on prompt_hotel_system.

-- The engine publishes its own resource name here at boot. Reading a
-- well-known key beats scanning for a name: escrow renames resources and
-- customers rename folders, and either breaks a name match.
local DISCOVERY_KEY = 'prompt_hotel_system'

local function findCore()
    local name = GlobalState[DISCOVERY_KEY]
    if name and GetResourceState(name) == 'started' then return name end
    -- Fallback for a very old engine build that predates the discovery key.
    for i = 0, GetNumResources() - 1 do
        local res = GetResourceByFindIndex(i)
        if res and res:sub(1, #DISCOVERY_KEY) == DISCOVERY_KEY and GetResourceState(res) == 'started' then
            return res
        end
    end
end

local function register()
    local core = findCore()
    if not core then
        print('^3[example_property] prompt_hotel_system not found — nothing to register^0')
        return
    end

    exports[core]:RegisterProperty('alpha', {
        label     = 'Alpha Inn',
        streaming = 'none',
        -- Required for players to rent: the engine's proximity check fails
        -- closed, so a property with no desk has no client rental path.
        reception = { coords = vec4(10.0, 0.0, 30.0, 0.0), model = 'a_m_y_business_01',
                      scenario = 'WORLD_HUMAN_CLIPBOARD' },
        variants  = { std = { door = vec3(0.5, 0.0, 1.0), probeInward = 2.0 } },
        roomTypes = { { id = 'std', label = 'Standard', variants = { 'std' }, pricePerDay = 100 } },
        rooms = {
            { num = 101, floor = 1, origin = vec4(10.0, 10.0, 30.0, 0.0),  variant = 'std' },
            { num = 102, floor = 1, origin = vec4(20.0, 10.0, 30.0, 90.0), variant = 'std' },
            { num = 103, floor = 1, origin = vec4(30.0, 10.0, 30.0, 0.0),  variant = 'std' },
            { num = 104, floor = 1, origin = vec4(40.0, 10.0, 30.0, 0.0),  variant = 'std' },
        },
        defaults = { maxDays = 7 },
    })

    exports[core]:RegisterProperty('beta', {
        label     = 'Beta Tower',
        streaming = 'script',
        reception = { coords = vec4(100.0, -10.0, 50.0, 0.0), model = 'a_m_y_business_01',
                      scenario = 'WORLD_HUMAN_CLIPBOARD' },
        variants  = { std = { door = vec3(0.5, 0.0, 1.0) } },
        roomTypes = { { id = 'std', label = 'Standard', variants = { 'std' }, pricePerDay = 200 } },
        layout = {
            mode = 'floors', floors = 2, zStep = 4.0,
            slots = {
                { slot = 1, variant = 'std', origin = vec4(100.0, 0.0, 50.0, 0.0) },
                { slot = 2, variant = 'std', origin = vec4(110.0, 0.0, 50.0, 0.0) },
                { slot = 3, variant = 'std', origin = vec4(120.0, 0.0, 50.0, 0.0) },
            },
            ipls = { { 'test_ipl_f1' }, { 'test_ipl_f2' } },
        },
        defaults = { maxDays = 9 },
    })

    -- Invalid on purpose: no variants, no roomTypes.
    exports[core]:RegisterProperty('broken', { label = 'Broken', rooms = {} })
end

-- The engine announces itself on boot. This is the reliable path: polling alone
-- misses a fast restart, because the key is cleared and re-published inside a
-- second and the poll sees the same value either side.
AddEventHandler('prompt_hotel_system:coreReady', function(core)
    Wait(300)
    register()
end)

-- Poll as well, for the case where this resource starts after the engine has
-- already announced. Deliberately NOT an onResourceStart name check: the
-- engine's folder name is not ours to predict.
CreateThread(function()
    local lastCore
    while true do
        local core = findCore()
        if core ~= lastCore then
            lastCore = core
            if core then
                Wait(500)
                register()
            end
        end
        Wait(1000)
    end
end)
