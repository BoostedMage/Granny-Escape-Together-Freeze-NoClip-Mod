GRANNY: ESCAPE TOGETHER — FREEZE + NO-CLIP v0.1.2 ALPHA
For Steam BuildID 26710650 / Unreal Engine 5.8; tested only by Lua simulation,
not yet verified inside the game. Requires the existing UE4SS v4.0.0 loader.

CHANGES FROM v0.1.1 (based on diagnostic ZIPs 07:41 and 07:47, Nov 17)
* F6: Granny, Grandpa, spiders and other recognized AI still freeze. Grandpa's
  attack prevention and local damage backup are retained unchanged.
* THE GRANDDAUGHTER GHOST IS NO LONGER FROZEN IN PLACE. Keeping its actor alive
  with a paused tick was leaving a throbbing camera effect. Instead, while F6
  is active, the script tries the game's GhostMustBeDeletted and ClearTwitchTimer
  cleanup methods; requests K2_DestroyActor to remove visible ghosts; and
  resets active LOCAL camera shakes on F6 activation and ghost cleanup.
* The game's BP_GranddaughterSpawnManager has bGlobalCooldownActive and
  bOtherScreamerActive flags. Both are forced true only during freeze and are
  restored afterward. It also tries to PAUSE its own reflected timer handles
  (TryPrepareSpawnTimerHandle, InitialSpawnTimerHandle) using KismetSystemLibrary.
  Only timers verified to exist and pause are resumed on F6 OFF. Never pauses
  the global world/game timer, other players' timers, puzzles or interaction.
* Existing and newly appearing ghost actors are suppressed while F6 is on;
  BeginPlay hook and 2-second poll are used as fallback. This is best-effort;
  blueprint effect sources not identified by the logs may require follow-up.
* F7 Space ascends at about 150 cm/sec while held if UE reports held-key state,
  via smaller 40 ms movement steps instead of the earlier large vertical jumps.
  Ctrl downward movement and Shift speed are unchanged. Space tap fallback is
  smaller (15 cm) when held-key data is unavailable. No extra key lockout.
* F8 optionally logs ghost/manager state. Never required to use freeze.
* Flashlight flickering is not changed in this build: the logs do not identify
  a flashlight cause. Report whether it happens only during F7/no-clip.

KEYS
 F6           Freeze/unfreeze AI, suppress granddaughter while F6 is on
 F7           Toggle local no-clip/flying
 F8           Optional extended diagnostics
 WASD         Move while flying; Shift to move faster
 Hold Space   Slowly ascend while F7 is on (150 cm/sec when input detected)
 Hold Ctrl    Descend (same behavior as v0.1.1)
 PageDown     Alternative descend in steps

INSTALL / UPDATE
 1. Exit the game completely.
 2. Extract this ZIP to a fresh folder; double-click Install_Mod.cmd.
    It reuses your installed UE4SS and backs up your previous main.lua.
 3. Start the game normally through Steam, ideally offline or private coop.
 4. Try F6 BEFORE the granddaughter appears; wait to see if she still spawns
    or if the throbbing effect appears. Then turn F6 off, wait for normal
    ghost behavior, and turn F6 on while the girl is present.
 5. Test F7 by HOLDING Space and Ctrl. Watch for a slow steady climb.
 6. After closing the game, run Collect_Diagnostics.cmd and upload its ZIP.

CAUTIONS
 This is an alpha; no in-game confirmation of the new ghost cleanup or held
 Space controls yet. The ghost effect could be a post-process material rather
 than a camera shake; this build cannot promise to reset that material.
 Destroying a currently visible ghost is intentional and not reversible; new
 ghosts can spawn normally after F6 OFF (no permanent save modifications).
 Only local effects and game-world managers are touched, and all original
 manager flags/ticks/timer paused state are restored when F6 is disabled.
 Human-controlled Granny excluded. No multiplayer lockout. Network authority,
 server/client replication and the game's own online restrictions may differ;
 no anti-cheat or network protection bypasses are included. Test only in
 consenting private co-op. No changes to Steam files or game saves.

OFFICIAL UE4SS: https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0
