# GarageMP Installation and Use Guide

GarageMP is a BeamMP server/client mod that persists selected players' vehicles across disconnects and server restarts.

## Included in This Repository

- `Resources/Server/GarageMP/main.lua`
- `Resources/Server/GarageMP/data/.gitkeep`
- `Resources/Client/GarageMP.zip`
- `README.md`

## Install

1. Stop your BeamMP server.
2. Copy this repository's `Resources/` folder into your server root directory.
3. Confirm these paths exist:
	- `Resources/Server/GarageMP/main.lua`
	- `Resources/Client/GarageMP.zip`
4. Start the server.

## First-Time Setup

1. Join the server with the account that should become admin.
2. Run `/garagemp setup`.
3. Add a player to persistence with `/garagemp add <playerName>`.
4. Confirm state with `/garagemp info`.

## Daily Admin Commands

- `/garagemp help`
- `/garagemp status`
- `/garagemp add <playerName>`
- `/garagemp remove <playerName>`
- `/garagemp list`
- `/garagemp save`
- `/garagemp clear <playerName>`
- `/garagemp addadmin <playerName>`
- `/garagemp removeadmin <playerName>`
- `/garagemp info`
- `/garagemp proxyclear <playerName|beammpID>`

Optional alias:

- `/pv ...` (if enabled in config)

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
- `commandPrefix`
- `allowPvAlias`
- `excludeGuestsAsHosts`
- `spawnMaxRetries`
- `retryBaseDelayMs`
- `removeMaxRetries`

## Data Storage

- `config.json` stores admins, persist list, and settings.
- `vehicles_<beammpID>.json` stores per-owner vehicle snapshots.

## Known Limitation

BeamMP cannot keep vehicles physically spawned when zero clients are connected. GarageMP persists vehicles and restores/re-hosts them when suitable clients are online.
