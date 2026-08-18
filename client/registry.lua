-- Client mirror of the server registry. Everything else on the client rebuilds
-- itself from EV('client:registryChanged') and tears down what it built before,
-- which is what lets a map be started, stopped or restarted at runtime.
CProperties, CRooms = {}, {}

HotelAccess = {}      -- [roomId] = true  (rooms you may enter)
MyRooms     = {}      -- [propId] = { roomId, num, floor, slot }

local ready = false
local myRoomIds = {}   -- kept raw: the access list can land before the registry

-- Pulled, not pushed through a statebag: at real-map sizes (hundreds of KB)
-- FiveM silently drops the value. GlobalState carries just a revision number.
local fetching = false
local haveRev  = -1

local function deriveMyRooms()
    MyRooms = {}
    for _, roomId in ipairs(myRoomIds) do
        local room = CRooms[roomId]
        if room then
            MyRooms[room.propId] = {
                roomId = roomId, num = room.num, floor = room.floor, slot = room.slot,
            }
        end
    end
end

local function fetch()
    if fetching then return end
    fetching = true

    local reg = lib.callback.await(EV('getRegistry'), false)
    fetching = false
    if type(reg) ~= 'table' then return end

    CProperties = reg.properties or {}

    -- Rooms are DERIVED here, not received: fetched properties already carry
    -- the room list and door offsets. Same shared code as the server, so ids match.
    CRooms = {}
    for propId, prop in pairs(CProperties) do
        for roomId, room in pairs(RoomsExpand(propId, prop)) do
            CRooms[roomId] = room
        end
    end

    haveRev = reg.rev or 0
    ready   = true
    deriveMyRooms()
    TriggerEvent(EV('client:registryChanged'))
end

AddStateBagChangeHandler(KEY('rev'), 'global', function(_, _, value)
    if value ~= haveRev then fetch() end
end)

function HotelRegistryReady() return ready end

function HotelRoomVariant(room)
    local prop = CProperties[room.propId]
    return prop and prop.variants and prop.variants[room.variant]
end

function HotelPropertyOf(roomId)
    local room = CRooms[roomId]
    return room and CProperties[room.propId]
end

RegisterNetEvent(EV('client:accessList'), function(map, mine)
    HotelAccess = map or {}
    myRoomIds = mine or {}
    deriveMyRooms()
    TriggerEvent(EV('client:accessChanged'))
end)

RegisterNetEvent(EV('client:notify'), function(key, ntype)
    Notify(key, ntype)
end)

-- Debug tools teleport, so they are gated on an ace the SERVER checks. A
-- client-registered command cannot gate itself.
function HotelDebugAllowed()
    return Config.Debug and LocalPlayer.state[KEY('debug')] == true
end

CreateThread(function()
    while not NetworkIsPlayerActive(PlayerId()) do Wait(200) end
    Wait(500)

    -- Retry: a property can register after we join, and the server may not have
    -- finished its own boot when we first ask.
    local tries = 0
    repeat
        fetch()
        if not ready or Util.Count(CProperties) == 0 then Wait(2000) end
        tries = tries + 1
    until (ready and Util.Count(CProperties) > 0) or tries >= 15

    if Util.Count(CProperties) == 0 then
        print('[prompt_hotel_system] no properties registered — is a hotel map running?')
    end

    TriggerServerEvent(EV('server:requestAccessList'))
    TriggerServerEvent(EV('server:requestDebugFlag'))
end)
