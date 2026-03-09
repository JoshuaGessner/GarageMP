# GarageMP Implementation TODO

## Phase 0 - Project Setup
- [x] Create server plugin folder: `Resources/Server/GarageMP/`
- [x] Create client mod staging folder for zip packaging
- [x] Create server entry file: `Resources/Server/GarageMP/main.lua`
- [x] Create client entry files:
  - [x] `scripts/modScript.lua`
  - [x] `lua/ge/extensions/GarageMP.lua`
- [x] Add basic startup logs on both server and client sides
- [ ] Verify plugin/mod loading order on server start

## Phase 1 - Config + Storage
- [x] Create data folder on init: `Resources/Server/GarageMP/data/`
- [x] Implement config defaults in memory
- [x] Implement `loadConfig()` for `config.json`
- [x] Implement `saveConfig()` with safe write (temp file then rename)
- [x] Implement `loadPlayerVehicles(beammpID)`
- [x] Implement `savePlayerVehicles(beammpID, data)`
- [x] Implement load-all scan for `vehicles_*.json`
- [x] Add corruption fallback (backup + regenerate defaults)

## Phase 2 - Core Runtime State
- [x] Initialize state tables:
  - [x] `persistListSet`
  - [x] `adminSet`
  - [x] `savedVehicles`
  - [x] `playerToBeammpID`
  - [x] `proxyAssignments`
  - [x] `proxyIndex`
  - [x] `pendingRestore`
- [x] Implement helper: `getBeammpID(playerID)` with caching
- [x] Implement helper: `isAdmin(playerID)`
- [x] Implement helper: `isPersistEnabled(beammpID)`

## Phase 3 - Event Registration
- [x] Register `onInit`
- [x] Register `onShutdown`
- [x] Register `onPlayerJoin`
- [x] Register `onPlayerDisconnect`
- [x] Register `onVehicleSpawn`
- [x] Register `onVehicleEdited`
- [x] Register `onVehicleDeleted`
- [x] Register `onVehicleReset`
- [x] Register `onChatMessage`
- [x] Register custom event for client ack (`GarageMP_SpawnComplete`)

## Phase 4 - Vehicle Snapshot + Tracking
- [x] Implement `extractVehicleJson(rawVehicleData)`
- [x] Implement owner snapshot from `MP.GetPlayerVehicles(pid)`
- [x] Merge live transforms from `MP.GetPositionRaw(pid, vid)`
- [x] Normalize schema to `{jbm, vcf, pos, rot, meta}`
- [x] Track updates on:
  - [x] `onVehicleSpawn`
  - [x] `onVehicleEdited`
  - [x] `onVehicleReset`
  - [x] `onVehicleDeleted`
- [x] Add max vehicles cap per owner (from config)

## Phase 5 - Chat Command System (`/garagemp`)
- [x] Parse prefix and subcommands in `onChatMessage`
- [x] Implement `/garagemp help`
- [x] Implement `/garagemp status`
- [x] Implement `/garagemp add <playerName>`
- [x] Implement `/garagemp remove <playerName>`
- [x] Implement `/garagemp list`
- [x] Implement `/garagemp save`
- [x] Implement `/garagemp clear <playerName>`
- [x] Implement `/garagemp addadmin <playerName>`
- [x] Implement `/garagemp removeadmin <playerName>`
- [x] Implement `/garagemp info`
- [x] Implement first-run bootstrap (initial admin setup)
- [x] Return clear success/failure chat messages for every command

## Phase 6 - Proxy Host Selection
- [x] Implement `getConnectedEligibleHosts(excludePid)`
- [x] Exclude guests by default (configurable)
- [x] Implement least-loaded host selection strategy
- [x] Implement host fallback when no eligible hosts exist
- [x] Add queue for delayed proxy spawns when server is empty

## Phase 7 - Owner Disconnect Flow
- [x] On disconnect, resolve owner BeamMP ID
- [x] If owner persisted:
  - [x] Snapshot current vehicles
  - [x] Save owner vehicles to disk
  - [x] Build spawn batch payload(s)
  - [x] Assign vehicles across hosts
  - [x] Trigger client spawn events
  - [x] Track pending assignment records

## Phase 8 - Client Spawning
- [x] Add client event handler: `GarageMP_SpawnBatch`
- [x] Add idempotency cache for request UUIDs
- [x] Spawn vehicle with model + config
- [x] Apply position and rotation
- [x] Collect success/error per vehicle
- [x] Send ack to server via `TriggerServerEvent("GarageMP_SpawnComplete", data)`
- [x] Add optional handler for explicit remove commands

## Phase 9 - Ack Handling + Mapping
- [x] Parse spawn ack payload on server
- [x] Map returned host VID to owner BeamMP ID
- [x] Populate:
  - [x] `proxyAssignments[ownerBeammpID]`
  - [x] `proxyIndex[hostPid:hostVid]`
- [x] Retry failed spawn items with backoff
- [x] Stop retries after max attempts and log

## Phase 10 - Owner Reconnect Flow
- [x] Detect persisted owner on join
- [x] Mark `pendingRestore[beammpID]`
- [x] Remove existing proxy copies for that owner
- [x] Send restore spawn batch to owner client
- [x] Update ownership mappings from ack
- [x] Clear `pendingRestore[beammpID]`

## Phase 11 - Proxy Host Disconnect Flow
- [x] Find all proxy vehicles hosted by disconnecting player
- [x] Requeue those vehicles for reassignment
- [x] Re-distribute to remaining hosts
- [x] If no hosts, keep vehicles queued until next join

## Phase 12 - Restart Recovery
- [x] Load all persisted owner files on `onInit`
- [x] Build offline restore queue in memory
- [x] On each player join, attempt queued assignment
- [x] Restore directly to owner if they are the one joining

## Phase 13 - Auto-Save + Reliability
- [x] Add event timer for periodic save (e.g. every 300000 ms)
- [x] Save config and dirty player files only
- [x] Add safe shutdown save on `onShutdown`
- [x] Add defensive `pcall` wrappers around critical handlers

## Phase 14 - Logging + Diagnostics
- [x] Add structured log prefix (`[GarageMP]`)
- [x] Log command calls (admin actions)
- [x] Log assignment decisions and retries
- [x] Log restore timings
- [x] Add `/garagemp info` runtime dump:
  - [x] persisted owners count
  - [x] active proxies count
  - [x] queued restores count

## Phase 15 - Validation Checklist
- [ ] Test: persisted owner disconnect with at least 1 host online
- [ ] Test: persisted owner reconnect and reclaim
- [ ] Test: proxy host disconnect and redistribution
- [ ] Test: server restart then first player join restore
- [ ] Test: empty server (no hosts) queue behavior
- [ ] Test: max cars reached on host
- [ ] Test: guest account behavior
- [ ] Test: duplicate spawn request dedupe
- [ ] Test: corrupted config/player file recovery
- [ ] Test: admin permissions on all commands

## Definition of Done
- [ ] Persisted players' vehicles survive owner disconnect
- [ ] Persisted vehicles survive full server restart
- [ ] Admin command suite is fully functional
- [ ] No uncontrolled duplicate spawns after retries/rejoins
- [ ] Failures are logged and recoverable without server restart

## Phase 16 - Packaging + Release
- [x] Create packaging script (`scripts/package_garagemp.sh`)
- [x] Build client mod archive (`Resources/Client/GarageMP.zip`)
- [x] Build upload-ready release zip (`dist/GarageMP/GarageMP.zip`)
- [x] Include full release README in package (`GarageMP/README.md`)
- [x] Include docs bundle in package (`docs/PLAN.md`, `docs/TODO.md`)
- [x] Generate checksum file (`dist/GarageMP/GarageMP.zip.sha256`)

## Test Harness (Reproducible)

### Harness Preconditions
- [ ] Use 3 test clients on same server: `OwnerA`, `HostB`, `HostC`
- [ ] Ensure GarageMP client mod is loaded on all test clients
- [ ] Set low test value for retries in config (example: `spawnMaxRetries=2`, `retryBaseDelayMs=1000`)
- [ ] Make `OwnerA` persisted via `/garagemp add OwnerA`
- [ ] Verify command access with `/garagemp info`

### Sequence 1: Baseline Proxy Spawn on Disconnect
1. `OwnerA` spawns 2 vehicles.
2. `HostB` and `HostC` remain connected.
3. `OwnerA` disconnects.

Expected:
- Server snapshots owner vehicles and writes `vehicles_<beammpID>.json`.
- Server dispatches `GarageMP_SpawnBatch` to host(s).
- Hosts acknowledge via `GarageMP_SpawnComplete`.
- `/garagemp info` shows active proxies > 0.

### Sequence 2: Restore on Reconnect
1. Continue from Sequence 1.
2. `OwnerA` reconnects.

Expected:
- Server removes proxy copies.
- Server sends restore batch to `OwnerA`.
- `pendingRestore` clears after ack.
- Vehicles appear owned by `OwnerA` again.

### Sequence 3: Explicit Proxy Remove Command
1. Create active proxy state (Sequence 1).
2. Admin runs: `/garagemp proxyclear OwnerA`.

Expected:
- Server emits `GarageMP_RemoveProxyBatch` to hosts.
- Clients run remove handler and emit `GarageMP_RemoveProxyComplete`.
- Proxy mappings clear for `OwnerA`.
- No stale proxy vehicles remain.

### Sequence 4: Retry/Backoff on Spawn Failure
1. Create active proxy spawn request scenario.
2. Force one host to fail spawn (invalid model in one item, or unload client mod temporarily).
3. Observe retry behavior over time.

Expected:
- Failed items are isolated from successful ones.
- Retries occur with exponential backoff (`base`, `base*2`, ...).
- Retry attempts do not exceed `spawnMaxRetries`.
- On exhaustion, owner is queued for later restore/proxy assignment.

### Sequence 5: Proxy Host Disconnect Redistribution
1. Create active proxy state where `HostB` holds at least one proxy vehicle.
2. Disconnect `HostB`.

Expected:
- Server detects affected owners.
- Proxy assignments are re-dispatched to remaining host(s) or queued if none.
- `/garagemp info` reflects new distribution.

### Sequence 6: Restart Recovery
1. Ensure persisted owner file exists on disk.
2. Restart server with no clients connected.
3. Connect `HostB` only.

Expected:
- Server loads saved owner data on init.
- Since owner is offline, proxy queue drains to available host when `HostB` joins.
- Vehicles reappear from persisted data.

### Sequence 7: Duplicate Request Idempotency
1. Trigger a spawn request.
2. Manually re-send same request ID from client (or replay message in debug tooling).

Expected:
- Client dedupe path responds with duplicate ack.
- No duplicate vehicle spawn for same request ID.

### Sequence 8: Corrupt File Recovery
1. Stop server.
2. Corrupt one `vehicles_<beammpID>.json` file (invalid JSON).
3. Restart server.

Expected:
- Server does not crash.
- Corrupt file is backed up with `.corrupt_<timestamp>` suffix.
- Empty/default state is regenerated for that owner.

### Sequence 9: Permission Enforcement
1. Use non-admin account.
2. Attempt admin commands (`add`, `remove`, `proxyclear`, `addadmin`).

Expected:
- Commands are denied with clear permission message.
- No config or mapping mutation occurs.

### Pass/Fail Recording Template
- [ ] Sequence 1 passed
- [ ] Sequence 2 passed
- [ ] Sequence 3 passed
- [ ] Sequence 4 passed
- [ ] Sequence 5 passed
- [ ] Sequence 6 passed
- [ ] Sequence 7 passed
- [ ] Sequence 8 passed
- [ ] Sequence 9 passed
