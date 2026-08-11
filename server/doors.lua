-- Authoritative lock state. Default (absent from the table) = locked.
local lockOverrides = {}   -- [roomId] = false only while unlocked

function DoorsIsLocked(roomId)
    return lockOverrides[roomId] ~= false
end

function DoorsRebuildGlobal()
    GlobalState[KEY('doors')] = lockOverrides
end

-- Clients act on the BROADCAST value, never on a fresh GlobalState read:
-- GlobalState has not replicated yet at the moment this event lands.
function DoorsSetLocked(roomId, locked)
    if locked then
        lockOverrides[roomId] = nil
    else
        lockOverrides[roomId] = false
    end
    DoorsRebuildGlobal()
    TriggerClientEvent(EV('client:doorState'), -1, roomId, locked)
end

DoorsRebuildGlobal()
