-- Wardrobe bridge. When nothing is installed, Available() returns false and
-- client/rooms.lua hides the wardrobe rather than offering a dead interaction.
Appearance = {}

local backend

local function resolve()
    local want = Config.Appearance or 'auto'
    if want == 'none' then return 'none' end
    if want == 'custom' then return 'custom' end
    if want ~= 'auto' then return want end
    if CustomWardrobe then return 'custom' end
    if GetResourceState('illenium-appearance') == 'started' then return 'illenium' end
    if GetResourceState('fivem-appearance') == 'started' then return 'fivem-appearance' end
    if GetResourceState('qb-clothing') == 'started' then return 'qb' end
    return 'none'
end

CreateThread(function()
    Wait(700)
    backend = resolve()
    if Config.Debug then print(('[prompt_hotel_system] appearance backend: %s'):format(backend)) end
end)

function Appearance.Available()
    backend = backend or resolve()
    return backend ~= 'none'
end

function Appearance.OpenWardrobe()
    backend = backend or resolve()
    if backend == 'custom' and CustomWardrobe then return CustomWardrobe() end

    -- illenium-appearance declares NO exports; it ships the qb-clothing event
    -- for compatibility. exports['illenium-appearance']:openOutfitMenu() throws.
    if backend == 'illenium' then
        return TriggerEvent('illenium-appearance:client:openOutfitMenu')
    end

    -- 'fivem-appearance' is not one API -- forks differ (pedr0fontoura only exposes
    -- startPlayerCustomization; WasabiRobby adds openWardrobe; brp uses its own event).
    -- Try the export, fall back to the event, and point owners at 'custom' if neither fits.
    if backend == 'fivem-appearance' then
        if pcall(function() exports['fivem-appearance']:openWardrobe() end) then return end
        TriggerEvent('fivem-appearance:useWardrobe')
        return
    end

    if backend == 'qb' then return TriggerEvent('qb-clothing:client:openOutfitMenu') end
end
