# Contributing

## Dev setup

A FiveM server with [ox_lib](https://github.com/overextended/ox_lib). Drop the
resource in, `ensure prompt_hotel_system`. Everything else (framework, money,
inventory, target, database) is optional and auto-detected — see the README.

No map? Copy `examples/example_property/` into `resources/` and ensure it: you
get synthetic rentable rooms to develop against.

## Debug mode

```
setr hotel_debug 1
```

in `server.cfg` (must be `setr` — the flag gates client scripts). It enables:

- `/hotel_place` — point-capture tool. Stand in a registered room and capture
  `stash` / `wardrobe` / `shower` / `showerHead` / `door` offsets; it prints
  room-local coordinates ready to paste into a property config.
- `/hotel_ptfx [name]` — particle browser anchored on the nearest room's
  shower head, for picking `Config.Shower` effects.
- `server/test.lua` — synthetic-property smoke tests for the registry.

## Code style

- Lua 5.4 (`lua54 'yes'`). Match the existing patterns.
- Comments state constraints the code cannot show. No narration, no
  change-logs, no restating the next line.
- Simplest thing that works. No speculative flexibility.
- Bridges keep the triple: `'auto'` detection, forced backend, `'custom'`
  hooks. A new backend must support all three.

## Pull requests

- One change per PR, and say what you tested on (framework, target backend,
  with/without a database).
- Behavior visible to maps or servers (schema fields, exports, events,
  locales) is a contract — additions are fine, breaking changes need a schema
  version bump.
