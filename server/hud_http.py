#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
hud_http.py — 骑士 HUD 的 HTTP 桥（给 App / 网页在没有 Web Bluetooth 时用）

背景：iOS WKWebView 不支持 Web Bluetooth；用这个桥，App 走 HTTP 让 Mac 转发 BLE，
      不需要原生 CoreBluetooth 也能先把 AI 语音/控屏链路跑通。

接口（默认 8001）：
  GET  /api/hud/state                 连接/屏幕状态
  POST /api/hud/connect               主动连板子
  POST /api/hud/send   {cmd}          发一条 v2 指令（UTF-8，自动分片）
  GET  /api/hud/events?since=N        拉取通知（按键 / 确认 / 状态）
  GET  /api/hud/dump                  读回当前屏幕内容（无屏验收）
  POST /api/hud/demo   {kind}         chat / ctrl / nav 演示

启动：
  .venv/bin/python server/hud_http.py            # 0.0.0.0:8001
  PORT=8001 .venv/bin/python server/hud_http.py
"""
from __future__ import annotations

import asyncio
import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))

from knight_hud import Hud, HudError, demo_chat, demo_ctrl, demo_nav  # noqa: E402

PORT = int(os.environ.get("PORT", "8001"))


class Service:
    """一个后台 asyncio 事件循环 + 常驻 Hud 连接"""

    def __init__(self):
        self.loop = asyncio.new_event_loop()
        self.hud = Hud(verbose=False)
        self.hud.on_event = self._on_event
        self.events: deque[tuple[int, str]] = deque(maxlen=400)
        self.seq = 0
        self.connected = False
        self.last_error = ""
        self.last_connect = 0.0
        threading.Thread(target=self.loop.run_forever, daemon=True).start()

    # ---------- 事件 ----------
    def _on_event(self, text: str):
        self.seq += 1
        self.events.append((self.seq, text))

    def state(self) -> dict:
        return {
            "connected": bool(self.hud.client and self.hud.client.is_connected),
            "device": getattr(self.hud.device, "address", "") if self.hud.device else "",
            "screen": self.hud.state,
            "mtu": getattr(self.hud.client, "mtu_size", None) if self.hud.client else None,
            "events": self.seq,
            "error": self.last_error,
        }

    # ---------- 协程调度 ----------
    def call(self, coro, timeout: float = 25.0):
        fut = asyncio.run_coroutine_threadsafe(coro, self.loop)
        return fut.result(timeout)

    def ensure(self, force: bool = False) -> bool:
        if self.hud.client and self.hud.client.is_connected and not force:
            return True
        if not force and time.time() - self.last_connect < 8:
            return False
        self.last_connect = time.time()
        try:
            self.call(self._connect(), timeout=20)
            return True
        except Exception as e:
            self.last_error = f"{type(e).__name__}: {e}"
            return False

    async def _connect(self):
        try:
            await self.hud.connect()
        except Exception:
            self.connected = False
            raise

    # ---------- 动作 ----------
    async def _send(self, cmd: str):
        if not (self.hud.client and self.hud.client.is_connected):
            await self._connect()
        await self.hud.send(cmd)

    async def _demo(self, kind: str):
        if not (self.hud.client and self.hud.client.is_connected):
            await self._connect()
        if kind == "ctrl":
            return await demo_ctrl(self.hud, auto=True)
        if kind == "nav":
            return await demo_nav(self.hud)
        await demo_chat(self.hud)
        return True


SVC = Service()


def _cors(h: BaseHTTPRequestHandler):
    h.send_header("Access-Control-Allow-Origin", "*")
    h.send_header("Access-Control-Allow-Headers", "Content-Type")
    h.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *a):
        print("[http]", fmt % a)

    def _out(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        _cors(self)
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode("utf-8") or "{}")
        except Exception:
            return {}

    def do_OPTIONS(self):
        self.send_response(204)
        _cors(self)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path, _, qs = self.path.partition("?")
        if path == "/api/hud/state":
            return self._out({"ok": True, **SVC.state()})
        if path == "/api/hud/events":
            since = 0
            for kv in qs.split("&"):
                k, _, v = kv.partition("=")
                if k == "since":
                    try:
                        since = int(v)
                    except ValueError:
                        since = 0
            rows = [{"n": n, "msg": m} for n, m in SVC.events if n > since]
            return self._out({"ok": True, "events": rows, "next": SVC.seq})
        if path == "/api/hud/dump":
            try:
                if not SVC.ensure():
                    return self._out({"ok": False, "error": SVC.last_error or "HUD 未连接"}, 503)
                d = SVC.call(SVC.hud.dump())
                return self._out({"ok": True, "screen": d})
            except Exception as e:
                return self._out({"ok": False, "error": f"{type(e).__name__}: {e}"}, 500)
        return self._out({"ok": False, "error": "not found"}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]
        b = self._body()
        try:
            if path == "/api/hud/connect":
                ok = SVC.ensure(force=True)
                return self._out({"ok": ok, **SVC.state()}, 200 if ok else 503)
            if path == "/api/hud/send":
                cmd = (b.get("cmd") or "").strip()
                if not cmd:
                    return self._out({"ok": False, "error": "cmd 为空"}, 400)
                if not SVC.ensure():
                    return self._out({"ok": False, "error": SVC.last_error or "HUD 未连接"}, 503)
                SVC.call(SVC._send(cmd))
                return self._out({"ok": True})
            if path == "/api/hud/demo":
                if not SVC.ensure():
                    return self._out({"ok": False, "error": SVC.last_error or "HUD 未连接"}, 503)
                ok = SVC.call(SVC._demo(b.get("kind", "chat")), timeout=90)
                return self._out({"ok": True, "result": bool(ok)})
        except HudError as e:
            return self._out({"ok": False, "error": str(e)}, 503)
        except Exception as e:
            return self._out({"ok": False, "error": f"{type(e).__name__}: {e}"}, 500)
        return self._out({"ok": False, "error": "not found"}, 404)


def main():
    print(f"Knight HUD HTTP bridge  http://0.0.0.0:{PORT}")
    print("  先从 Mac 连板子：curl -X POST localhost:8001/api/hud/connect")
    SVC.ensure()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    srv.serve_forever()


if __name__ == "__main__":
    main()
