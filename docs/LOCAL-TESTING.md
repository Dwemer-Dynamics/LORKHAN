# Local ALMSIVI testing

## What is already deployed

- ALMSIVIserver runs in WSL on port 8089 with PostgreSQL, Apache, migrations, a private pairing key,
  and the deterministic mock LLM/TTS providers.
- The private client configuration is at `C:\Modlists\ALMSIVI\Config\almsivi-client.conf`. The
  pairing key is never printed by the setup script.
- The OpenMW Lua data package is deployed under `C:\Modlists\ALMSIVI\Data`.
- The exact-pinned Windows x64 engine is deployed under `C:\Modlists\ALMSIVI\OpenMW`.
- The active local server source is mirrored to `/var/www/html/ALMSIVIserver`, matching the stable
  local deployment layout used by HerikaServer and DialecticServer.

## Full local deploy

Run the client repository's deploy entrypoint from PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\deploy\full-local.ps1
```

It deploys ALMSIVIserver to WSL, builds the pinned ALMSIVI OpenMW targets, mirrors the engine and Lua
payload into `C:\Modlists\ALMSIVI`, preserves the local client IDs/media cache, refreshes the private
pairing configuration, updates the ALMSIVI OpenMW profile, and recreates the desktop shortcuts.

## OpenMW requirement

Stock OpenMW does not contain `openmw.almsivi`. Use the deployed ALMSIVI-patched OpenMW 0.51.0 build,
which was produced from the exact commit in `config/source-pins/openmw.json`. Do not substitute a
stock OpenMW executable.

## Install after OpenMW is configured

1. Configure the deployed ALMSIVI OpenMW folder with the user's legal Morrowind data and normal OpenMW
   user/profile paths.
2. Add the absolute `C:\Modlists\ALMSIVI\Data` directory as an OpenMW data directory. Keep it
   separate from Morrowind's original Data Files directory.
3. Enable `ALMSIVI.omwscripts` in the OpenMW launcher content list.
4. Set `ALMSIVI_CLIENT_CONFIG` to the absolute `C:\Modlists\ALMSIVI\Config\almsivi-client.conf` path before launching the
   patched OpenMW executable.
5. Confirm `http://127.0.0.1:8089/ALMSIVIserver/api/v1/health` works from Windows. If WSL localhost
   forwarding is disabled, run `scripts/deploy/enable-wsl-loopback.ps1` from an elevated PowerShell
   window. The native client intentionally rejects non-loopback server URLs.
6. In game, press F6 to open ALMSIVI, center the crosshair on an NPC, select the target, type a line,
   and send. F7 is the emergency halt fallback. All four ALMSIVI inputs can be rebound under
   Options > Scripts > ALMSIVI.
7. Use `Add aimed NPC to group` to include additional nearby actors. `Reset group to target` returns
   the conversation to the primary target only.

## What to verify in game

- the target name matches the NPC under the crosshair;
- a typed turn appears in the transcript and receives a mock response;
- push-to-talk records only while its semantic input is held and submits the resulting bounded WAV;
- opt-in open microphone visibly reports its privacy state and ignores silence through VAD;
- the generated short WAV plays through the actor voice path and subtitles remain visible;
- `inspect.report` returns a terminal result;
- `ai.follow`, `ai.stop`, and bounded `ai.wander` affect only the selected actor;
- `combat.start` waits for the visible Approve/Reject choice, while `combat.stop` remains immediate;
- `animation.play` accepts only `idle2` through `idle9`; `item.use` can select only an item already
  present in that actor's inventory and also waits for Approve/Reject;
- player inventory, stats, effects, factions, journal, cell, weather, nearby actors, and target state
  are sent only through the bounded read-only context snapshot;
- F7 stops ALMSIVI-owned speech/follow state;
- save/load and cell changes do not replay stale dialogue or actions.

Do not enter live provider credentials in the game client. Configure them only in the private server
environment, then switch `provider_driver` from `mock` to `openai-compatible`.

Microphone capture is implemented inside the restricted native bridge because OpenMW Lua API 129
does not expose it. It uses the Windows multimedia capture API and exposes only bounded semantic
start/stop/poll operations to Lua; it does not expose arbitrary devices, files, or network access.
