# Local acceptance run - 2026-08-03

Source commit: `b60908ed18044271fa615a233e120b15d288f464` on `codex/full-dialectic-parity`.
Server source commit: `40ebe0e59be36c13d1a8e115f4432c2fd4d9097c` on `codex/herika-ui-core-port`.

| Check | Result |
| --- | --- |
| WSL Python repository suite | PASS - 47 tests |
| Lua 5.1 fake-OpenMW runtime suite | PASS - 47 tests |
| CMake foundation build and CTest | PASS - 6/6 tests, including protocol, evidence, Lua structural/runtime, and native |
| OpenMW patch generation, validation, and exact-pin audit | PASS |
| Windows x64 Release product build | PASS - OpenMW 0.51.0 at pinned revision `f4bec41444` |
| Local client deployment | PASS - `C:\Modlists\ALMSIVI`; source and deployed `openmw.exe` SHA-256 both `63892e2445fd1ea651e2b00a806a7f0431c0468a49df38b8d8691ac041d8aaed` |
| Lua deployment | PASS - source and deployed `player.lua` SHA-256 both `997778ec2617dd99865d57a9904f38085fcebe5abef7507fa7d534f082244188` |
| Server deployment and health | PASS - `/var/www/html/ALMSIVIserver`, `almsivi.health.v1`, Apache running, worker loop and PHP worker use the active tree |
| Browser visual acceptance | PASS at 1280x720 desktop and true 390x844 mobile emulation for the principal hubs and page families; Config and Control embedded documents have no horizontal overflow |

The local Windows product build and deployment are proven. No unmodified OpenMW control build,
formal release package, clean uninstall, game launch, in-game interaction, controller matrix,
compatibility-mod matrix is claimed. ITT, STT, Background Life, and
model-triggering autonomy remain excluded from the active product scope. The durable evidence
recorder was not used because its standalone Clang lane is unavailable in this WSL distro; the
successful CMake native test is recorded above without relabelling it as standalone-Clang proof.
