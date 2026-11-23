# Expedition 33: Clair Obscur - Coop (v2 Hybrid Architecture)

For those who come after, with your friends!

![](./docs/header_s.jpg)

## Architecture (v2 Rewrite)

This rewrite replaces all fragile Kismet bytecode patching (`*Patch.cs`) with a **hybrid architecture**:

1. **Base `.utoc` assets (unpatched upstream Kouzukii mod)** provide the Unreal widgets (`UserSwitchWidget`, `PlayerIndicator`), `CoopController` input bindings, `ModActor`, and base hooks.
2. **UE4SS Lua Runtime (`ue4ss/Mods/E33CoopV2`)** owns all state, character-first mapping, control transitions, UI customization, and CommonUI gamepad fixes — with zero bytecode splicing and zero tick-polling wars.

### Modules (`ue4ss/Mods/E33CoopV2/Scripts/e33coop/`)

| Module | Responsibility |
| --- | --- |
| `roster.lua` | Canonical playable character list (`Frey`/Gustave, `Lune`, `Maelle`, `Sciel`, `Monoco`, `Verso`) and game enum constants |
| `config.lua` | Single source of truth for per-character assignments persisted in `config.json`, v1 SaveGame migration, and independent per-character 6-bit battle random rolls + Retry keep-roll |
| `ue.lua` | Safe game-thread UE4SS wrappers, party/battle queries, and 3-player-safe `setController0User` |
| `battle.lua` | Character-first projection from actual spawned battle actors (spots `0..2`) directly into `ModActor.CoopConfig`, handling normal parties, `OverrideParty` (1–3 chars), and Reserve/Backup teams, plus turn toasts |
| `control.lua` | Unified `PC0` ownership state machine: exploration restore after battle & map changes, optional `START` guard during active battle, enemy-turn P1 defense reset, and one-shot event-driven Victory/Flee handover (`StartBattleEndFlow`) |
| `ui.lua` | Settings menu enhancement (`Random (P1/P2)` option, slot character labels, descriptions) and Team Screen `PlayerIndicator` (`P1`/`P2`/`P3`/`P?`) |
| `gamepad.lua` | Click-safe CommonUI Gamepad mode protection for non-primary players (tracks `HandleButtonPressed`/`Released` so menu clicks are never canceled; covers dialogues, choices, and fullscreen notifications like Relationship Up) |
| `hooks.lua` | Deadlock-free game-thread-only hook manager (no `LoopAsync` / `ExecuteInGameThread`, lazy Blueprint hook registration) |

## Features

- **Per-character assignments**: Settings remember the player assigned to each character (following them across party swaps, `OverrideParty`, and Reserve Teams). Unassigned characters default to Player 1 once any choice is saved.
- **Random (P1/P2) mode**: Assign any character to `Random (P1/P2)`. Each character rolls independently at battle start and keeps the same roll if you **Retry** a lost battle.
- **Turn indicator toast**: Shows `"Player N's Turn (Character)"` using `UserSwitchWidget` at the start of every player turn.
- **Exploration control persistence**: Whoever was exploring keeps control across map transitions, Victory/Flee screens, and after battles end.
- **Enemy-turn defense safety**: Always hands `PC0` back to Player 1 on every enemy turn and optionally blocks accidental `START` presses mid-battle.
- **Click-safe CommonUI Gamepad support**: Keeps Player 2 / Player 3 in Gamepad mode for dialogues, choices, menus, and fullscreen popups without canceling held button clicks or interfering with Player 1's mouse & keyboard.

## Installation

1. Install the **unpatched** base `expedition33_coop_P.{pak,ucas,utoc}` into `..\Expedition 33\Sandfall\Content\Paks\~mods`.
2. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) into `..\Expedition 33\Sandfall\Binaries\Win64\`.
3. Run the installer script:
   ```powershell
   .\scripts\Install-CoopV2.ps1 -GameDir "D:\SteamLibrary\steamapps\common\Expedition 33"
   ```
   If you previously installed a v1 bytecode-patched `.utoc`, pass `-BasePakDir "<folder with unpatched expedition33_coop_P.*>"` to restore the clean base assets automatically.

## Configuration (`Mods/E33CoopV2/config.json`)

Created automatically on first run. The per-slot `Character 1/2/3 Assignment` values of an existing `"Coop"` SaveGame are imported as `legacySlots`. Per-character choices saved by a v1 bytecode-patched `.utoc` are only imported if that patched `.utoc` is still installed on the first run: the unpatched base `CoopConfig` has no fields for them, so otherwise pick them again in Settings.

```json
{
  "assignments": {
    "Frey": 0,
    "Lune": 1,
    "Maelle": 3
  },
  "blockStartInBattle": true,
  "debug": false,
  "hasPerCharacterAssignments": true,
  "legacySlots": [0, 1, 2],
  "showTurnToast": true,
  "version": 2
}
```

- `debug`: set to `true` to enable verbose `[E33CoopV2] [DEBUG]` logs in `UE4SS.log`.
- `blockStartInBattle`: prevents accidental `START` presses during active combat from stealing `PC0` (still allowed during exploration and on Victory/Flee screens).
- `showTurnToast`: toggles the `"Player N's Turn (Character)"` toast at player turn start.

## Building the Base Assets (Upstream Reference)

The base Unreal assets under `./Sandfall` and `./Program.cs` remain untouched from upstream `6038f67`. See the original upstream instructions if you ever need to rebuild the base `.utoc` in Unreal Engine 5.4.
