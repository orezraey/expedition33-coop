# Expedition 33: Clair Obscur - Coop (v2)

For those who come after, with your friends!

![](./docs/header_s.jpg)

[Leia em português](./README.pt-BR.md)

This is a fork of [Kouzukii/expedition33-coop](https://github.com/Kouzukii/expedition33-coop). It keeps the original mod's
assets untouched and adds a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod, `E33CoopV2`, that fixes a number of
co-op problems and adds per-character settings. Tested with game version 1.5, the original mod's v0.9.6 files and a
UE4SS development build from October 2026.

## How it works

- During battles each player controls their own characters, including parrying and choosing actions.
- During exploration Player 1 has control by default, but any player can take over by pressing START (useful for
  leveling and choosing equipment for your own characters).

### Playing with friends remotely

Steam only offers "Remote Play Together" for games with built-in co-op, but you can use
[RemotePlayWhatever](https://github.com/m4dEngi/RemotePlayWhatever) as a workaround.

## What is different from the original mod

The original mod is a set of Unreal assets (`expedition33_coop_P.pak/.ucas/.utoc`). This fork uses those assets as
they are and adds a UE4SS Lua mod on top; nothing in the original files is patched.

### Settings and battles

- **Players are assigned per character, not per party slot.** In the original, Settings has "Character 1/2/3
  Assignment", tied to the party slot, so swapping the party order or a solo battle (e.g. the Sirène fight with only
  Maelle) gives the turn to the wrong player. Here each character remembers its player and keeps it across party
  swaps, solo battles and the reserve team. Once any choice is saved, characters nobody assigned go to Player 1.
- **`Random (P1/P2)` option.** Each character with this option rolls its player at the start of each battle and keeps
  the same roll when you retry a lost battle.
- **Turn indicator.** A "Player N's Turn (Character)" message appears at the start of each player turn.
- **Team screen badges.** The team screen shows `P1`/`P2`/`P3` next to each character.
- **Accidental START during battle is blocked** (optional), so a stray press doesn't take controller 0 in the middle
  of a fight. START still works during exploration and on the Victory/Flee screens.
- **Enemy turns always start with controller 0 back on Player 1**, so the base mod's defense routing starts from the
  same state every enemy turn.

### Exploration control

- **Whoever is exploring keeps control** after battles, on the Victory/Flee screens and across map changes. In the
  original, control could go back to Player 1 after changing maps.
- If that player's controller does not come back within 10 seconds after a map change (e.g. the pad was unplugged),
  control goes back to Player 1 and a warning is written to the log.

### Controllers, menus and dialogues for Player 2/3

- **Player 2/3 can advance dialogues with A.** In the original, dialogue lines could only be skipped by Player 1
  when Player 2 was exploring.
- **Player 2/3 can close fullscreen notifications** shown after dialogues (relationship level up, new gradient attack,
  etc.) with A.
- **Player 2/3 can answer confirmation popups** with A (confirm) and B (cancel). Hold-to-confirm popups still need
  Player 1.
- **The game stays in gamepad mode for Player 2/3**: no keyboard icons appearing in dialogues, and button presses in
  menus are never cancelled by the mod's own input-mode fixes.

### Mouse cursor

- **No more blinking cursor in the middle of the screen** when resting at an Expedition Flag or opening menus.
- The cursor is always hidden while Player 2/3 control the game and for the extra controllers; Player 1 keeps the
  game's normal mouse behaviour.

### Settings file

- Options live in `ue4ss\Mods\E33CoopV2\config.json` (see [Configuration](#configuration)). Per-slot choices from the
  original mod's save are imported on the first run.

## Installation

You need three things: the original co-op mod, UE4SS and `E33CoopV2`.

1. **Original co-op mod**: download the latest release of
   [Kouzukii/expedition33-coop](https://github.com/Kouzukii/expedition33-coop/releases) and unzip
   `expedition33_coop_P.pak/.ucas/.utoc` into `..\Expedition 33\Sandfall\Content\Paks\~mods` (create `~mods` if it
   doesn't exist).
2. **UE4SS**: install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) into
   `..\Expedition 33\Sandfall\Binaries\Win64\`. The game uses Unreal Engine 5.4, which the old stable v3.0.1
   (2024) may not support: use v4.0.0 or newer. This mod was tested with a development build from October 2026
   (commit `cdbc0b66`, shown as "v3.0.1 Beta" in `UE4SS.log`); v4.0.0 itself has not been tested yet.
3. **E33CoopV2**: download `E33CoopV2-<version>.zip` from this fork's
   [Releases](https://github.com/orezraey/expedition33-coop/releases) and copy the `ue4ss\Mods\E33CoopV2` folder into
   `..\Expedition 33\Sandfall\Binaries\Win64\ue4ss\Mods\`. The mod is enabled by its own `enabled.txt`.

   Or run the installer from the unzipped folder. It copies the scripts, keeps your `config.json` and adds
   `E33CoopV2 : 1` to `mods.txt`:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\scripts\Install-CoopV2.ps1 -GameDir "C:\Program Files (x86)\Steam\steamapps\common\Expedition 33"
   ```

   `-BasePakDir "<folder with the original expedition33_coop_P.*>"` also copies the original mod's files into
   `~mods`.

To update, replace the `Scripts` folder (or run the installer again). Your `config.json` is kept.

## Configuration

`..\Win64\ue4ss\Mods\E33CoopV2\config.json` is created on the first run. Player assignments are changed in the game's
Settings menu; the other options are edited in the file.

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

- `assignments`: player per character (`0` = Player 1, `1` = Player 2, `2` = Player 3, `3` = Random (P1/P2)).
- `blockStartInBattle`: block START from taking controller 0 during an active battle.
- `showTurnToast`: show the "Player N's Turn (Character)" message.
- `debug`: write detailed `[E33CoopV2] [DEBUG]` lines to `..\Win64\ue4ss\UE4SS.log`.
- `legacySlots`: the per-slot assignment imported from the original mod's save. It is used per party slot until you
  save a choice in Settings; from then on every character has its own entry in `assignments`.

The per-slot "Character 1/2/3 Assignment" values of an existing `Coop` save are imported as `legacySlots`.

## Issues

If something goes wrong, set `"debug": true` in `config.json`, reproduce it and open an issue with an exact
description and `..\Win64\ue4ss\UE4SS.log` attached.

### Known issues

- Press & hold actions in menus (Learn Skill, Upgrade Attributes, Level Weapon, hold-to-confirm popups) can only be
  done by Player 1, as in the original mod.

## For developers

### E33CoopV2 (Lua)

The mod lives in `ue4ss/Mods/E33CoopV2/Scripts`:

| Module | Responsibility |
| --- | --- |
| `main.lua` | Registers the hooks and wires the modules together |
| `roster.lua` | Playable characters (`Frey`/Gustave, `Lune`, `Maelle`, `Sciel`, `Monoco`, `Verso`) and game enum constants |
| `config.lua` | Per-character assignments in `config.json`, save migration, random rolls and Retry keep-roll |
| `ue.lua` | Safe UE4SS wrappers: party/battle queries, controller 0 user switching, dialogue/notification/popup lookups |
| `battle.lua` | Projects per-character assignments into the base mod's `CoopConfig` from the characters actually spawned in battle |
| `control.lua` | Controller 0 ownership: exploration restore after battles and map changes, START guard, enemy-turn reset, Victory/Flee handover |
| `gamepad.lua` | Gamepad mode for Player 2/3, A/B for dialogues, notifications and popups, mouse cursor handling |
| `ui.lua` | Settings menu options and Team screen `P1`/`P2`/`P3` badges |
| `hooks.lua` | Hook registration on the game thread, with lazy registration for Blueprint functions loaded later |

Run the offline tests with any Lua 5.4 interpreter:

```powershell
lua tests\run_tests.lua
```

### Base assets (original mod)

The Unreal assets under `./Sandfall` and `./Program.cs` are unchanged from upstream `6038f67`. To rebuild them:

- Clone the repository with its submodules: `git clone https://github.com/orezraey/expedition33-coop.git --recurse-submodules`
- Download [retoc](https://github.com/trumank/retoc) into the project root folder.
- Extract the game's assets into the `./Export` folder
  ```
  .\retoc.exe to-legacy "GAMEPATH\Expedition 33\Sandfall\Content\Paks" ".\Export"
  ```
- Start Unreal Engine 5.4 and open `./Sandfall/Sandfall.uproject`
- Package the project with the Shipping configuration under the `./Sandfall` directory (Such that `./Sandfall/Windows/Sandfall/Sandfall.exe` is created)
- Build the mod using `dotnet run --project Expedition33Coop.csproj` (.NET 10 SDK is required)

## Credits

Original mod by [Kouzukii](https://github.com/Kouzukii/expedition33-coop). MIT License, see [LICENSE](./LICENSE).
