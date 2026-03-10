# GarageMP Installation and Use Guide

GarageMP is a BeamMP server/client mod that persists selected players' vehicles across disconnects and server restarts.

## Included in This Release

- `Resources/Server/GarageMP/main.lua`
- `Resources/Server/GarageMP/data/.gitkeep`
- `Resources/Client/GarageMP/` (client source)
- `README.md`

## Install

1. Stop your BeamMP server.
2. Build `Resources/Client/GarageMP.zip` from `Resources/Client/GarageMP/` (or use a release artifact).
3. Extract/copy files into your server root directory.
4. Confirm these paths exist:
   - `Resources/Server/GarageMP/main.lua`
   - `Resources/Client/GarageMP.zip`
5. Start the server.

Quick local build command:

```bash
(cd Resources/Client/GarageMP && zip -rq ../GarageMP.zip . -x "*.DS_Store")
```

Notes:

- Built zip files are not tracked in git.
- Source of truth for client code is `Resources/Client/GarageMP/`.

## First-Time Setup

1. Join the server with the account that should become admin.
2. Run `/garagemp setup`.
3. Add a player to persistence with `/garagemp add <playerName>`.
4. Confirm state with `/garagemp info`.

## Daily Admin Commands

- `/garagemp help`
- `/garagemp status`
- `/garagemp limits`
- `/garagemp add <playerName>`
- `/garagemp remove <playerName>`
- `/garagemp list`
- `/garagemp save`
- `/garagemp clear <playerName>`
- `/garagemp addadmin <playerName>`
- `/garagemp removeadmin <playerName>`
- `/garagemp info`
- `/garagemp proxyclear <playerName|beammpID>`
- `/garagemp syncmode <proxy|file|status>`

Optional alias:

- No legacy alias is supported. Use `/garagemp ...` for all commands.

## Update Existing Installation

1. Stop server.
2. Backup `Resources/Server/GarageMP/data/`.
3. Replace:
   - `Resources/Server/GarageMP/main.lua`
   - `Resources/Client/GarageMP.zip`
4. Keep existing `data/` files.
5. Start server and validate with `/garagemp info`.

## Configuration

Config file:

- `Resources/Server/GarageMP/data/config.json`

Key settings:

- `autoSaveIntervalMs`
- `maxVehiclesPerPlayer`
- `serverMaxCarsPerPlayer` (set this to your BeamMP `MaxCars` value)
- `commandPrefix`
- `syncMode` (`proxy` to keep offline owners live via hosts, `file` to disable proxy syncing)
- `excludeGuestsAsHosts`
- `spawnMaxRetries`
- `retryBaseDelayMs`
- `removeMaxRetries`

## Data Storage

- `config.json` stores admins, persist list, and settings.
- `vehicles_<beammpID>.json` stores per-owner vehicle snapshots.

## Known Limitation

BeamMP cannot keep vehicles physically spawned when zero clients are connected. GarageMP persists vehicles and restores/re-hosts them when suitable clients are online.

When connected players do not have enough free vehicle slots, GarageMP keeps as many vehicles synced as capacity allows and queues overflow for later sync. Overflow always remains persisted on disk and can restore on owner login.
