-- Money bridge.
--
--   'auto'     framework-native (qb/qbox/esx), or BigDaddy-Money if present
--   'bigdaddy' force BigDaddy-Money
--   'custom'   your CustomGetMoney / CustomRemoveMoney / CustomAddMoney globals
--   'free'     no economy at all — every charge succeeds, nothing is deducted
--
-- 'free' is an EXPLICIT choice for naked standalone servers, deliberately
-- distinct from "auto-detect found nothing". 'custom' FAILS CLOSED: a missing
-- hook rejects the charge, because a missing hook must never hand out free rooms.
Money = {}

local FREE_BALANCE = 999999999
local warned = {}

local function warnOnce(key, msg)
    if warned[key] then return end
    warned[key] = true
    print('[prompt_hotel_system][money] ' .. msg)
end

function Money.Mode()
    local m = Config.MoneySystem or 'auto'
    if m == 'free' or m == 'custom' or m == 'bigdaddy' then return m end
    if GetResourceState('BigDaddy-Money') == 'started' then return 'bigdaddy' end
    return 'auto'
end

local function bigDaddyAccounts(src)
    local raw = exports['BigDaddy-Money']:GetAccounts(src, src, -1)
    if not raw then return nil end
    local ok, accounts = pcall(json.decode, raw)
    return ok and accounts or nil
end

function Money.Get(src, mtype)
    mtype = mtype or Config.MoneyType or 'bank'
    local mode = Money.Mode()

    if mode == 'free' then return FREE_BALANCE end
    if mode == 'custom' then
        if CustomGetMoney then return tonumber(CustomGetMoney(src, mtype)) or 0 end
        warnOnce('get', "MoneySystem='custom' but CustomGetMoney() is not defined — balance treated as 0")
        return 0
    end
    if mode == 'bigdaddy' then
        local a = bigDaddyAccounts(src)
        return a and (a[mtype] or 0) or 0
    end

    local fw, p = FW.Framework(), FW.Player(src)
    if (fw == 'qbcore' or fw == 'qbox') and p then return p.PlayerData.money[mtype] or 0 end
    if fw == 'esx' and p then
        if mtype == 'bank' then
            local acc = p.getAccount('bank')
            return acc and acc.money or 0
        end
        return p.getMoney() or 0
    end
    return FREE_BALANCE   -- no framework: there is no economy to charge against
end

function Money.Charge(src, amount, reason)
    amount = tonumber(amount) or 0
    if amount <= 0 then return true end
    local mtype = Config.MoneyType or 'bank'
    local mode  = Money.Mode()

    if mode == 'free' then return true end
    if mode == 'custom' then
        if CustomRemoveMoney then return CustomRemoveMoney(src, amount, mtype, reason) == true end
        warnOnce('remove', "MoneySystem='custom' but CustomRemoveMoney() is not defined — charge REJECTED")
        return false
    end
    if mode == 'bigdaddy' then
        local a = bigDaddyAccounts(src)
        if not a then return false end
        local bank, cash = a.bank or 0, a.cash or 0
        if mtype == 'bank' then
            if bank < amount then return false end
            bank = bank - amount
        else
            if cash < amount then return false end
            cash = cash - amount
        end
        exports['BigDaddy-Money']:UpdateTotals(src, bank, cash, a.dirty or 0, -1)
        return true
    end

    local fw, p = FW.Framework(), FW.Player(src)
    if fw == 'qbcore' or fw == 'qbox' then
        return p ~= nil and p.Functions.RemoveMoney(mtype, amount, reason or 'hotel') == true
    elseif fw == 'esx' then
        if not p then return false end
        if mtype == 'cash' then
            if p.getMoney() < amount then return false end
            p.removeMoney(amount)
            return true
        end
        local acc = p.getAccount('bank')
        if not acc or acc.money < amount then return false end
        p.removeAccountMoney('bank', amount)
        return true
    end
    warnOnce('standalone', 'no framework detected — rooms are FREE. '
        .. "Set Config.MoneySystem = 'custom' and define CustomRemoveMoney to charge on a standalone server.")
    return true
end

function Money.Refund(src, amount, reason)
    amount = tonumber(amount) or 0
    if amount <= 0 then return true end
    local mtype = Config.MoneyType or 'bank'
    local mode  = Money.Mode()

    if mode == 'free' then return true end
    if mode == 'custom' then
        if CustomAddMoney then return CustomAddMoney(src, amount, mtype, reason) == true end
        warnOnce('add', "MoneySystem='custom' but CustomAddMoney() is not defined — refund SKIPPED")
        return false
    end
    if mode == 'bigdaddy' then
        local a = bigDaddyAccounts(src)
        if not a then return false end
        local bank, cash = a.bank or 0, a.cash or 0
        if mtype == 'bank' then bank = bank + amount else cash = cash + amount end
        exports['BigDaddy-Money']:UpdateTotals(src, bank, cash, a.dirty or 0, -1)
        return true
    end

    local fw, p = FW.Framework(), FW.Player(src)
    if (fw == 'qbcore' or fw == 'qbox') and p then
        p.Functions.AddMoney(mtype, amount, reason or 'hotel-refund')
        return true
    elseif fw == 'esx' and p then
        if mtype == 'bank' then p.addAccountMoney('bank', amount) else p.addMoney(amount) end
        return true
    end
    return true
end

CreateThread(function()
    Wait(600)
    print(('[prompt_hotel_system] money: %s (%s)'):format(Money.Mode(), Config.MoneyType or 'bank'))
end)
