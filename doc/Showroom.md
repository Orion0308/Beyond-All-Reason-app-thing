# Unit Showroom

A small, staged scene: one unit (and an optional target) up close, a camera you can orbit, and a
stats panel underneath. Three modes:

| Mode | What happens |
|---|---|
| **Inspect** | Nobody shoots, nobody can die. With no target, the camera slowly turns around the unit. |
| **Target** | The subject attacks the target. The target holds still and can't die, so you can watch range, reload and accuracy. |
| **Duel** | Both units fight to the death, and the panel announces the winner. |

This is a prototype. Its purpose is to show how the pieces fit, so you can change and extend it.

---

## 1. The files

| File | Runs in | Job |
|---|---|---|
| `common/showroom.lua` | both | Shared, engine-free logic: message format, arena layout, stats maths |
| `luarules/gadgets/game_showroom.lua` | **synced** (gadget) | Spawns units, gives orders, cancels damage, reports results |
| `luaui/Widgets/gui_showroom.lua` | **unsynced** (widget) | Camera, stats panel, buttons and keys, `/showroom` command |
| `tools/StartScripts/startscript_showroom.txt` | engine | Launches a showroom game directly |
| `modoptions.lua` + `language/en/interface.json` | lobby | Declares the `showroom` modoption |
| `game_initial_spawn.lua`, `game_end.lua`, `game_team_com_ends.lua` | synced | One-line opt-outs: no commanders, no game over |
| `spec/common/showroom_spec.lua` | tests | Unit tests for `common/showroom.lua` |

---

## 2. Concepts you need first

### Synced vs unsynced: why there is a gadget AND a widget

Recoil runs every player's game in lockstep, with the same simulation on every machine. Code
that changes the simulation (creating units, giving orders, deciding damage) must run
identically everywhere. That is **synced** code, and in BAR it lives in **gadgets**
(`luarules/gadgets/`).

Code that only affects your own screen (camera, drawing, mouse, keyboard) is **unsynced**. It
mostly lives in **widgets** (`luaui/Widgets/`).

A widget **cannot** call `Spring.CreateUnit`. It has to ask a gadget. That's why the
showroom is split in two:

```
┌────────────── widget (your screen) ──────────────┐        ┌──────── gadget (simulation) ────────┐
│ button "Duel" clicked                            │        │                                     │
│   Spring.SendLuaRulesMsg("showroom:mode:duel") ──┼──────► │ gadget:RecvLuaMsg(msg, playerID)    │
│                                                  │        │   give attack orders, allow damage  │
│                                                  │        │   Spring.SetGameRulesParam(...)  ───┼──┐
│ widget:Update():                                 │        │                                     │  │
│   Spring.GetGameRulesParam("showroom_mode") ◄────┼────────┼─────────────────────────────────────┼──┘
│   point camera, draw panel                       │        └─────────────────────────────────────┘
└──────────────────────────────────────────────────┘
```

### The two channels

1. **Widget → gadget: `Spring.SendLuaRulesMsg(string)`.** The string is broadcast through the
   network to every client's synced code, where `gadget:RecvLuaMsg(msg, playerID)` receives it.
   *Every* gadget sees *every* message, so each one starts with a header (`"showroom:"`) and the
   gadget ignores anything else. Returning `true` from `RecvLuaMsg` marks the message as handled.

2. **Gadget → widget: game rules params.** `Spring.SetGameRulesParam(name, value)` (synced
   only) stores a number or string that any widget can read with
   `Spring.GetGameRulesParam(name)`. It's the simplest one-way channel: no callbacks, it survives
   `/luaui reload`, and no player can forge it.

   (Other options you'll meet in the codebase: `SendToUnsynced` plus `Script.LuaUI` for
   event-style pushes, and unit rules params (`SetUnitRulesParam`) for per-unit data.)

### Modoptions: switching the whole thing on

A **modoption** is a key/value pair in the start script's `[modoptions]` section (or set in the
lobby). Code reads it with `Spring.GetModOptions().showroom`. Both the gadget and the widget
start with:

```lua
if not Showroom.IsSession(Spring.GetModOptions()) then
	return false   -- gadget: "don't load me"; a widget just returns
end
```

So in a normal game neither file defines any call-ins and costs nothing. Note that
`IsSession` compares the value to `"1"`/`"true"`: modoptions are strings, and a switched-off
bool can arrive as `"0"`, which Lua treats as true.

---

## 3. The gadget, call-in by call-in (`game_showroom.lua`)

| Call-in / API | Used for |
|---|---|
| `gadget:RecvLuaMsg(msg, playerID)` | Receives `stage`, `mode` and `reset` from the widget. Spectators are ignored (`Spring.GetPlayerInfo` 3rd return). |
| `Spring.CreateUnit(defID, x, y, z, facing, teamID)` | Spawns the units. `facing` is 0 south, 1 east, 2 north, 3 west. `y` comes from `Spring.GetGroundHeight(x, z)`. |
| `Spring.DestroyUnit(id, selfd, reclaimed)` | Clears the stage. `reclaimed = true` means the unit vanishes with no explosion and no wreck. |
| `Spring.GiveOrderToUnit(id, CMD.X, params, options)` | `CMD.FIRE_STATE {0 hold / 2 fire at will}`, `CMD.MOVE_STATE {0 hold / 2 roam}`, `CMD.ATTACK {unitID}`, `CMD.STOP {}`. An attack order makes a mobile unit close to its range by itself. |
| `gadget:UnitPreDamaged(unitID, ...)` | Called before every hit lands. Returning `0, 0` (damage, impulse) cancels the hit. This is how "can't die" works. |
| `gadget:UnitDestroyed(unitID)` | Detects the end of a duel and publishes the winner. |
| `gadget:FeatureCreated(featureID)` | Remembers wrecks from the fight so the next stage can remove them (map trees and rocks are left alone). |
| `Spring.SetGlobalLos(allyTeam, true)` | Lets you see the target even when it's outside your unit's sight, e.g. for artillery. |
| `Spring.SetGameRulesParam(name, value)` | Publishes `showroom_subject`, `_target`, `_mode`, `_result` and `_revision`. |

**Teams.** The start script has two teams on different allyteams, so their units are enemies
and will shoot each other. Team 1 has no player or AI; the gadget gives it every order.

**Why `revision`?** The widget needs to know "this is a new stage, re-frame the camera". Unit IDs
can be reused, so a counter that increases on every stage or reset is the reliable signal.

---

## 4. The widget, piece by piece (`gui_showroom.lua`)

### Hiding the normal game UI

```lua
widgetHandler:HideInterface("showroom", { "Showroom", "Chat" })
```

This is BAR's widget-handler API (`luaui/barwidgets.lua`). Every widget's `DrawScreen` and
input is skipped except for the ones named, plus the menu buttons, which are always kept so you
can quit. World rendering (lighting, bloom, health bars over units) carries on as normal.
`widgetHandler:ShowInterface("showroom")` undoes it, and so does the widget being removed.

> **Only game widgets get `HideInterface`.** It works because this file lives in the game's
> `luaui/Widgets`. A copy in your personal `LuaUI/Widgets` folder still runs, but the HUD stays
> visible.

### The camera

The engine has several camera modes. The showroom uses the **fps camera** (mode 0) and sets its
exact position and rotation every frame from `widget:Update(dt)`:

```lua
local ex, ey, ez = CameraMath.EyeFromTarget(focus.x, focus.y, focus.z, pitch, yaw, distance)
local rx, ry    = CameraMath.LookAtRotation(ex, ey, ez, focus.x, focus.y, focus.z)
local dx, dy, dz = CameraMath.FwdFromRot(rx, ry)
Spring.SetCameraState({ name = "fps", mode = 0, px = ex, py = ey, pz = ez,
                        dx = dx, dy = dy, dz = dz, rx = rx, ry = ry, rz = 0, fov = 38 }, 0)
```

- `common/camera_math.lua` converts "orbit the target at this yaw, pitch and distance" into
  engine angles. `rx` is pitch in engine terms (π/2 = level, π = straight down) and `ry` is a
  compass bearing (0 = facing north).
- The last argument `0` is the transition time: snap, no engine smoothing. The widget smooths
  the focus point itself with `1 - exp(-rate * dt)`, which feels the same at any frame rate.
- `Spring.SetConfigInt("FPSClampPos", 0, true)` stops the fps camera being clamped inside the
  map. The trailing `true` means *overlay*: the setting isn't saved to the player's config.
- The yaw default of 0 looks north. The subject stands west and the target east, so the subject
  appears on the **left** and the target on the **right**, as in the sketch.

The `CAMERA` table at the top of the file holds every tuning value: FOV, pitch limits, drag
speed, zoom step, follow stiffness and auto-rotate speed.

### Mouse and keys

| Call-in | Behaviour |
|---|---|
| `widget:MousePress(x, y, button)` | Returning `true` makes this widget the **mouse owner**, so `MouseMove` and `MouseRelease` come here. Clicks on the panel go to buttons; anything above it starts an orbit drag. |
| `widget:MouseMove(x, y, dx, dy)` | `dx` turns the yaw and `dy` the pitch (clamped). |
| `widget:MouseWheel(up)` | Zooms. Returning `true` stops the engine camera zooming as well. |
| `widget:KeyPress(key, mods, isRepeat)` | `1`/`2`/`3` modes, `R` reset, `[`/`]` presets, `O` auto-rotate. Key codes come from `Spring.GetKeyCode("r")`. (Not `KEYSYMS`: widgets can only see the globals listed in `luaui/system.lua`, and reading a missing one at load time stops the whole widget loading.) **Caveat:** keybind actions run *before* widgets, so a key your keybind preset already uses never arrives here. The on-screen buttons always work. |
| `widgetHandler:AddAction("showroom", fn, nil, "t")` | Registers the `/showroom <unit> [target]` chat command (`"t"` = text action). |

Screen coordinates start at the **bottom-left** corner (y grows upward), so the panel is
`y < vsy * 0.30`.

### The panel

`widget:DrawScreen()` draws with immediate-mode GL: `gl.Color` + `gl.Rect` for boxes, and the
game's shared font (`WG.fonts.getFont()`) between `font:Begin()` and `font:End()`. Colour codes
inside strings are `"\255RGB"` with each channel as a byte (e.g. `"\255\120\235\140"` is green).

The stats come from `Showroom.UnitStats(unitDef, WeaponDefs, weaponsLib, armorType)`:
- `unitDef` fields: `health`, `metalCost`, `energyCost`, `buildTime`, `speed`, `sightDistance`,
  `weapons` (a list of `{ weaponDef = id }`), `armorType`, `radius`.
- For each weapon, `WeaponDefs[id].damages[armorType]` is the damage against that armor class
  (`[0]` = default). DPS uses `common/weapons.lua` (`GetDamagePerSecond`), the same function the
  in-game unit stats tooltip uses. That's why the panel's DPS is against the **other** unit's
  armor.
- Rows, labels, formats and which direction is "better" are all listed in `Showroom.ROWS`. To
  add a stat, add a field in `UnitStats` and a row there.

---

## 5. How to test it

You need a working BAR install with this repository as a dev game (see the main `README.md`:
create `devmode.txt` and clone this repo into `games/<name>.sdd`).

### A. Unit tests (no game needed)

From the repo root, with [lux](https://github.com/lumen-oss/lux) installed, run the whole suite
the same way CI does (`.github/workflows/test_unit.yml`):

```bash
lx --lua-version 5.1 test
```

Or only this file, with busted installed for Lua 5.1:

```bash
busted spec/common/showroom_spec.lua
```

### B. In game, from the start script

1. Open `tools/StartScripts/startscript_showroom.txt` and set `mapname` to a map you have
   installed (a small, flat one looks best).
2. Run the engine on the script from your BAR data directory. On Windows, for example:

   ```bash
   engine\<version>\spring.exe "games\BAR.sdd\tools\StartScripts\startscript_showroom.txt"
   ```

   (`$VERSION` in `gametype` resolves to your dev `.sdd`; if it doesn't, replace the line with
   `gametype = Beyond All Reason test-<anything>;` to match what the lobby shows for your dev
   game.)
3. Alternatively, in the lobby, start a **skirmish** against one AI with
   **Unit Showroom** switched on under the *Dev* modoptions. The AI's team becomes the target
   team. Pick an inactive AI (NullAI) if your lobby lists one: a real AI may give the target
   unit orders of its own. The start script avoids this entirely.

### C. What to check

| # | Do | Expect |
|---|---|---|
| 1 | Start the game | No commanders, no top bar or build menu; Pawn (left) and Grunt (right) facing each other; panel at the bottom |
| 2 | Drag with the mouse above the panel | Camera orbits the pair; it can't go under the ground |
| 3 | Mouse wheel | Zooms; the normal game camera doesn't move |
| 4 | Click **Target** | Pawn walks into range and shoots; Grunt doesn't fire back and its health doesn't drop |
| 5 | Click **Duel** | Both fight; one dies; panel shows "X wins"; the survivor stops |
| 6 | Click **Reset** | Both units back at their marks, full health, wreck gone |
| 7 | Click **Next ] >** a few times | New matchups; camera re-frames (the Sheldon artillery pair should be much wider) |
| 8 | Type `/showroom armcom` in chat | Lone commander, turntable rotation; Target/Duel say "needs a target" in the log |
| 9 | Type `/showroom armpw nosuchunit` | Pawn alone, log says unknown target |
| 10 | Quit | Next normal skirmish: HUD is back, no showroom panel, commanders spawn |

If something fails, open `infolog.txt` in the BAR data directory and search for `showroom` or
`Error`.

Under BAR's AI policy (`AI_POLICY.md`), AI-assisted code must be run and verified by a human
before it goes into a pull request, ideally with screenshots of these steps.

---

## 6. Ideas for expanding it

- **Unit picker:** open the existing unit library (`luaui/RmlWidgets/gui_unit_library`):
  `WG.UnitLibrary.open({ title = "SHOWROOM", onPick = function(name) ... end })`. It ships
  disabled, so it must be enabled first (see how `cmd_terraform_suite.lua` does it and undoes
  it).
- **Slow motion:** `Spring.SendCommands("slowdown")` / `"speedup"` from the widget (singleplayer).
- **Cinematic duel cam:** `WG.cinematicCamera` (`api_cinematic_camera.lua`) already has `Follow`,
  `Orbit` and `Shake`; hand control to it while a duel runs.
- **Groups:** stage 3 vs 3 by making `stage` take counts, and spawn in a line in `Layout`.
- **Arena dressing:** a dedicated small map, or `Spring.SetSunLighting` / atmosphere tweaks for
  a studio look.
- **RmlUi panel:** move the GL panel to an `.rml`/`.rcss` document (see `luaui/RmlWidgets/`) for
  proper layout, scrolling and styling.
- **Lobby button:** in Chobby, a "Showroom" entry that writes this start script with the chosen
  units in modoptions, e.g. `showroom_subject = armpw;`, which the gadget would read in `Initialize`.
