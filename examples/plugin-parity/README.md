# Plugin parity example (`parity.example` 1.0.0)

This is a minimal `LORKHAN_Addons` v1 addon. It contains no assets or binaries. The API is
described in `lorkhan/files/docs/LORKHAN/addons.md`.

| Path | Purpose |
| --- | --- |
| `server/lorkhan-plugin.json` | Canonical manifest bytes. The server package carries these exact bytes. |
| `client/ParityExample.omwscripts` | One GLOBAL and one CUSTOM script. Load it after `LORKHAN.omwscripts`. |
| `client/scripts/parity_example/manifest.lua` | Lua copy of the manifest, plus the SHA-256 of the JSON bytes. |
| `client/scripts/parity_example/global.lua` | Registers the addon. It handles `mark_camp` in GLOBAL (tier 0) and emits `camp_marked`. |
| `client/scripts/parity_example/actor.lua` | SELF handler for `wander_briefly` (tier 2). The player confirms first; then only this actor's AI changes, and the action completes asynchronously. |

The manifest is disabled by default (`default_enabled: false`). Enable it in the server's
plugin policy.

Build the complete example outside both repositories:

```powershell
python scripts/package-addon-example.py --server-root D:/wt/LorkhanServer --output D:/build/parity-example
```

Use the generated `ParityExample` folder as an OpenMW data directory and enable `ParityExample.omwscripts`
after `LORKHAN.omwscripts`. Startup synchronizes its fixed server package automatically. The server package
remains disabled until you enable it in Configuration -> Server Plugins.

The LORKHAN Lua suite checks that the canonical JSON encoding of `manifest.lua` equals
`server/lorkhan-plugin.json` byte for byte. If you edit either file, regenerate the other and
update `sha256`, which is the SHA-256 of the JSON bytes:
`4a44b0af71ffdda44c3a7f68fd70d340b4a0e8fa142b16fdfd2d107ef62e20b0`.
