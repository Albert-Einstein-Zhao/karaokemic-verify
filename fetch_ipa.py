#!/usr/bin/env python3
"""下载最新一次 Actions 构建的 IPA 产物并解包到本地安装包目录。"""
import io
import json
import os
import subprocess
import sys
import time
import urllib.request
import zipfile

REPO = "Albert-Einstein-Zhao/karaokemic-verify"
LOCAL = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.abspath(os.path.join(LOCAL, "..", "雪宝K歌_iOS安装包"))

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass


def get_token():
    p = subprocess.run(["git", "credential", "fill"],
                       input=b"protocol=https\nhost=github.com\n\n",
                       capture_output=True, cwd=LOCAL)
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip()
    raise RuntimeError("no credential")


TOKEN = get_token()
H = {"Authorization": f"Bearer {TOKEN}",
     "Accept": "application/vnd.github+json",
     "User-Agent": "WorkBuddy-FetchIPA"}


def api(url, tries=6):
    last = None
    for i in range(1, tries + 1):
        try:
            return json.loads(urllib.request.urlopen(
                urllib.request.Request(url, headers=H), timeout=40).read())
        except Exception as e:
            last = e
            if i < tries:
                w = min(2 ** i, 15)
                print(f"  retry {i}/{tries} in {w}s ({e})")
                time.sleep(w)
    raise last


def main():
    runs = api(f"https://api.github.com/repos/{REPO}/actions/runs?per_page=5")["workflow_runs"]
    run = next((r for r in runs if r["head_sha"].startswith("f0ce9666")), None) or runs[0]
    print("run:", run["id"], run["status"], run["conclusion"], run["head_sha"][:8])

    if run["status"] != "completed":
        print("build not finished yet")
        return
    if run["conclusion"] != "success":
        print("build FAILED:", run["conclusion"])
        return

    arts = api(f"https://api.github.com/repos/{REPO}/actions/runs/{run['id']}/artifacts")["artifacts"]
    target = next((a for a in arts if a["name"] == "KaraokeMicVerify-unsigned"), None)
    if not target:
        print("artifact not found:", [a["name"] for a in arts])
        return
    print("artifact:", target["name"], target["size_in_bytes"], "bytes")

    print("downloading...")
    url = f"https://api.github.com/repos/{REPO}/actions/artifacts/{target['id']}/zip"
    raw = urllib.request.urlopen(urllib.request.Request(url, headers=H), timeout=180).read()
    print(f"  got {len(raw)} bytes (zip wrapper)")

    os.makedirs(DEST, exist_ok=True)
    # 第一层：Actions 的 zip 包装
    with zipfile.ZipFile(io.BytesIO(raw)) as z:
        names = z.namelist()
        ipa_name = next(n for n in names if n.endswith(".ipa"))
        ipa_bytes = z.read(ipa_name)

    out = os.path.join(DEST, "KaraokeMicVerify-unsigned.ipa")
    with open(out, "wb") as f:
        f.write(ipa_bytes)
    print("\nsaved:", out)
    print("size :", f"{len(ipa_bytes):,} bytes")

    # 校验 IPA 结构
    with zipfile.ZipFile(io.BytesIO(ipa_bytes)) as z:
        il = z.namelist()
        apps = [n for n in il if n.endswith(".app/Info.plist")]
        print("\n-- IPA contents --")
        print("entries:", len(il))
        print("Payload app:", apps[0].split("/")[1] if apps else "MISSING!")
        if "Payload/KaraokeMicVerify.app/KaraokeMicVerify" in il:
            print("executable: present")
        else:
            print("executable: MISSING!")


if __name__ == "__main__":
    main()