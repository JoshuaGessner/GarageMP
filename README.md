# GarageMP Installation and Use Guide

GarageMP is a BeamMP server/client mod that persists selected players' vehicles across disconnects and server restarts.

This is the canonical project guide. Release packaging also uses this file.

## Included in This Repository

- `Resources/Server/GarageMP/main.lua`
- `Resources/Server/GarageMP/data/.gitkeep`
- `Resources/Client/GarageMP/` (client source)
- `README.md`

## Install

1. Stop your BeamMP server.
2. Build `Resources/Client/GarageMP.zip` from `Resources/Client/GarageMP/` (or download a release artifact).
3. Copy this repository's `Resources/` folder into your server root directory.
4. Confirm these paths exist:
   - `Resources/Server/GarageMP/main.lua`
   - `Resources/Client/GarageMP.zip`
5. Start the server.

Quick local build command:

```bash
(cd Resources/Client/GarageMP && zip -rq ../GarageMP.zip . -x "*.DS_Store")
```

Release package build command:

```bash
./scripts/package_garagemp.sh
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
   - `Resources/Client/GarageMP.zip` (rebuilt from source or from release)
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

When there is not enough live vehicle capacity across connected proxy hosts, GarageMP keeps as many vehicles synced as possible and queues the overflow. Queued overflow stays in persisted files and is restored on owner login or when proxy capacity becomes available.

