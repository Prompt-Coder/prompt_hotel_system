# Changelog

## 1.0.1 — 2026-08-18

Fixed: on a framework with character selection (QBCore/QBox/ESX) a player who
reconnected lost access to their own room — no door option, no stash, no room
blip — until the resource was restarted. The client asks for its keys as soon as
it has the registry, which happens while the framework still has no player
object, and that request was discarded. The server now waits for the identity,
and pushes the list again on framework login so switching character works too.

## 1.0.0 — 2026-08-10

Initial public release.
