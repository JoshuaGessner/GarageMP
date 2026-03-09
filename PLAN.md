# GarageMP - BeamMP Mod Research + Full Build Plan

## Goal
Build a BeamMP server/client mod that keeps designated players' vehicles present and synced when they disconnect and across server restarts, with admin chat commands to control who is enabled.

## Key Finding (Critical)
A true server-only "ghost player" / virtual player ID approach is not available with current BeamMP APIs.

Why:
- No Lua API exists to spawn vehicles directly from server-side code.
- Vehicles are tied to real connected clients in BeamMP internals.
- On disconnect, the server path removes that client's vehicles.
- `MP.TriggerClientEvent` sends custom events (`E:`), not native vehicle spawn protocol packets.

Practical result:
- The viable approach is proxy-hosted persistence: connected clients spawn/host persisted vehicles for offline owners.

## Source-Backed Research Notes
From BeamMP docs and server reference:
- Server plugins run in `Resources/Server/<PluginName>/` with Lua 5.3.
- Client mods are zipped in `Resources/Client/<ModName>.zip`.
- Useful server events: `onPlayerJoin`, `onPlayerDisconnect`, `onVehicleSpawn`, `onVehicleEdited`, `onVehicleDeleted`, `onVehicleReset`, `onChatMessage`, `onInit`, `onShutdown`.
- Useful server functions: `MP.GetPlayerIdentifiers`, `MP.GetPlayerVehicles`, `MP.GetPositionRaw`, `MP.RemoveVehicle`, `MP.TriggerClientEvent(Json)`, `MP.SendChatMessage`, `MP.GetPlayers`.
- Storage helpers: `FS.*` and `Util.JsonEncode/Decode`.

From BeamMP server source dive (architecture confirmation):
- Vehicle state is associated with connected client objects.
- Vehicle deletes are broadcast on disconnect (`Od:PID-VID` flow).
- No exposed MP API for synthetic clients or direct server vehicle insertion.

## Final Architecture
Use a GarageMP server plugin + client extension with distributed proxy hosting.

- Server tracks persisted owners by stable BeamMP ID (`identifiers.beammp`).
- When owner disconnects, server snapshots vehicles and assigns them to currently connected proxy clients.
- Proxy clients spawn/own those vehicles so they remain in-world.
- When owner rejoins, proxy copies are removed and vehicles are restored to owner.
- State is persisted to disk so restarts recover vehicles.

## Recommended File Layout

Resources/
- Server/
  - GarageMP/
    - main.lua
    - data/
      - config.json
      - vehicles_<beammpID>.json
- Client/
  - GarageMP.zip
    - scripts/
      - modScript.lua
    - lua/ge/extensions/
      - GarageMP.lua

## Data Model

`config.json`
- admins: list of beammp IDs
- persistList: list of beammp IDs
- settings:
  - autoSaveIntervalMs
  - maxVehiclesPerPlayer
  - commandPrefix (`/garagemp`)

`vehicles_<beammpID>.json`
- beammpID
- lastKnownName
- vehicles: array of objects:
  - model (`jbm`)
  - config (`vcf`)
  - pos `[x,y,z]`
  - rot `[x,y,z,w]`
  - metadata (timestamps/version)

In-memory runtime tables (server):
- `persistListSet[beammpID] = true`
- `adminSet[beammpID] = true`
- `savedVehicles[beammpID] = {...}`
- `playerToBeammpID[playerID] = beammpID`
- `proxyAssignments[ownerBeammpID] = { {hostPid, hostVid, slot}, ... }`
- `proxyIndex[hostPid:hostVid] = ownerBeammpID`
- `pendingRestore[beammpID] = true|nil`

## Chat Commands
Prefix: `/garagemp`

Player-safe:
- `/garagemp help`
- `/garagemp status`

Admin:
- `/garagemp add <playerName>`
- `/garagemp remove <playerName>`
- `/garagemp list`
- `/garagemp save`
- `/garagemp clear <playerName>`
- `/garagemp addadmin <playerName>`
- `/garagemp removeadmin <playerName>`
- `/garagemp info`
- `/garagemp proxyclear <playerName|beammpID>`

Bootstrap:
- If no config/admin exists, first-time setup command can assign initial admin.

## Runtime Flows

### 1) Owner Disconnect Flow
1. Resolve owner's BeamMP ID from cache/identifiers.
2. If owner not persisted, exit.
3. Snapshot owner vehicles:
   - read config via `MP.GetPlayerVehicles(pid)`
   - read latest transforms via `MP.GetPositionRaw(pid, vid)`
4. Save to memory and disk.
5. Choose proxy hosts from connected players (excluding owner), balanced by current proxy count.
6. Send spawn instructions to proxy hosts via `MP.TriggerClientEventJson`.
7. On proxy spawn confirmation, record host PID/VID mapping.

### 2) Owner Reconnect Flow
1. Detect persisted owner on `onPlayerJoin`.
2. Remove proxy copies currently hosting that owner's vehicles.
3. Mark `pendingRestore[beammpID] = true`.
4. Send restore spawn instructions to returning owner.
5. On confirmations, update mappings and clear pending restore.

### 3) Server Restart Recovery
1. `onInit`: load config + all vehicle files.
2. No vehicles can exist until a client is online.
3. As players join:
   - persisted owner online: restore to owner
   - otherwise assign offline owners' vehicles to available proxies

### 4) Proxy Host Disconnect
1. Find all proxy vehicles that were hosted by disconnecting player.
2. Requeue those vehicles for redistribution to remaining clients.
3. If no clients left, keep only on disk and retry when someone joins.

## Client Extension Responsibilities
`GarageMP.lua`:
- Register event handlers for server commands:
  - `GarageMP_SpawnBatch`
  - `GarageMP_RemoveProxyBatch`
- For each spawn request:
  - spawn vehicle with requested model/config
  - apply pos/rot
  - return ack to server with local vid, success/failure, error message
- Handle retries and idempotency keys to avoid duplicate spawns.
- Send explicit remove ack via `GarageMP_RemoveProxyComplete`.

## Safety + Edge Cases
- Guest players: avoid persistence (no stable identity guarantee).
- Car limit reached on host: skip or queue; report to admin.
- Duplicate spawns: use request UUID + dedupe cache on both server and client.
- Corrupted JSON files: backup and rebuild defaults, do not crash plugin.
- Name changes: always key by BeamMP ID, not username.
- Empty server: persistence remains on disk; no live ghosts until a player is online.

## Implementation Plan (Step-by-Step)

Phase 1 - Scaffolding
1. Create server plugin folder and `main.lua`.
2. Create client zip structure with `modScript.lua` and extension file.
3. Add plugin init logging and version checks.

Phase 2 - Persistence Core
4. Implement config load/save utilities.
5. Implement per-player vehicle file load/save utilities.
6. Add autosave timer and graceful `onShutdown` save.

Phase 3 - Identity + Tracking
7. Build BeamMP ID resolver/cache (`playerToBeammpID`).
8. Track owner vehicles on spawn/edit/reset/delete.
9. Implement snapshot merge logic (`GetPlayerVehicles` + `GetPositionRaw`).

Phase 4 - Commands
10. Add `/garagemp` parser in `onChatMessage`.
11. Implement admin auth checks by BeamMP ID.
12. Implement all user/admin commands listed above.

Phase 5 - Proxy Spawn System
13. Define server->client event payload schema.
14. Implement host selection (least-loaded, online only).
15. Send spawn batches to selected hosts.
16. Add client ack event path and server ack handlers.
17. Persist proxy mapping tables in-memory.

Phase 6 - Lifecycle Handlers
18. Implement owner disconnect to proxy transfer.
19. Implement owner reconnect reclamation flow.
20. Implement proxy host disconnect redistribution.

Phase 7 - Restart Recovery
21. On init, load all saved owners and queue recovery work.
22. On first suitable player joins, execute queued proxy spawns.

Phase 8 - Hardening
23. Add structured logging around every transfer/restore action.
24. Add retry/backoff for failed proxy spawns.
25. Add anti-duplication guard tokens.
26. Add command `/garagemp info` for diagnostics.

Phase 9 - Validation
27. Test single owner disconnect/reconnect cycle.
28. Test two owners + one proxy host.
29. Test host disconnect while holding proxies.
30. Test restart with no players online then delayed join.
31. Test command permissions and edge behaviors.

## Practical Constraints to Keep in Mind
- True "always spawned with zero players online" is impossible in BeamMP without a real connected host client.
- The best achievable behavior is:
  - persisted on disk always
  - restored into world as soon as at least one player is connected

## Next Build Decision
Use distributed proxy hosting (load-balanced across all connected users) rather than a single proxy host for better stability and lower per-client load.
