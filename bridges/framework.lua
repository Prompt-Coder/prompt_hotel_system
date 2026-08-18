-- Framework bridge: qbox / qbcore / esx / standalone.
-- Standalone resolves identity from the license identifier; money lives in
-- bridges/money.lua so a server can mix (e.g. ESX identity, custom money).
FW = { fw = 'standalone', bound = false, QBCore = nil, ESX = nil }

local function detect()
    local want = Config.Framework or 'auto'
    if want ~= 'auto' then return want end
    if GetResourceState('qbx_core') == 'started' then return 'qbox' end
    if GetResourceState('qb-core') == 'started' then return 'qbcore' end
    if GetResourceState('es_extended') == 'started' then return 'esx' end
    return 'standalone'
end

-- A framework can be installed but not started yet -- a single check at +500ms
-- that sticks on 'standalone' forever frees every room and drops identity to the license.
local function frameworkInstalled()
    for _, res in ipairs({ 'qbx_core', 'qb-core', 'es_extended' }) do
        if GetResourceState(res) ~= 'missing' then return true end
    end
    return false
end

-- Binding must not throw: an export call on a resource that isn't running raises,
-- silently killing this thread -- every player got 'no_access' with no error printed.
local function bind()
    local want = detect()
    local ok, e = pcall(function()
        if want == 'qbcore' then
            FW.QBCore = exports['qb-core']:GetCoreObject()
        elseif want == 'esx' then
            FW.ESX = exports['es_extended']:getSharedObject()
        end
    end)
    if not ok then
        print(('[prompt_hotel_system] ^1could not bind framework \'%s\': %s^0'):format(want, tostring(e)))
        if (Config.Framework or 'auto') ~= 'auto' then
            print(("[prompt_hotel_system] ^1Config.Framework is forced to '%s' but it is not running. "
                .. 'Set it to \'auto\', or install that framework.^0'):format(Config.Framework))
        end
        FW.fw = 'standalone'
        return false
    end
    FW.fw = want
    return true
end

CreateThread(function()
    Wait(500)   -- let framework resources finish starting
    bind()

    local waited = 500
    while FW.fw == 'standalone' and (Config.Framework or 'auto') == 'auto'
          and frameworkInstalled() and waited < 60000 do
        Wait(2000)
        waited = waited + 2000
        bind()
    end

    -- Bookings are gated on this: before it's set, GetIdentifier returns the
    -- license instead of citizenid, so a rental gets paid for and becomes unreachable.
    FW.bound = true

    print(('[prompt_hotel_system] framework: %s'):format(FW.fw))
    if FW.fw == 'standalone' and frameworkInstalled() then
        print('[prompt_hotel_system] ^3a framework is installed but never started — '
            .. 'running standalone: identities fall back to license and rooms are free.^0')
        print('[prompt_hotel_system] ^3Set Config.Framework explicitly if this is wrong.^0')
    end
end)

function FW.Framework() return FW.fw end
function FW.Bound() return FW.bound end

function FW.Player(src)
    if FW.fw == 'qbcore' then return FW.QBCore and FW.QBCore.Functions.GetPlayer(src)
    elseif FW.fw == 'qbox' then return exports.qbx_core:GetPlayer(src)
    elseif FW.fw == 'esx' then return FW.ESX and FW.ESX.GetPlayerFromId(src) end
end

function FW.GetIdentifier(src)
    if not src or src <= 0 then return nil end   -- console: GetPlayerIdentifierByType(0,..) crashes
    if CustomGetIdentifier then return CustomGetIdentifier(src) end
    local p = FW.Player(src)
    if FW.fw == 'qbcore' or FW.fw == 'qbox' then
        return p and p.PlayerData.citizenid
    elseif FW.fw == 'esx' then
        return p and p.identifier
    end
    return GetPlayerIdentifierByType(src, 'license')
end

function FW.Connected(src)
    return GetPlayerName(src) ~= nil
end

-- A framework only builds the player object once the character is chosen, which
-- is long after the client connects -- measured on QBCore, NetworkIsPlayerActive
-- is already true while GetPlayer() is still nil. Anything answering a client on
-- join must wait for identity instead of reading nil as "this player owns nothing".
function FW.AwaitIdentifier(src, maxMs)
    local id = FW.GetIdentifier(src)
    if id then return id end

    local waited, limit = 0, maxMs or 600000
    while waited < limit do
        Wait(1000)
        waited = waited + 1000
        if not FW.Connected(src) then return nil end
        id = FW.GetIdentifier(src)
        if id then return id end
    end
    return nil
end

function FW.GetName(src)
    local p = FW.Player(src)
    if (FW.fw == 'qbcore' or FW.fw == 'qbox') and p then
        local ci = p.PlayerData.charinfo
        return (ci.firstname or '') .. ' ' .. (ci.lastname or '')
    elseif FW.fw == 'esx' and p then
        return p.getName()
    end
    return GetPlayerName(src) or 'Unknown'
end

-- Returns jobName, onDuty. ESX has no native on-duty flag, so it reports true.
function FW.GetJob(src)
    local p = FW.Player(src)
    if not p then return nil, false end
    if FW.fw == 'qbcore' or FW.fw == 'qbox' then
        local job = p.PlayerData.job
        return job and job.name, job and job.onduty
    elseif FW.fw == 'esx' then
        return p.job and p.job.name, true
    end
    return nil, false
end
