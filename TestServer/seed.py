#!/usr/bin/env python3
"""Seed a fresh, stock Immich test server for DarkRoom tests (stdlib only).

Runs next to the test server. Reads samples/manifest.json (written by a local, untracked selection
script) and uploads the files, creating:
  - an admin account and a second user (generated credentials in .seed-credentials, mode 600)
  - Live Photos as linked still+motion pairs, RAW+JPEG pairs as stacks
  - a synthetic animated GIF, an album, a couple of favourites and ratings
Results (asset ids by category) go to samples/seed-result.json.

Usage: python3 seed.py [--server http://127.0.0.1:2284] [--samples ./samples]
"""
import argparse
import json
import mimetypes
import os
import re
import secrets
import struct
import sys
import time
import urllib.error
import urllib.request
import uuid

ap = argparse.ArgumentParser()
ap.add_argument("--server", default="http://127.0.0.1:2284")
ap.add_argument("--samples", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "samples"))
args = ap.parse_args()
API = args.server.rstrip("/") + "/api"
HERE = os.path.dirname(os.path.abspath(__file__))
CREDS = os.path.join(HERE, ".seed-credentials")


def request(method, path, token=None, body=None, raw=None, content_type=None, ok=(200, 201, 204)):
    data, headers = None, {"Accept": "application/json", "devicemodel": "DarkRoomSeed", "devicetype": "script"}
    if body is not None:
        data, headers["Content-Type"] = json.dumps(body).encode(), "application/json"
    if raw is not None:
        data, headers["Content-Type"] = raw, content_type
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            text = r.read().decode() or "null"
            return r.status, json.loads(text)
    except urllib.error.HTTPError as e:
        payload = e.read().decode()
        if e.code in ok:
            return e.code, json.loads(payload or "null")
        raise RuntimeError(f"{method} {path} -> {e.code}: {payload[:300]}") from None


def wait_ready():
    for _ in range(90):
        try:
            request("GET", "/server/ping")
            return
        except Exception:
            time.sleep(2)
    sys.exit("server not reachable")


def credentials():
    if os.path.exists(CREDS):
        return json.load(open(CREDS))
    creds = {
        "admin": {"email": "admin@darkroom.test", "name": "Test Admin", "password": secrets.token_urlsafe(18)},
        "user": {"email": "viewer@darkroom.test", "name": "Test Viewer", "password": secrets.token_urlsafe(18)},
    }
    old = os.umask(0o077)
    try:
        with open(CREDS, "w") as f:
            json.dump(creds, f, indent=1)
    finally:
        os.umask(old)
    return creds


def login(c):
    return request("POST", "/auth/login", body={"email": c["email"], "password": c["password"]})[1]["accessToken"]


def iso(ts):
    """'2024-04-12 10:55:13.99-07' -> '2024-04-12T10:55:13.99-07:00'."""
    ts = ts.replace(" ", "T", 1)
    return re.sub(r"([+-]\d{2})$", r"\1:00", ts)


def upload(token, path, created, modified, extra=None):
    boundary = uuid.uuid4().hex
    fields = {"fileCreatedAt": iso(created), "fileModifiedAt": iso(modified), "filename": os.path.basename(path).split("-", 2)[-1]}
    fields.update(extra or {})
    parts = []
    for k, v in fields.items():
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
    ctype = mimetypes.guess_type(path)[0] or "application/octet-stream"
    parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="assetData"; filename="{fields["filename"]}"\r\n'
                 f'Content-Type: {ctype}\r\n\r\n'.encode())
    with open(path, "rb") as f:
        parts.append(f.read())
    parts.append(f"\r\n--{boundary}--\r\n".encode())
    _, res = request("POST", "/assets", token, raw=b"".join(parts), content_type=f"multipart/form-data; boundary={boundary}")
    return res["id"]


def make_gif(path):
    """Tiny 4-frame animated GIF (red/green/blue/white squares), no dependencies."""
    w = h = 64
    palette = bytes([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255])
    out = bytearray(b"GIF89a" + struct.pack("<HHBBB", w, h, 0xF1, 0, 0) + palette)
    out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"
    for color in range(4):
        out += b"\x21\xF9\x04\x04\x32\x00\x00\x00"
        out += b"\x2C" + struct.pack("<HHHHB", 0, 0, w, h, 0)
        # LZW with min code size 2 and a clear code before every 2 pixels (always valid, never grows)
        codes, clear, eoi = [], 4, 5
        for i in range(w * h):
            if i % 2 == 0:
                codes.append(clear)
            codes.append(color)
        codes.append(eoi)
        bits, nbits, data = 0, 0, bytearray()
        for c in codes:
            bits |= c << nbits
            nbits += 3
            while nbits >= 8:
                data.append(bits & 0xFF)
                bits >>= 8
                nbits -= 8
        if nbits:
            data.append(bits & 0xFF)
        out += b"\x02"
        for i in range(0, len(data), 255):
            chunk = data[i:i + 255]
            out += bytes([len(chunk)]) + chunk
        out += b"\x00"
    out += b"\x3B"
    with open(path, "wb") as f:
        f.write(out)


def main():
    wait_ready()
    creds = credentials()
    status, cfg = request("GET", "/server/config")
    if not cfg.get("isInitialized"):
        request("POST", "/auth/admin-sign-up", body=creds["admin"])
    admin = login(creds["admin"])
    request("POST", "/admin/users", admin, body={**creds["user"], "shouldChangePassword": False}, ok=(200, 201, 400))
    viewer = login(creds["user"])

    existing = request("POST", "/search/metadata", admin, body={"size": 1})[1]["assets"]["total"]
    if existing:
        print(f"already seeded ({existing} assets); nothing to do")
        return

    manifest = json.load(open(os.path.join(args.samples, "manifest.json")))
    result, stacks = {}, {}
    for item in manifest:
        f = os.path.join(args.samples, item["file"])
        extra = {}
        if "motion" in item:
            motion_id = upload(admin, os.path.join(args.samples, item["motion"]), item["fileCreatedAt"],
                               item["fileModifiedAt"], {"visibility": "hidden"})
            extra["livePhotoVideoId"] = motion_id
        aid = upload(admin, f, item["fileCreatedAt"], item["fileModifiedAt"], extra)
        result.setdefault(item["category"], []).append(aid)
        if "stack" in item:
            stacks.setdefault(item["stack"], []).append((item.get("stackPrimary"), aid))
        print(f"  uploaded {item['category']}: {item['file']}")

    for members in stacks.values():
        ids = [aid for primary, aid in sorted(members, key=lambda m: not m[0])]
        if len(ids) > 1:
            request("POST", "/stacks", admin, body={"assetIds": ids})

    gif = os.path.join(args.samples, "synthetic-animated.gif")
    make_gif(gif)
    now = time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime())
    result["gif"] = [upload(admin, gif, now, now)]

    # A few organising touches for list/filter tests
    still = result.get("jpg", []) + result.get("heic", [])
    if still:
        request("PUT", "/assets", admin, body={"ids": still[:2], "isFavorite": True, "rating": 4})
    album_assets = (result.get("live-heic-portrait", []) + result.get("cr3", []))[:4]
    _, album = request("POST", "/albums", admin, body={"albumName": "Sample Album", "assetIds": album_assets})
    result["album"] = [album["id"]]

    # The second user gets a couple of their own photos (multi-user tests)
    viewer_items = [m for m in manifest if m["category"] in ("jpg", "png")][:2]
    result["viewer"] = [upload(viewer, os.path.join(args.samples, m["file"]), m["fileCreatedAt"], m["fileModifiedAt"])
                        for m in viewer_items]

    with open(os.path.join(args.samples, "seed-result.json"), "w") as fh:
        json.dump(result, fh, indent=1)
    print(f"seeded: {sum(len(v) for v in result.values())} records -> samples/seed-result.json")


main()
