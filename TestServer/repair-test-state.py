#!/usr/bin/env python3
"""Restores the seeded test library after interrupted DarkRoom test runs (test server only).

Un-hides seeded assets, removes DarkRoom metadata keys, re-stacks the RAW+JPEG pair and permanently
deletes "-edit" versions that tests created. Never touches anything that isn't a seeded asset or a test version.
"""
import json, sys, urllib.request, pathlib
secrets = pathlib.Path(__file__).parent / ".secrets"
creds = json.load(open(secrets / "credentials.json"))["admin"]
seed = json.load(open(secrets / "seed-result.json"))
BASE = "http://localhost:2283/api"

def req(method, path, body=None, token=None):
    r = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                               headers={"Content-Type": "application/json", **({"Authorization": "Bearer " + token} if token else {})})
    try:
        data = urllib.request.urlopen(r).read().decode()
        return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        return {"error": e.code, "body": e.read().decode()[:200]}

token = req("POST", "/auth/login", {"email": creds["email"], "password": creds["password"]})["accessToken"]
seeded = [i for k, ids in seed.items() if k not in ("album", "viewer") for i in ids]
for i in seeded:
    a = req("GET", f"/assets/{i}", token=token)
    if a.get("visibility") == "hidden" and not a.get("livePhotoVideoId") is None or a.get("visibility") == "hidden":
        # Live Photo motion clips are legitimately hidden; seeded ids are stills/videos, so un-hide.
        req("PUT", "/assets", {"ids": [i], "visibility": "timeline"}, token)
        print("unhid", a["originalFileName"])
    for key in ("darkroom.version", "darkroom.recipe"):
        req("DELETE", f"/assets/{i}/metadata/{key}", token=token)
    edits = req("GET", f"/assets/{i}/edits", token=token)
    if isinstance(edits, dict) and edits.get("edits"):
        req("DELETE", f"/assets/{i}/edits", token=token); print("removed built-in edits", a["originalFileName"])

# Test versions: "-edit." files (including trashed ones).
found = req("POST", "/search/metadata", {"originalFileName": "-edit.", "withDeleted": True, "size": 200}, token)["assets"]["items"]
ids = [a["id"] for a in found if "-edit." in a["originalFileName"]]
if ids:
    req("DELETE", "/assets", {"ids": ids, "force": True}, token); print("deleted test versions:", len(ids))

# Re-stack the camera pair (JPEG primary as seeded).
pair = seed["raw-jpeg-pair"]
infos = [req("GET", f"/assets/{i}", token=token) for i in pair]
if not any(x.get("stack") for x in infos):
    for x in infos:
        for s in req("GET", f"/stacks?primaryAssetId={x['id']}", token=token) or []:
            req("DELETE", f"/stacks/{s['id']}", token=token)
    jpeg = [x["id"] for x in infos if x["originalFileName"].lower().endswith((".jpg", ".jpeg"))]
    other = [x["id"] for x in infos if x["id"] not in jpeg]
    print("restack", req("POST", "/stacks", {"assetIds": jpeg + other}, token).get("id"))
print("ok")
