"""Reads `xcrun simctl list devices available -j` on stdin; prints the UDID of an
iPhone simulator on the newest iOS runtime (CI only; names change with each Xcode)."""
import json
import re
import sys

devices = json.load(sys.stdin)["devices"]


def version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)


for runtime in sorted(devices, key=version, reverse=True):
    if "iOS" not in runtime:
        continue
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        sys.exit(0)
sys.exit("no iPhone simulator found")
