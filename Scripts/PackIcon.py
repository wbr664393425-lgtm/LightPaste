"""Pack native PNG representations into the macOS ICNS container."""
import struct
import sys
from pathlib import Path

folder = Path(sys.argv[1])
parts = []
for code, name in [
    (b"icp4", "icon_16x16.png"), (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"), (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"), (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png")
]:
    data = (folder / name).read_bytes()
    parts.append(code + struct.pack(">I", len(data) + 8) + data)
body = b"".join(parts)
Path(sys.argv[2]).write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
