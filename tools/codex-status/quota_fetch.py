#!/usr/bin/env python3
"""抓取 GPT(Codex) 额度，输出统一 JSON 给桌面卡片。

GPT:  mode=codex  读 ~/.codex/auth.json 的 access_token/account_id
      GET https://chatgpt.com/backend-api/wham/usage
      返回 plan_type + rate_limit.primary_window(周) / secondary_window(5h)
      mode=session 用浏览器 __Secure-next-auth.session-token（实验性，接口结构未验证）
"""
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(DIR, "config.json")
CACHE_PATH = os.path.join(DIR, "cache.json")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")


class FetchError(Exception):
    pass


def _origin(url):
    parsed = urllib.parse.urlsplit(url)
    scheme = parsed.scheme.lower()
    default_port = 443 if scheme == "https" else 80 if scheme == "http" else None
    return scheme, (parsed.hostname or "").lower(), parsed.port or default_port


class SameOriginRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if _origin(req.full_url) != _origin(newurl):
            raise FetchError("拒绝跨域重定向，未转发认证信息")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def http_json(url, headers=None, timeout=20, proxy=None, cookie=None):
    h = {"User-Agent": UA, "Accept": "application/json"}
    if headers:
        h.update(headers)
    if cookie:
        h["Cookie"] = cookie
    req = urllib.request.Request(url, headers=h)
    handlers = [SameOriginRedirectHandler()]
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    opener = urllib.request.build_opener(*handlers)
    try:
        with opener.open(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise FetchError("token/key 失效 (401)")
        raise FetchError(f"HTTP {e.code}")


def load_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)


# ---------------- GPT ----------------

def jwt_exp(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload)).get("exp", 0)
    except Exception:
        return 0


def parse_gpt_window(w):
    if not w:
        return None
    secs = w.get("limit_window_seconds", 0)
    name = {18000: "5h", 604800: "周"}.get(secs, f"{secs // 86400}d" if secs >= 86400 else f"{secs // 3600}h")
    return {
        "id": name,
        "used_pct": w.get("used_percent", 0),
        "remaining": None,
        "total": None,
        "reset_at": w.get("reset_at"),
    }


def fetch_gpt_codex(gcfg, timeout, proxy):
    path = os.path.expanduser(gcfg.get("auth_json", "~/.codex/auth.json"))
    try:
        with open(path) as f:
            auth = json.load(f)
    except OSError:
        raise FetchError("未检测到 Codex 登录（请安装 Codex 并 codex login）")
    tokens = auth.get("tokens") or {}
    token, acct = tokens.get("access_token"), tokens.get("account_id")
    if not token:
        raise FetchError("auth.json 里没有 access_token，请运行 codex login")
    exp = jwt_exp(token)
    if exp and exp < time.time() + 60:
        raise FetchError("Codex token 已过期，运行一次 codex 或 codex login 刷新")
    data = http_json(
        "https://chatgpt.com/backend-api/wham/usage",
        headers={"Authorization": f"Bearer {token}", "chatgpt-account-id": acct or ""},
        timeout=timeout, proxy=proxy)
    rl = data.get("rate_limit") or {}
    windows = [w for w in (parse_gpt_window(rl.get("primary_window")),
                           parse_gpt_window(rl.get("secondary_window"))) if w]
    return {"ok": True, "level": data.get("plan_type") or "", "windows": windows}


def fetch_gpt_session(gcfg, timeout, proxy):
    st = gcfg.get("session_token", "")
    if not st:
        raise FetchError("未配置 gpt.session_token")
    sess = http_json("https://chatgpt.com/api/auth/session",
                     cookie=f"__Secure-next-auth.session-token={st}",
                     timeout=timeout, proxy=proxy)
    token = sess.get("accessToken")
    if not token:
        raise FetchError("session token 无效或已过期，请从浏览器重新复制")
    acct = sess.get("accountId") or ""
    data = http_json("https://chatgpt.com/backend-api/rate_limits",
                     headers={"Authorization": f"Bearer {token}",
                              **({"chatgpt-account-id": acct} if acct else {})},
                     timeout=timeout, proxy=proxy)
    # 结构未官方稳定，宽松解析：rate_limits[] 里取 window/usage
    windows = []
    for item in data.get("rate_limits") or []:
        win = item.get("window")
        used = item.get("used_percent")
        if used is None:
            u = item.get("usage") or {}
            used = u.get("percent")
        if win and used is not None:
            windows.append({"id": str(win), "used_pct": round(used),
                            "remaining": None, "total": None,
                            "reset_at": None})
    if not windows:
        raise FetchError("rate_limits 结构变化，原始 keys: " + ",".join(data.keys()))
    return {"ok": True, "level": "", "windows": windows}


def fetch_gpt(cfg, timeout, proxy):
    gcfg = cfg.get("gpt", {})
    mode = gcfg.get("mode", "codex")
    if mode == "codex":
        return fetch_gpt_codex(gcfg, timeout, proxy)
    return fetch_gpt_session(gcfg, timeout, proxy)


# ---------------- main ----------------

def main():
    try:
        cfg = load_config()
    except Exception as e:
        print(json.dumps({
            "updated": 0,
            "gpt": {"ok": False, "error": f"配置读取失败: {e}", "windows": []},
        }, ensure_ascii=False))
        return
    timeout = cfg.get("timeout_seconds", 20)
    proxy = cfg.get("proxy")

    result = {"updated": int(time.time())}
    cache = {}
    if os.path.exists(CACHE_PATH):
        try:
            with open(CACHE_PATH) as f:
                cache = json.load(f)
        except Exception:
            cache = {}

    changed = False
    try:
        result["gpt"] = fetch_gpt(cfg, timeout, proxy)
        cache = {"gpt": result["gpt"]}
        changed = True
    except Exception as e:
        old = cache.get("gpt")
        if old and old.get("ok"):
            old = dict(old, stale=True, error=str(e))
        result["gpt"] = old or {"ok": False, "error": str(e), "windows": []}

    if changed:
        cache["updated"] = result["updated"]
        try:
            with open(CACHE_PATH, "w") as f:
                json.dump(cache, f, ensure_ascii=False)
        except Exception:
            pass
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
