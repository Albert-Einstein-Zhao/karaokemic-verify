#!/usr/bin/env python3
"""
用 GitHub REST API 直接把本地提交推到远端，绕过 git 的 HTTPS 传输层。

背景：github.com:443 的 git 通道持续被重置/超时，但 api.github.com 通（HTTP 200），
     所以改用 API 建 blob / tree / commit / 更新 ref。

用法：python push_via_api.py
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request
import urllib.error

# Windows 控制台默认 GBK，装不下 → / ▸ 这类符号，强制 UTF-8 并降级替换
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

REPO = "Albert-Einstein-Zhao/karaokemic-verify"
API = f"https://api.github.com/repos/{REPO}"
LOCAL = os.path.dirname(os.path.abspath(__file__))


def sh(*args, binary=False):
    r = subprocess.run(args, cwd=LOCAL, capture_output=True)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed:\n{r.stderr.decode('utf-8', 'replace')}")
    if binary:
        return r.stdout
    # git 在 Windows 上按 UTF-8 输出路径（含中文文件名），
    # 必须显式用 utf-8 解码，否则中文名会被GBK 误解码成乱码，
    # 导致后续 open() 报Invalid argument。
    return r.stdout.decode("utf-8", "replace")


def get_token():
    """从 git credential helper 取 PAT。"""
    p = subprocess.run(
        ["git", "credential", "fill"],
        input=b"protocol=https\nhost=github.com\n\n",
        capture_output=True, cwd=LOCAL,
    )
    for line in p.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("password="):
            return line.split("=", 1)[1].strip()
    raise RuntimeError("未能从 git credential helper 取到凭据")


TOKEN = get_token()


def api(method, path, body=None, raw=None, content_type="application/json", retries=5):
    """调用 GitHub API。

    本机到api.github.com 的连接不稳定（实测会随机被重置/断开），
    所以每个请求都带指数退避重试。
    """
    url = path if path.startswith("http") else API + path
    headers = {
        "Authorization": f"Bearer {TOKEN}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "WorkBuddy-PushScript",
    }
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    if raw is not None:
        headers["Content-Type"] = content_type

    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=60) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")
            # 5xx 和 429 值得重试；4xx 是请求本身有问题，重试没用
            if e.code not in (429, 500, 502, 503, 504):
                raise RuntimeError(f"HTTP {e.code} {method} {path}\n{detail}")
            last = RuntimeError(f"HTTP {e.code} {method} {path}\n{detail}")
        except Exception as e:          # 连接被重置 / 超时 / 远端断开
            last = RuntimeError(f"{type(e).__name__} {method} {path}: {e}")

        if attempt < retries:
            wait = min(2 ** attempt, 20)
            print(f"    retry {attempt}/{retries} in {wait}s ({last})")
            time.sleep(wait)

    raise last


def main():
    # 1. 确认本地与远端是否已一致（避免重复推送）
    local_sha = sh("git", "rev-parse", "HEAD").strip()
    try:
        remote = api("GET", f"/git/ref/heads/main")
        remote_sha = remote["object"]["sha"]
    except RuntimeError:
        remote_sha = None

    print("local  HEAD:", local_sha)
    print("remote main:", remote_sha)
    if remote_sha == local_sha:
        print(">>> already up to date")
        return

    # 2. 收集要上传的文件。
    #    注意两个坑：
    #    a) 不能用 `git diff base..local` —— 远端 commit 对象本地不存在，diff 会报错。
    #    b) 不能直接用 `git ls-files` —— 它对非 ASCII 文件名会加引号并转义成
    #       "Windows\351\203\250..." 这种八进制形式，拼路径必然失败。
    #       这里统一用 -z（NUL 分隔、raw 模式）拿到原始字节路径，自己解码。
    out = sh("git", "-c", "core.quotepath=false", "ls-files", "-z", binary=True)
    tracked = [p.decode("utf-8", "replace")
               for p in out.split(b"\0") if p.strip()]
    changed = tracked

    print("\nuploading", len(changed), "tracked files (full tree rebuild)")
    if not changed:
        print(">>> no files")
        return

    # 3. 每个文件建 blob（带本地缓存，重跑时不用重复上传）
    print("\n-- creating blobs --")
    cache_path = os.path.join(LOCAL, ".push_blob_cache.json")
    try:
        with open(cache_path, "r", encoding="utf-8") as f:
            cache = json.load(f)
    except Exception:
        cache = {}

    blobs = {}
    for path in changed:
        full = os.path.join(LOCAL, path)
        # git ls-files 在Windows 上按 UTF-8 输出，但默认编码可能是 GBK，
        # 导致中文文件名（如「Windows部署手册_无Mac版.md」）open 失败。
        # 显式按 UTF-8 拼路径即可。
        try:
            with open(full, "rb") as f:
                content = f.read()
        except FileNotFoundError:
            print(f"  SKIP {path}  (not found locally, deleted?)")
            continue

        # 内容没变且缓存里有，直接复用
        import hashlib
        digest = hashlib.sha1(content).hexdigest()
        if cache.get(path, {}).get("digest") == digest:
            blobs[path] = cache[path]["sha"]
            print(f"  CACHED {path}  {blobs[path][:8]}")
            continue

        blob = api("POST", "/git/blobs",
                   body={"content": base64.b64encode(content).decode(),
                         "encoding": "base64"})
        blobs[path] = blob["sha"]
        cache[path] = {"digest": digest, "sha": blob["sha"]}
        print(f"  OK {path}  {blob['sha'][:8]}  ({len(content)} bytes)")
        # 每成功一个就落盘，整轮中途失败也不丢进度
        with open(cache_path, "w", encoding="utf-8") as cf:
            json.dump(cache, cf, indent=1, ensure_ascii=False)
        time.sleep(0.7)

    with open(cache_path, "w", encoding="utf-8") as f:
        json.dump(cache, f, indent=1, ensure_ascii=False)
    print("\n-- all blobs ready --")

    # 4. 建 tree（不带 base_tree，全量重建，避免依赖本地缺失的对象）
    print("\n-- creating tree --")
    tree_body = {"tree": [
        {"path": p, "mode": "100644", "type": "blob", "sha": s}
        for p, s in blobs.items()
    ]}
    tree = api("POST", "/git/trees", body=tree_body)
    print("  OK tree", tree['sha'][:8])
    if tree.get("truncated"):
        raise RuntimeError("tree 被截断，仓库文件过多，需分批处理")

    # 5. 建 commit
    print("\n-- creating commit --")
    msg = sh("git", "log", "-1", "--format=%B", local_sha).strip()
    commit = api("POST", "/git/commits", body={
        "message": msg,
        "tree": tree["sha"],
        "parents": [remote_sha],
    })
    print("  OK commit", commit['sha'][:8])

    # 6. 更新 ref（force=false，拒绝非快进）
    print("\n-- updating main ref --")
    updated = api("PATCH", "/git/refs/heads/main",
                  body={"sha": commit["sha"], "force": False})
    print("  OK main ->", updated['object']['sha'][:8])

    print("\n>>> push done:", local_sha[:8], "->", updated['object']['sha'][:8])
    print(">>> CI triggered - check Actions page")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print("\nFAILED:", e, file=sys.stderr)
        sys.exit(1)