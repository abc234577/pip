"""
电脑端：被观看方。
- 抓取整块屏幕（可指定显示器 / 可服务端预裁剪）
- 用 WebRTC(H264/VP8) 实时推给 iOS
- 自带信令：iOS 连上 ws 后，电脑主动发 offer，iOS 回 answer
- 非 trickle ICE：等 ICE 收集完成后把 host 候选嵌进 SDP，局域网直连最稳

运行：
    pip install -r requirements.txt
    python sender.py --host 0.0.0.0 --port 8080 --monitor 1 --fps 30
iOS 填：ws://<电脑局域网IP>:8080/ws
"""
import argparse
import asyncio
import json
import logging
import time
import fractions

import numpy as np
from aiohttp import web
from av import VideoFrame
from aiortc import RTCPeerConnection, RTCSessionDescription, VideoStreamTrack
import mss

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("sender")

ARGS = None
pcs = set()


class ScreenTrack(VideoStreamTrack):
    """按固定帧率抓屏并输出 WebRTC 视频帧。"""

    def __init__(self, monitor: int, fps: int, crop=None, max_width=1920):
        super().__init__()
        self.fps = fps
        self.monitor = monitor
        self.crop = crop          # (left, top, width, height) 像素，服务端预裁剪；None=整屏
        self.max_width = max_width
        self._sct = mss.mss()
        self._mon = self._sct.monitors[monitor]
        self._interval = 1.0 / fps
        self._next = time.monotonic()

    async def recv(self):
        # 帧率节流
        now = time.monotonic()
        wait = self._next - now
        if wait > 0:
            await asyncio.sleep(wait)
        self._next += self._interval

        pts, time_base = await self.next_timestamp()

        region = self._mon
        if self.crop:
            l, t, w, h = self.crop
            region = {"left": self._mon["left"] + l, "top": self._mon["top"] + t,
                      "width": w, "height": h}

        raw = self._sct.grab(region)
        img = np.asarray(raw)          # BGRA
        bgr = img[:, :, :3]            # 丢 alpha

        # 过大就等比缩小，省带宽、降延迟
        h, w = bgr.shape[:2]
        if w > self.max_width:
            scale = self.max_width / w
            new = (int(w * scale) // 2 * 2, int(h * scale) // 2 * 2)
            import cv2
            bgr = cv2.resize(bgr, new, interpolation=cv2.INTER_AREA)

        frame = VideoFrame.from_ndarray(np.ascontiguousarray(bgr), format="bgr24")
        frame.pts = pts
        frame.time_base = time_base
        return frame


async def ws_handler(request):
    ws = web.WebSocketResponse(heartbeat=20)
    await ws.prepare(request)
    log.info("client connected: %s", request.remote)

    pc = RTCPeerConnection()
    pcs.add(pc)

    crop = None
    if ARGS.crop:
        crop = tuple(int(x) for x in ARGS.crop.split(","))
    track = ScreenTrack(ARGS.monitor, ARGS.fps, crop=crop, max_width=ARGS.max_width)
    sender = pc.addTrack(track)

    # 优先 H264，iOS 硬解省电
    try:
        from aiortc.rtcrtpsender import RTCRtpSender
        caps = RTCRtpSender.getCapabilities("video")
        h264 = [c for c in caps.codecs if c.mimeType == "video/H264"]
        others = [c for c in caps.codecs if c.mimeType != "video/H264"]
        if h264:
            for tr in pc.getTransceivers():
                if tr.sender == sender:
                    tr.setCodecPreferences(h264 + others)
    except Exception as e:
        log.warning("codec pref failed: %s", e)

    @pc.on("connectionstatechange")
    async def on_state():
        log.info("pc state: %s", pc.connectionState)
        if pc.connectionState in ("failed", "closed"):
            await pc.close()
            pcs.discard(pc)

    # 电脑主动发 offer
    offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    await _wait_ice_complete(pc)      # 等 ICE 收集完，候选嵌进 SDP
    await ws.send_json({"type": "offer", "sdp": pc.localDescription.sdp})
    log.info("offer sent")

    async for msg in ws:
        if msg.type == web.WSMsgType.TEXT:
            data = json.loads(msg.data)
            if data["type"] == "answer":
                await pc.setRemoteDescription(
                    RTCSessionDescription(sdp=data["sdp"], type="answer"))
                log.info("answer received, streaming...")
        elif msg.type == web.WSMsgType.ERROR:
            break

    await pc.close()
    pcs.discard(pc)
    log.info("client gone")
    return ws


async def _wait_ice_complete(pc, timeout=5.0):
    if pc.iceGatheringState == "complete":
        return
    fut = asyncio.get_event_loop().create_future()

    @pc.on("icegatheringstatechange")
    def _():
        if pc.iceGatheringState == "complete" and not fut.done():
            fut.set_result(True)

    try:
        await asyncio.wait_for(fut, timeout)
    except asyncio.TimeoutError:
        log.warning("ice gather timeout, send partial")


async def on_shutdown(app):
    await asyncio.gather(*[pc.close() for pc in list(pcs)], return_exceptions=True)
    pcs.clear()


def main():
    global ARGS
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="0.0.0.0")
    p.add_argument("--port", type=int, default=8080)
    p.add_argument("--monitor", type=int, default=1, help="mss 显示器序号，1=主屏")
    p.add_argument("--fps", type=int, default=30)
    p.add_argument("--max-width", type=int, default=1920, dest="max_width")
    p.add_argument("--crop", default="", help="服务端预裁剪 left,top,w,h（可选，裁剪也能在手机上做）")
    ARGS = p.parse_args()

    app = web.Application()
    app.router.add_get("/ws", ws_handler)
    app.on_shutdown.append(on_shutdown)
    log.info("listening ws://%s:%d/ws  monitor=%d fps=%d",
             ARGS.host, ARGS.port, ARGS.monitor, ARGS.fps)
    web.run_app(app, host=ARGS.host, port=ARGS.port)


if __name__ == "__main__":
    main()
