# Granny: Escape Together — Freeze + No-Clip Mod

**Version: v0.1.2 Alpha (working gameplay test reported November 17, 2026)**  
Platform: Windows Steam · Unreal Engine 5.8 · UE4SS v4.0.0  
Original development target: Steam build **26710650**. Later updates may affect compatibility.

An unofficial mod to freeze computer-controlled enemies and fly through walls in *Granny: Escape Together*. The original tester confirmed that v0.1.2 works in-game. Behavior can vary by game build, host authority, and multiplayer session.

## Features & controls

| Key | Action |
| --- | --- |
| **F6** | Toggle freezing enemy AI, including Granny, Grandpa, and spiders. Grandpa's weapon/attack logic is also targeted. |
| **F7** | Toggle local no-clip / flight. |
| **WASD** | Fly horizontally while no-clip is on. |
| **Hold Space** | Ascend gradually during no-clip. |
| **Hold Ctrl** | Descend during no-clip. |
| **Shift** | Move faster during no-clip. |
| **F8** | Optional diagnostics. Not required for freezing. |

While freeze is on, the mod tries to **suppress the granddaughter ghost's appearances and camera effects** rather than leaving her frozen in place. No radar is included.

## Install

1. Exit *Granny: Escape Together*.
2. Download `GrannyEscapeTogether_FreezeNoClip_v0.1.2_ALPHA.zip` from the GitHub release assets (not GitHub's automatic source-code ZIP).
3. Extract the ZIP and run **`Install_Mod.cmd`**.
4. The installer will locate the Steam game and reuse an existing UE4SS v4.0.0 installation. If it is missing, it can offer to download the loader from the [official UE4SS GitHub release](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0) with permission.
5. Start the game through Steam and press F6 or F7 in a level.

For an update, close the game and rerun `Install_Mod.cmd` from the new ZIP. To remove **this mod**, close the game and run `Uninstall_Mod.cmd` (does not remove third-party loader files).

## Multiplayer and cautions

The mod has **no deliberate multiplayer lockout**, but network replication and compatibility depend on the game's authority model and policies. Test only with consenting players in private sessions. Human-controlled Granny is excluded from AI freezing. No anti-cheat bypass or network protections bypass is provided.

The F6 damage guard may also suppress some environmental/trap damage while active. The game receives updates, and later game versions may break the mod. Back up important saves before installing unofficial mods.

## Diagnostics

`Collect_Diagnostics.cmd` makes a local troubleshooting ZIP. It does not automatically upload anything. **Do not publish generated diagnostic ZIPs** to public issues or the repository without reviewing them for personal information.

## Project files

The repo contains the Lua mod, installer and uninstaller PowerShell/CMD scripts, and diagnostic helper. The full installer ZIP is attached to the release as an asset. The upstream UE4SS loader, game files, and proprietary game assets are **not redistributed** here.

Unofficial community project; not affiliated with the game's developers or UE4SS maintainers.

**License:** No open-source license has been granted in this repository. Please ask the author before redistributing or reusing code.
