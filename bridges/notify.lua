-- Notification bridge. Takes a locale key, not a finished string, so a server
-- owner retranslates in one place.
local mode

local function resolve()
    local want = Config.Notify or 'auto'
    if want ~= 'auto' then return want end
    if CustomNotify then return 'custom' end
    if GetResourceState('ox_lib') == 'started' then return 'oxlib' end
    if GetResourceState('qb-core') == 'started' then return 'qb' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'chat'
end

function Notify(key, ntype)
    mode = mode or resolve()
    local msg = L(key)

    if mode == 'custom' and CustomNotify then return CustomNotify(msg, ntype) end
    if mode == 'oxlib' then return lib.notify({ description = msg, type = ntype or 'inform' }) end
    if mode == 'qb' then return TriggerEvent('QBCore:Notify', msg, ntype == 'error' and 'error' or 'primary') end
    if mode == 'esx' then return TriggerEvent('esx:showNotification', msg) end
    TriggerEvent('chat:addMessage', { args = { 'Hotel', msg } })
end

CreateThread(function()
    Wait(800)
    mode = resolve()
end)
