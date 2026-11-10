"""Build the paired parity.example mod from source; generated packages stay outside either repository."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--server-root", required=True, type=Path, help="Matching LorkhanServer source checkout")
parser.add_argument("--output", required=True, type=Path, help="External build output directory")
args = parser.parse_args()
client_root = Path(__file__).resolve().parents[1]
server_root = args.server_root.resolve()
output = args.output.resolve()
if output.is_relative_to(client_root) or output.is_relative_to(server_root):
    parser.error("Output must be outside both source repositories")
example = server_root / "examples/plugins/parity.example"
manifest = (example / "server/lorkhan-plugin.json").read_bytes()
if manifest != (client_root / "examples/plugin-parity/server/lorkhan-plugin.json").read_bytes():
    parser.error("Client and server addon manifest bytes differ")
metadata = (example / "manifest.json").read_bytes()
if json.loads(metadata)["name"] != "parity.example" or json.loads(metadata)["version"] != "1.0.0":
    parser.error("Unexpected example package identity")
files = {
    "manifest.json": metadata,
    "server/lorkhan-plugin.json": manifest,
    "server/plugin.php": (example / "server/plugin.php").read_bytes(),
}
files["checksums.sha256"] = "".join(
    hashlib.sha256(data).hexdigest() + "  " + name + "\n" for name, data in sorted(files.items())
).encode()
mod = output / "ParityExample"
mod.mkdir(parents=True, exist_ok=True)
for source in (client_root / "examples/plugin-parity/client").rglob("*"):
    if source.is_file():
        target = mod / source.relative_to(client_root / "examples/plugin-parity/client")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
archive = mod / "lorkhan-packages/parity.example/parity.example-1.0.0.dwpkg"
archive.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as package:
    for name, data in sorted(files.items()):
        info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
        info.external_attr = 0o100644 << 16
        package.writestr(info, data)
print(f"Built {archive}")
print(f"SHA-256 {hashlib.sha256(archive.read_bytes()).hexdigest()}")
print("Add ParityExample as an OpenMW data directory and load ParityExample.omwscripts after LORKHAN.omwscripts.")
print("The server half syncs at addon startup and installs disabled. Enable it in Configuration > Server Plugins.")
