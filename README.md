# GarageMP

GarageMP is a BeamMP server/client mod that persists selected players' vehicles across disconnects and server restarts.

## Repository Layout

- `Resources/Server/GarageMP/main.lua` - server plugin
- `Resources/Client/GarageMP/` - client mod sources used to build `GarageMP.zip`
- `scripts/package_garagemp.sh` - release packager
- `README_GarageMP.md` - end-user install/use guide bundled into release archives

## Build Release Package

```bash
bash scripts/package_garagemp.sh
```

Outputs:

- `dist/GarageMP/GarageMP.zip`
- `dist/GarageMP/GarageMP.zip.sha256`

## Upload Target

Intended GitHub repository:

- `https://github.com/JoshuaGessner/GarageMP`
