# Moon Rover (`moon_rover`)

Two craftable Moon Rovers for **Luanti 5.10+**, both with 1-block obstacle climbing and continuous-timeline glTF tire animations:

1. **Moon Rover (`moon_rover:rover`)** — Drivable crewed rover (Quaternius CC0).
2. **Autonomous Moon Rover (`moon_rover:auto_rover`)** — Self-driving 64-slot chest rover with a built-in oven, material gatherer, tree chopper, crafter, and self-replicator (Kenney.nl CC0).

## Crafting Recipes

### Drivable Moon Rover (`moon_rover:rover`)
| Left | Center | Right |
| :--- | :--- | :--- |
| `wool:grey` | `default:sign_wall_steel` | `wool:grey` |
| *(empty)* | `default:steel_ingot` | *(empty)* |
| `wool:grey` | *(empty)* | `wool:grey` |

### Autonomous Moon Rover (`moon_rover:auto_rover`)
| Left | Center | Right |
| :--- | :--- | :--- |
| `wool:grey` | `wool:yellow` | `wool:grey` |
| *(empty)* | `default:steel_ingot` | *(empty)* |
| `wool:grey` | *(empty)* | `wool:grey` |

## Controls & Usage

### Drivable Moon Rover
- **Place:** Right-click open ground.
- **Board / Dismount:** Right-click rover (or press **Shift / Sneak** after boarding).
- **Drive / Reverse:** `W` / `S` (`up` / `down`), climbs 1-block obstacles (`stepheight = 1.15`).
- **Steer:** `A` / `D` (`left` / `right`) — inverted steering in reverse + stationary pivot turn.
- **Handbrake:** `Space` (`jump`).
- **Pick up:** Punch rover when unoccupied (or while driving it yourself).

### Autonomous Moon Rover
- **Open 64-slot Chest & Oven UI:** Right-click the rover. The rover pauses automatically while its inventory is open so you can take collected materials or give it items it hasn't found yet (such as `default:steel_ingot`, wool, coal, or iron lumps).
- **Autonomous Gathering:** Drives around automatically (climbing 1-block steps, avoiding cliffs & liquids), vacuums nearby dropped items, prioritizes valuable ores & replication ingredients first, chops whole tree columns, and falls back to lower-value stone/sand/dirt when no high-value targets are nearby.
- **Oven & Crafting:** Automatically smelts ores (iron lumps → steel ingots, etc.) using coal/sticks/wood fuel, crafts chopped wood into planks and `default:stick`, processes cotton & flowers into `wool:grey` and `wool:yellow`, and combines player-provided items with collected resources.
- **Self-Replication:** Once its 64-slot chest contains `4 × wool:grey`, `1 × wool:yellow`, and `1 × default:steel_ingot`, it crafts a new `moon_rover:auto_rover` and deploys it nearby (respecting protection and a local density cap).
- **Dug-Only Rule:** Never synthesizes free items and never places terrain blocks it has not dug from the world.
- **Pick up:** Punch when empty, or **Shift + punch** to drop stored contents and pick up.

## Rebuilding Assets

```bash
python3 tools/build_assets.py
```

Builds `models/moon_rover.glb` and `models/moon_rover_auto.glb` (skinned with 4 animated wheels on Luanti's continuous timeline: `0.0–1.0s` forward, `1.2–2.2s` reverse), extracts/bakes their textures, renders 64×64 icons, and validates both `.glb` files.

## Testing

```bash
lua tests/test_rover.lua
```

## License & Credits

- **Code:** MIT License — Copyright (c) 2026 `ronrob-lu` (see [LICENSE](LICENSE)).
- **Drivable Rover Model & Atlas:** Quaternius — CC0 1.0 Universal.
- **Autonomous Rover Model:** Kenney.nl — CC0 1.0 Universal.
