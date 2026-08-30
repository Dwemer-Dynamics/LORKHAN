# Local LORKHAN testing

## What is already deployed

- LORKHANserver runs in WSL on port 8090 with PostgreSQL, Apache, migrations, a private pairing key,
  and the deterministic mock LLM/TTS providers.
- The private client configuration is at `C:\Modlists\LORKHAN\Config\lorkhan-client.conf`. The
  pairing key is never printed by the setup script.
- The OpenMW Lua data package is deployed under `C:\Modlists\LORKHAN\Data`.
- The exact-pinned Windows x64 engine is deployed under `C:\Modlists\LORKHAN\OpenMW`.
- The active local server source is mirrored to `/var/www/html/LORKHANserver`, matching the stable
  local deployment layout used by HerikaServer and DialecticServer.

## Full local deploy

Run the client repository's deploy entrypoint from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\deploy\full-local.ps1
```

It deploys LORKHANserver to WSL, builds the pinned LORKHAN OpenMW targets, mirrors the engine and Lua
payload into `C:\Modlists\LORKHAN`, preserves the local client IDs/media cache, refreshes the private
pairing configuration, updates the LORKHAN OpenMW profile, and recreates the desktop shortcuts.

## OpenMW requirement

Stock OpenMW does not contain `openmw.lorkhan`. Use the deployed LORKHAN-patched OpenMW 0.51.0 build,
which was produced from the exact commit in `config/source-pins/openmw.json`. Do not substitute a
stock OpenMW executable.

## Install after OpenMW is configured

1. Configure the deployed LORKHAN OpenMW folder with the user's legal Morrowind data and normal OpenMW
   user/profile paths.
2. Add the absolute `C:\Modlists\LORKHAN\Data` directory as an OpenMW data directory. Keep it
   separate from Morrowind's original Data Files directory.
3. Enable `LORKHAN.omwscripts` in the OpenMW launcher content list.
4. Set `LORKHAN_CLIENT_CONFIG` to the absolute `C:\Modlists\LORKHAN\Config\lorkhan-client.conf` path before launching the
   patched OpenMW executable.
5. Start DwemerDistro Launcher and confirm `/LORKHANserver/api/v1/health` at `http://127.0.0.1:7514` works from Windows. The launcher refreshes the route to WSL port 8090 when the WSL address changes. If WSL localhost
   forwarding is disabled, run `scripts/deploy/enable-wsl-loopback.ps1` from an elevated PowerShell
   window. The native client intentionally rejects non-loopback server URLs.
6. In game, center the crosshair on an NPC and press F6. LORKHAN selects that NPC automatically and
   opens the compact chatbox. Click the text box, type a line, and press Enter; Escape closes the panel.
   F7 stops current LORKHAN work. Every visible LORKHAN control can be rebound under
   Options > Scripts > LORKHAN > Hotkeys. Only F6 and F7 are assigned on a new install.
7. Bind `Targeted NPC tools` to open the compact activation, group, dynamic-profile, actor-action and
   stop controls for the aimed NPC. `Manual AI Activate` toggles the aimed actor, or pins up to 12
   nearby actors when no actor is aimed. The Dynamic Profiles selector can manage the targeted NPC,
   a bounded nearby AI NPC, or the narrator without opening a master dashboard.
8. For `Attack aimed actor` or `Stop combat with aimed actor`, choose the action, aim at the second
   actor, and use `Targeted NPC tools` again. The server accepts only a different actor from the bounded nearby-actor
   snapshot. For `Go to aimed point` or `Escort me to aimed point`, choose the action, aim at a point
   in the current cell within 2048 units, and use `Targeted NPC tools` again; LORKHAN captures that ray hit rather than
   accepting model-authored coordinates. `Face me` turns toward the player; `Face aimed actor` uses the
   same two-stage targeted-tools confirmation and reports success only after the heading is observed. Bounded playback-gated rechat depth, separate interior/exterior scan and hearing distances, creatures, and hostile
   actors are controlled under Options > Scripts > LORKHAN. Managed NPCs inside the hearing distance join
   the bounded turn audience without replacing manually selected group members. Auto-managed actors already
   fighting the player are removed unless `Add hostile actors` is enabled; actors selected manually remain
   under user control. Rechat is evaluated only after completed playback and is fenced by the current
   target, session, generation and active-turn state. Automatic greetings, boredom, combat barks and
   timer-driven autonomy are excluded; any inherited controls for them remain disabled.
   The `Dialogue mode` hotkey opens routing choices: Standard adds normal spatial hearing, Close uses only
   the explicit group, Whisper uses the primary target only, and Shout doubles spatial hearing. Typed chat
   also accepts `|` for one Whisper turn, `||` for one Close turn, and `!!` for one Shout turn without
   changing the selected mode. `Mood and delivery...` applies an optional saved mood cue to typed and
   spoken turns; None and an empty custom cue keep ordinary chat unchanged.
9. The `LLM model` hotkey lists only revisioned choices created on LORKHANserver; `Server default`
   clears the per-session override. Dynamic Profiles > Targeted NPC assigns a server profile to the
   currently confirmed actor for this playthrough; `Playthrough default` clears that actor binding.
   Neither panel accepts an endpoint, API key, model name, profile text, or other free-form configuration.

## What to verify in game

- the target name matches the NPC under the crosshair;
- a typed turn appears in the transcript and receives a mock response;
- push-to-talk records only while its semantic input is held and submits the resulting bounded WAV;
- opt-in open microphone visibly reports listening/muted state, resumes after unmute, and honors the
  configured VAD sensitivity and silence-end delay;
- Standard, Close, Whisper and Shout produce the expected target/group/spatial audience;
- typed `|`, `||`, and `!!` prefixes are removed from the displayed message, affect only that turn, and
  leave the selected mode unchanged; the optional player mood reaches the NPC prompt but not the displayed text;
- playback-gated rechat continues only within its configured depth and never starts from an idle timer;
- automatic greetings, boredom and combat barks do not trigger;
- the generated short WAV plays through the actor voice path and subtitles remain visible;
- `inspect.report` returns a terminal result;
- `ai.follow`, same-cell `ai.travel`/`ai.escort`, `ai.stop`, and bounded `ai.wander` affect only the
  selected actor; replacement/stop matches the package LORKHAN started;
- `ai.face` is actor-local, times out after three seconds, cancels on combat/cell/target loss, and
  releases its yaw control on every terminal path;
- `combat.start` waits for the visible Approve/Reject choice, while `combat.stop` remains immediate;
  both aimed-actor commands require the two-stage targeted-tools confirmation and reject stale/out-of-context targets;
- `animation.play` accepts only `idle2` through `idle9`; `item.use` can select only an item already
  present in that actor's inventory and also waits for Approve/Reject;
- player inventory, stats, effects, factions, journal, cell, weather, nearby actors, and target state
  are sent only through the bounded read-only context snapshot;
- F7 stops LORKHAN-owned speech/follow state;
- model-slot and actor-profile choices update visibly, survive a fresh controls query, and affect only
  future accepted turns for the current session/actor scope;
- save/load and cell changes do not replay stale dialogue or actions.

Do not enter live provider credentials in the game client. Configure them only in the private server
environment, then switch `provider_driver` from `mock` to `openai-compatible`.

Microphone capture is implemented inside the restricted native bridge because OpenMW Lua API 129
does not expose it. It uses the Windows multimedia capture API and exposes only bounded semantic
start/stop/poll operations to Lua; it does not expose arbitrary devices, files, or network access.
