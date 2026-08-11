# prompt_hotel_system

Rentable rooms for any Prompt hotel or motel MLO — reception menu, per-room
door locks, room storage, wardrobe, shower, and teleport elevators where the
map has them.

**The script is optional.** Your map works exactly as it does today without it.
Install it and the map's rooms become rentable; remove it and nothing breaks.

**One script, every property.** It contains no coordinates and no room lists.
Each map ships its own data and registers itself at boot, so a customer who owns
three of our hotels runs one script, gets one update, and can hold one room at
each — which three separate scripts could not do.

Source, issues, and updates:
[github.com/Prompt-Coder/prompt_hotel_system](https://github.com/Prompt-Coder/prompt_hotel_system)
— free and open source under LGPL-3.0.

---

## Ready-made properties

This script is the engine. Fully-built properties for it — MLO interiors with
per-room door numbering, captured amenity points, elevators, and bars — are
available on [the store](https://store.prompt-mods.com/store/):

- **Sandy Shores Motel** — 31 rooms, exterior walkways
- **Embassy Hotel** — 8-floor tower, 200 rooms *(coming soon)*
- **LS Motel** — 63 rooms across three floors *(coming soon)*

Any other map — yours or another creator's — plugs in the same way; see
[For map makers](#for-map-makers).

---

## Install

1. Drop `prompt_hotel_system` into your `resources` folder.
2. `ensure prompt_hotel_system` in `server.cfg`, **after** your framework and
   `oxmysql` if you use them.
3. Restart. That's it — no SQL to import, no config to fill in.

Requires [ox_lib](https://github.com/overextended/ox_lib) (free). Everything
else is optional and auto-detected.

### Supported, and what happens without it

| | Detected | Not installed |
|---|---|---|
| **Framework** | QBox, QBCore, ESX | Standalone — players identified by license |
| **Money** | your framework's, BigDaddy-Money | **rooms are free** (see below) |
| **Inventory** | ox_inventory, qb-inventory | room storage is hidden |
| **Database** | oxmysql | saves to a JSON file instead |
| **Target** | ox_target, qb-target | `[E]` prompts |
| **Notifications** | ox_lib, QBCore, ESX | chat messages |
| **Wardrobe** | illenium-appearance, fivem-appearance, qb-clothing | wardrobe is hidden |

Every one of these can be forced in `config.lua` instead of auto-detected, and
every one accepts `'custom'` so you can wire in your own system.

---

## Configuration

`config.lua` holds **policy only** — prices and rules. Room positions live with
the map that owns them, so a map update never overwrites your settings and your
settings never break on a map update.

### Prices and rules

Each map ships sensible defaults. Change them only if you want to:

```lua
Config.Overrides = {
    ['prompt_lsmotel:lsmotel'] = { pricePerDay = 250, maxDays = 7 },
}
```

The key is the property id, printed in your console at startup:

```
[prompt_hotel_system] registered 'LS Motel' (prompt_lsmotel:lsmotel) — 63 rooms
```

Anything you set here wins over the map's own settings **and survives map
updates**. Leave the table empty to use each map's defaults. Adding another
hotel needs no entry at all.

Per-room-type prices:

```lua
['prompt_dlcopencity_hotel_only:tower'] = { prices = { standard = 300, premium = 750 } },
```

Also accepted here: `maxDays`, `graceDays`, `maxRoomsPerPlayer`, `maxGuests`,
`clearStashOnEviction`, `blip = false`, `label`.

### One room per player

```lua
Config.RoomQuotaScope = 'property'   -- one room at each hotel (default)
Config.RoomQuotaScope = 'global'     -- one room across the whole server
```

### Money on a server with no framework

Auto-detection finds no economy, so **rooms are free** and the console says so.
To charge anyway, point the script at your own system:

```lua
Config.MoneySystem = 'custom'

-- Define these as globals in any server script of your own.
function CustomGetMoney(source, account)          return myBank:get(source) end
function CustomRemoveMoney(source, amount, account, reason)
    return myBank:take(source, amount)            -- must return true on success
end
function CustomAddMoney(source, amount, account, reason)
    return myBank:give(source, amount)
end
```

If `CustomRemoveMoney` is missing, charges are **rejected** rather than waved
through — a half-finished integration must not hand out free rooms.

`Config.MoneySystem = 'free'` disables the economy deliberately, which is
different from detection failing.

The same shape applies to `CustomGetIdentifier`, `CustomNotify`,
`CustomWardrobe`, `CustomInventory` (a table: `.open(src, roomId, label)` and
`.clear(roomId)`) and `CustomStorage` (`.load()`, `.save(roomId, rental)`,
`.delete(roomId)`).

---

## Database

With oxmysql running, the script creates **one** table, `prompt_hotel_rentals`,
on first boot and touches nothing else.

If your database user cannot `CREATE TABLE`, the console prints exactly that,
falls back to the JSON file so the hotel still works, and tells you to import
the bundled `prompt_hotel_system.sql` by hand. Import it, restart, and it picks
the table up. Existing rentals in the JSON file are migrated across once,
automatically.

No database at all is fine: rentals save to `data/rooms.json`.

---

## Admin commands

Console, or in-game with the `hotel.admin` ace.

| Command | |
|---|---|
| `hotel_properties` | registered properties, room counts, free counts |
| `hotel_rentals` | active rentals and expiry times |
| `hotel_grant <id> <property> <type> <days>` | give a room, no charge |
| `hotel_revoke <roomId>` | release a room |
| `hotel_evictall <property>` | release every room at a property |
| `hotel_orphans` | rentals whose room no longer exists (see below) |

`hotel_orphans` lists rentals pointing at rooms that are gone — usually because
that map is not running. They are never deleted automatically: a map being down
for maintenance must not destroy paid rentals.

---

## For map makers

Any map can register a property — ours, yours, or another creator's. Two files,
no dependency on this script.

Copy the two files in [`examples/example_property/`](examples/example_property)
into your map resource, then write your property payload:

```lua
HotelProperty = {
    label     = 'Seaside Inn',
    streaming = 'map',              -- 'map' | 'script' | 'none'

    reception = {
        coords   = vec4(120.5, -430.2, 32.1, 90.0),
        model    = 'a_m_y_business_01',
        scenario = 'WORLD_HUMAN_CLIPBOARD',
    },

    variants = {
        standard = {
            door      = vec3(0.62, 0.0, 1.15),   -- LOCAL offset from room origin
            doorModel = 'my_door_prop',
            amenities = {
                stash    = vec3(2.1, 1.4, 0.6),
                wardrobe = vec3(3.0, 1.1, 1.0),
                shower   = vec3(-1.2, 0.8, 0.7),
            },
        },
    },

    roomTypes = {
        { id = 'standard', label = 'Room', variants = { 'standard' }, pricePerDay = 150 },
    },

    rooms = {
        { floor = 1, num = 101, origin = vec4(100.0, -400.0, 30.0, 0.0), variant = 'standard' },
    },

    defaults = { maxDays = 14, graceDays = 1, maxRoomsPerPlayer = 1, maxGuests = 4 },
}
```

`num` is the room number your guest is told. Fold the floor in yourself
(floor 2 room 3 → `203`) so the number on the door matches the key.

For a tower where every floor is identical, use `layout` instead of `rooms` and
the script generates them:

```lua
layout = {
    mode = 'floors', floors = 8, zStep = 4.19,
    slots    = { { slot = 1, variant = 'standard', origin = vec4(...) }, ... },
    ipls     = { { 'floor1_ipl_a', ... }, { 'floor2_ipl_a', ... } },   -- per floor
    landings = { vec4(...), ... },                                    -- per floor
    zone     = { center = vec3(...), radius = 150.0 },
},
```

With `streaming = 'script'` the script loads and unloads one floor at a time and
can run teleport elevators (`elevators = { ... }`). With `streaming = 'map'`
your map keeps its own loader and the script only books rooms.

### Adding a bar

Send the bartender spawn points — where they stand is the one thing only your
map knows. Everything else has a default:

```lua
bar = {
    bartenders = {
        vec4(62.759, -917.012, 36.941, 251.658),
        vec4(60.488, -919.967, 36.941, 210.331),
    },
},
```

That's a complete bar. Stand **behind** the counter facing the customer side
when you capture each point; the script walks the customer to the opposite side
automatically.

You get the script's drinks menu, ped model, idle animation and payment account
for free. Override any of them if your venue calls for it:

```lua
bar = {
    bartenders = { vec4(...) },
    pedModel   = 's_m_y_barman_01',
    payFrom    = 'bank',
    drinks = {
        { label = 'House Red', price = 15, intoxication = 0.7,
          model = `ba_prop_battle_beer_bottle`, glass = `p_cs_shot_glass_2_s` },
    },
},
```

A server owner can change prices without touching your map:

```lua
Config.Overrides = {
    ['your_map:yourhotel'] = { bar = { drinks = { { label = 'Beer', price = 5 } } } },
}
```

Drinks are the pour animation plus a drunk effect — **no inventory item is
created**, so a bar works on a server with no inventory script. `bar = false`
disables it entirely.

**Validation is deliberately forgiving.** A key this version doesn't recognise
is a warning, not a rejection, so a map built for a newer script still works on
an older one. Only an unusable property is rejected — and only that one: a
mistake in one property can never take down your others, and the console names
the exact field.

---

## For script developers

Server-side exports. Reads and writes accept a server id **or** a stored
identifier, so a web panel can act on an offline player.

```lua
local hotel = exports.prompt_hotel_system

hotel:GetProperties()                              --> { [propId] = { label, rooms, free } }
hotel:GetPlayerRooms(src)                          --> { { roomId, propertyId, num, type, expiresAt, inGrace } }
hotel:IsRoomOwner(src, roomId)                     --> boolean
hotel:GetRoom(roomId)                              --> { propertyId, num, type, identifier, expiresAt, guests }

hotel:GrantRoom(identifier, propId, type, days)    --> roomId | nil, reason   (no charge)
hotel:RevokeRoom(roomId)                           --> boolean
hotel:SetRoomExpiry(roomId, expiresAtMs)           --> boolean
hotel:AddGuest(roomId, identifier)                 --> boolean
hotel:RemoveGuest(roomId, identifier)              --> boolean
```

Events fired server-side:

```lua
AddEventHandler('prompt_hotel_system:roomRented',  function(identifier, roomId, propId, days, price) end)
AddEventHandler('prompt_hotel_system:roomEvicted', function(identifier, roomId, propId, reason) end)
AddEventHandler('prompt_hotel_system:roomEntered', function(src, roomId) end)
```

All timestamps are unix **milliseconds**.

---

## Notes

- Room storage is **not** wiped when a rental lapses, so an accidental expiry
  doesn't void someone's belongings. It is wiped when a different player takes
  the room. Set `clearStashOnEviction = true` to wipe at eviction instead.
- An expired rental enters a grace period (one day by default) during which the
  room is still yours and the reception menu leads with *Extend*.
- `setr hotel_debug 1` enables the in-game capture and teleport commands
  (`/hotel_place`, `/hotel_ptfx`). Leave it unset on a live server.

---

## Contributing

PRs welcome — [CONTRIBUTING.md](CONTRIBUTING.md) has the dev setup, the debug
tooling, and the style rules.

## License

[LGPL-3.0](LICENSE). In practice: this script and any fork of it stay
open-source; maps and scripts that talk to it through its exports and events
are not derivatives and may be licensed however you like — including
commercially.
