#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
knight_hud.py — 骑士 HUD BLE 客户端（Mac 侧）

作用：把「骑士 App」的 AI 语音 / 语音控屏指令按 v2 协议推到 ESP32-S3 硬件板，
      并接收板子回传的状态、按键、确认结果。可单独跑演示，也被 ai_voice_loop.py 复用。

协议见 docs/hud/ai-hud-protocol.md

用法：
  .venv/bin/python server/knight_hud.py demo-chat        # 数字大冰对话演示
  .venv/bin/python server/knight_hud.py demo-ctrl        # 微信回复：步骤 + 确认
  .venv/bin/python server/knight_hud.py demo-ctrl --auto # 确认由脚本自动点（无人在板子前）
  .venv/bin/python server/knight_hud.py demo-nav         # 双行 HUD 镜像
  .venv/bin/python server/knight_hud.py watch 20         # 看 20 秒通知，按板子 BOOT 试试
  .venv/bin/python server/knight_hud.py send "S:listen"  # 发原始指令
  .venv/bin/python server/knight_hud.py dump             # 读回当前屏幕内容
"""
from __future__ import annotations

import argparse
import asyncio
import sys
import time

from bleak import BleakClient, BleakScanner

SVC = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
DEV_NAME = "ROADLINK-HUD"
FRAG = 16           # 每个分片的字节数（BLE 20 字节净荷 - 4 字节帧头）
FRAG_GAP = 0.012    # 分片间隔


class HudError(RuntimeError):
    pass


class Hud:
    def __init__(self, name: str = DEV_NAME, verbose: bool = True):
        self.name = name
        self.verbose = verbose
        self.client: BleakClient | None = None
        self.device = None
        self.state = "unknown"
        self.log_lines: list[str] = []      # 所有通知原文
        self._changed: asyncio.Event = asyncio.Event()
        self.on_event = None                # 外部回调（HTTP 桥 / UI 用）
        self._tx_lock = asyncio.Lock()      # 防止多路并发写把分片搅乱

    # ---------------- 连接 ----------------
    async def connect(self, timeout: float = 15.0) -> "Hud":
        print(f"[hud] 扫描 {self.name} …")
        self.device = await BleakScanner.find_device_by_name(self.name, timeout=timeout)
        if not self.device:
            raise HudError(f"没找到 {self.name}（确认板子已上电、蓝牙没被别的设备占用）")
        self.client = BleakClient(self.device, disconnected_callback=self._on_disconnect)
        await self.client.connect()
        await self.client.start_notify(TX, self._on_notify)
        # 等板子的版本 + 初始状态
        try:
            await self.wait_for(lambda s: s.startswith("V,"), timeout=4)
        except asyncio.TimeoutError:
            pass
        print(f"[hud] 已连接 {self.device.address}  mtu={getattr(self.client, 'mtu_size', '?')}")
        return self

    def _on_disconnect(self, _c):
        self.state = "disconnected"
        self._changed.set()

    def _on_notify(self, _char, data: bytearray):
        text = bytes(data).decode("utf-8", "replace")
        self.log_lines.append(text)
        if self.verbose:
            print(f"[hud] <- {text}")
        if text.startswith("S,"):
            self.state = text[2:]
        self._changed.set()
        if self.on_event:
            try:
                self.on_event(text)
            except Exception:
                pass

    async def close(self):
        if self.client:
            try:
                await self.client.disconnect()
            except Exception:
                pass
            self.client = None

    # ---------------- 发送 ----------------
    async def send(self, msg: str):
        """发一条逻辑消息；超过 FRAG 字节自动分片（全局串行，避免分片交错）"""
        async with self._tx_lock:
            await self._send_locked(msg)

    async def _send_locked(self, msg: str):
        if not self.client or not self.client.is_connected:
            raise HudError("HUD 未连接")
        data = msg.encode("utf-8")
        if len(data) <= FRAG:
            await self.client.write_gatt_char(RX, data)
            if self.verbose:
                print(f"[hud] -> {msg}")
            return
        chunks = [data[i:i + FRAG] for i in range(0, len(data), FRAG)]
        for i, ch in enumerate(chunks):
            last = (i == len(chunks) - 1)
            head = f"#{i:02x}!," if last else f"#{i:02x},"
            await self.client.write_gatt_char(RX, head.encode() + ch)
            await asyncio.sleep(FRAG_GAP)
        if self.verbose:
            print(f"[hud] -> {msg}  ({len(chunks)} 片)")

    # ---------------- 等待 ----------------
    async def wait_for(self, pred, timeout: float = 10.0) -> str:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for line in self.log_lines:
                if pred(line):
                    return line
            self._changed.clear()
            try:
                await asyncio.wait_for(self._changed.wait(), timeout=0.25)
            except asyncio.TimeoutError:
                pass
        raise asyncio.TimeoutError(f"等待超时：{timeout}s（当前状态 {self.state}）")

    async def wait_state(self, name: str, timeout: float = 8.0) -> None:
        await self.wait_for(lambda s: s == f"S,{name}", timeout=timeout)

    async def wait_gate(self, timeout: float = 12.0) -> bool:
        """等确认结果：G,1 确认 / G,0 取消（含超时）"""
        line = await self.wait_for(lambda s: s.startswith("G,"), timeout=timeout)
        return line.strip() == "G,1"

    async def dump(self) -> dict:
        """读回当前屏幕内容（无屏验收）"""
        self.log_lines.clear()
        await self.send("DUMP")
        await asyncio.sleep(0.5)
        out: dict = {"raw": list(self.log_lines)}
        for line in self.log_lines:
            k, _, v = line.partition(",")
            if k in ("M", "Q", "T", "G", "D1", "D2", "UP"):
                out[k] = v
            elif k in ("L", "K"):
                i, _, text = v.partition(",")
                out.setdefault(k, {})[int(i)] = text
        return out

    # ---------------- 语义化指令 ----------------
    async def idle(self):
        await self.send("S:idle")

    async def listen(self):
        await self.send("S:listen")

    async def think(self):
        await self.send("S:think")

    async def say(self, question: str, answer: str):
        if question:
            await self.send(f"Q:{question}")
        await self.send(f"A:{answer}")

    async def act_start(self, title: str):
        await self.send(f"T:{title}")

    async def act_step(self, idx: int, total: int, text: str):
        await self.send(f"K:{idx},{total},{text}")

    async def gate(self, text: str, yes: str = "确认", seconds: int = 8):
        await self.send(f"G:{text}|{yes}")

    async def hud(self, line1: str, line2: str = ""):
        await self.send(f"D:{line1}|{line2}")

    async def error(self, text: str):
        await self.send(f"E:{text}")

    async def beep(self):
        await self.send("BEEP")


# ================================================================
#  演示流程
# ================================================================
async def demo_chat(h: Hud):
    """数字大冰：一轮 AI 语音对话"""
    q = "链条一直响怎么办？"
    a = "多半是缺油或松紧不对。先看下垂量，再补链条油。"
    print("\n=== demo-chat：AI 语音对话 ===")
    await h.listen()
    await asyncio.sleep(1.2)
    await h.think()
    await asyncio.sleep(1.2)
    await h.say(q, a)
    await asyncio.sleep(2.0)
    d = await h.dump()
    assert d.get("M") == "say", f"期望 say 屏，实际 {d.get('M')}"
    assert "链条" in (d.get("Q") or ""), f"Q 回读异常：{d.get('Q')}"
    joined = "".join(d.get("L", {}).values())
    assert "链条油" in joined, f"回答回读异常：{joined}"
    print(f"[ok] say 屏回读 {len(d.get('L', {}))} 行：{joined}")
    # 长回答翻页
    long_a = "前方三百米连续右弯，先减速到四十，入弯前完成刹车，避开白线和碎石，出弯再补油。"
    await h.say("前方路况", long_a)
    await asyncio.sleep(1.0)
    d = await h.dump()
    print(f"[ok] 长回答折行 {len(d.get('L', {}))} 行")
    await h.hud("↱ 280m", "右转弯道")
    await asyncio.sleep(1.5)
    await h.idle()


async def demo_ctrl(h: Hud, auto: bool = False):
    """语音控屏：微信回复老王（步骤 → 确认 → 结果）"""
    print("\n=== demo-ctrl：AI 语音控屏（微信回复老王）===")
    reply = "二十分钟到"
    await h.say("回复老王：二十分钟到", "你好骑士，回复老王：二十分钟到")
    await asyncio.sleep(1.2)
    await h.act_start("微信回复老王")
    steps = ["打开微信", "找到联系人「老王」", "自动填入回复文字", "确认发送"]
    for i, s in enumerate(steps, 1):
        await h.act_step(i, len(steps), s)
        await asyncio.sleep(0.7)
    d = await h.dump()
    assert d.get("M") == "act" and len(d.get("K", {})) == 4, f"步骤回读异常：{d}"
    print(f"[ok] 操作卡 {len(d.get('K', {}))} 步：{[d['K'][i] for i in sorted(d['K'])]}")

    await h.gate("发给老王？", "确认发送", seconds=10)
    print("[..] 等待确认：按板子 BOOT 短按=确认 / 长按=取消" + ("（--auto 自动确认）" if auto else ""))
    if auto:
        await asyncio.sleep(2.0)
        await h.send("GA:1")
    ok = await h.wait_gate(timeout=14)
    print(f"[{'ok' if ok else 'cancel'}] 确认结果：{ok}")
    if ok:
        await h.hud("✓ 已回复", reply)
        await asyncio.sleep(1.2)
        await h.say("", "已经回复老王：二十分钟到。")
        await asyncio.sleep(1.5)
    await h.idle()
    return ok


async def demo_nav(h: Hud):
    print("\n=== demo-nav：双行镜像 ===")
    for a, b in [("↱ 280m", "右转弯道"), ("⚠ 前方碎石", "300m 减速"), ("✓ 已回复", "二十分钟到")]:
        await h.hud(a, b)
        await asyncio.sleep(1.4)
        d = await h.dump()
        assert d.get("D1") == a and d.get("D2") == b, f"镜像回读异常：{d}"
        print(f"[ok] 镜像：{a} / {b}")


async def cmd_watch(h: Hud, seconds: int):
    print(f"\n[watch] 监听 {seconds}s，按板子 BOOT 键试试（短按 B,short / 长按 B,long）")
    await asyncio.sleep(seconds)
    btns = [l for l in h.log_lines if l.startswith("B,")]
    print(f"[watch] 收到 {len(btns)} 次按键：{btns}")


# ================================================================
#  main
# ================================================================
async def amain(argv=None) -> int:
    ap = argparse.ArgumentParser(description="Knight HUD BLE 客户端 / 演示")
    ap.add_argument("action", nargs="?", default="demo-chat",
                    choices=["demo-chat", "demo-ctrl", "demo-nav", "watch", "send", "dump", "idle"])
    ap.add_argument("arg", nargs="?", default="")
    ap.add_argument("--auto", action="store_true", help="确认屏自动点确认（无人值守）")
    ap.add_argument("--quiet", action="store_true")
    a = ap.parse_args(argv)

    h = Hud(verbose=not a.quiet)
    try:
        await h.connect()
        if a.action == "demo-chat":
            await demo_chat(h)
            code = 0
        elif a.action == "demo-ctrl":
            ok = await demo_ctrl(h, auto=a.auto)
            code = 0 if ok else 3
        elif a.action == "demo-nav":
            await demo_nav(h)
            code = 0
        elif a.action == "watch":
            await cmd_watch(h, int(a.arg or 15))
            code = 0
        elif a.action == "send":
            await h.send(a.arg)
            code = 0
        elif a.action == "dump":
            import json
            print(json.dumps(await h.dump(), ensure_ascii=False, indent=2))
            code = 0
        else:
            await h.idle()
            code = 0
        return code
    except (HudError, AssertionError, asyncio.TimeoutError) as e:
        print(f"[fail] {type(e).__name__}: {e}")
        return 2
    finally:
        await h.close()


def main():
    sys.exit(asyncio.run(amain()))


if __name__ == "__main__":
    main()
