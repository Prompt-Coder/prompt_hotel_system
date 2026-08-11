-- Namespace: events, GlobalState keys, statebags, door hashes, stash ids,
-- target zones and commands are all scoped to this resource, so nothing here
-- collides with another script. Room ids also carry their map's resource
-- name, so two creators reusing a property name can't collide either.
NS = GetCurrentResourceName()

-- network / local event name:  EV('client:doorState')
function EV(name)
    return NS .. ':' .. name
end

-- GlobalState + statebag key:  GlobalState[KEY('doors')]
function KEY(name)
    return NS .. '_' .. name
end

-- Fixed prefix, not GetCurrentResourceName(): stash ids persist in
-- inventory tables, so a rename -- including an escrow rename -- would
-- silently orphan every renter's room storage.
local RID_PREFIX = 'prompt_hotel_system_'

function RID(roomId)
    return RID_PREFIX .. roomId
end

-- console command name. Config.CommandPrefix keeps them short and readable,
-- and lets an owner rename them if something else already owns '/hotel_*'.
function CMD(name)
    return (Config.CommandPrefix or 'hotel') .. '_' .. name
end
