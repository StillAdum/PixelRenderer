#!/usr/bin/env python3
"""
converter.py v3 -- Video / Image -> chunked, compressed binary pixel data
for PixelRenderer v3.

ARCHITECTURE (v3)
-----------------
Instead of one giant base64/JSON blob, v3 emits:

    manifest.json        small metadata file
    chunk_000.bin        LZ4-compressed binary chunk
    chunk_001.bin
    ...

Each chunk holds `chunkFrames` frames (default 10). Inside a chunk, frames
are delta-encoded (keyframe + changed-pixel runs) then the whole chunk is
LZ4-compressed. This gives:

  * ~5-10x smaller files than v2 base64
  * constant converter memory (streams one chunk at a time)
  * constant player memory (downloads + decodes one chunk at a time)
  * instant startup (only chunk 0 needed to begin playback)

LIMITS
------
  * Max resolution: 1280x720 (720p). Larger is refused.
  * Max fps: 50.

USAGE
-----
    # 720p @ 40fps, default chunk=10 frames, default delta tolerance=6
    python3 converter.py input.mp4 -o out_dir --preset p720 --fps 40

    # 480p @ 30fps, lossless delta
    python3 converter.py input.mp4 -o out_dir --preset p480 --fps 30 --lossless

    # Custom resolution (refused if > 720p in either dimension)
    python3 converter.py input.mp4 -o out_dir --width 960 --height 540 --fps 30

    # Single image
    python3 converter.py photo.jpg -o out_dir --preset p720

    # Legacy v2 single-file output (one .lua table) for paste-into-ModuleScript
    python3 converter.py input.mp4 -o video.lua --format legacy-lua --preset p480

    # Live stream: real-time HTTP server, defaults to 360p @ 40fps
    python3 converter.py input.mp4 -o serve_dir --live

    # Live stream with options: custom port, loop, 480p
    python3 converter.py input.mp4 -o serve_dir --live --port 9000 --live-loop --preset p480

REQUIREMENTS
------------
    pip install opencv-python numpy pillow lz4
"""

import argparse
import base64
import json
import lz4.block
import os
import struct
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from typing import List, Optional, Tuple

try:
    import cv2
    import numpy as np
    from PIL import Image
except ImportError as e:
    print(
        "ERROR: missing dependency.\n"
        "Install with:  pip install opencv-python numpy pillow lz4\n"
        f"Detail: {e}",
        file=sys.stderr,
    )
    sys.exit(1)


# --------------------------------------------------------------------------- #
# Constants & limits
# --------------------------------------------------------------------------- #

SUPPORTED_VERSION = 3
MAX_WIDTH = 1280
MAX_HEIGHT = 720
MAX_FPS = 50

PRESETS = {
    # Low-res presets for the Frame backend (no EditableImage API needed).
    # These create one Frame instance per pixel, so keep the count low.
    "p16":  (16, 9),     # 144 px    — ultra-smooth, very blocky
    "p32":  (32, 18),    # 576 px    — smooth
    "p48":  (48, 27),    # 1,296 px  — smooth on most devices
    "p64":  (64, 36),    # 2,304 px  — smooth 40fps (recommended for Frame backend)
    "p96":  (96, 54),    # 5,184 px  — okay on desktop
    "p128": (128, 72),   # 9,216 px  — desktop, may drop frames
    # Standard presets (EditableImage backend recommended for these).
    "p240": (426, 240),
    "p360": (640, 360),
    "p480": (854, 480),
    "p720": (1280, 720),
}

# Default fps per preset when --fps not given (adaptive: lower res -> higher fps).
ADAPTIVE_FPS = {
    "p16":  50,
    "p32":  50,
    "p48":  50,
    "p64":  50,
    "p96":  45,
    "p128": 40,
    "p240": 50,
    "p360": 45,
    "p480": 35,
    "p720": 30,
}

DEFAULT_CHUNK_FRAMES = 10
DEFAULT_DELTA_TOLERANCE = 6   # per-channel; pixels within this are "unchanged"

# Live streaming defaults
LIVE_DEFAULT_PRESET = "p360"
LIVE_DEFAULT_FPS = 40
LIVE_DEFAULT_CHUNK_FRAMES = 4    # 100ms latency at 40fps
LIVE_DEFAULT_BUFFER_CHUNKS = 40  # ~4s rolling window at 4fpc/40fps
LIVE_DEFAULT_PORT = 8080


# --------------------------------------------------------------------------- #
# Frame resizing
# --------------------------------------------------------------------------- #

def _to_rgba_bytes(frame_bgr: np.ndarray) -> bytes:
    """BGR frame -> packed RGBA bytes (alpha=255)."""
    rgb = cv2.cvtColor(frame_bgr, cv2.COLOR_BGR2RGB)
    rgba = np.dstack([rgb, np.full(frame_bgr.shape[:2], 255, dtype=np.uint8)])
    return rgba.tobytes()


def _resize_letterbox(frame: np.ndarray, width: int, height: int) -> np.ndarray:
    h_src, w_src = frame.shape[:2]
    scale = min(width / w_src, height / h_src)
    new_w = max(1, int(round(w_src * scale)))
    new_h = max(1, int(round(h_src * scale)))
    resized = cv2.resize(frame, (new_w, new_h), interpolation=cv2.INTER_AREA)
    canvas = np.full((height, width, 3), (0, 0, 0), dtype=np.uint8)
    x_off = (width - new_w) // 2
    y_off = (height - new_h) // 2
    canvas[y_off:y_off + new_h, x_off:x_off + new_w] = resized
    return canvas


def _resize_stretch(frame: np.ndarray, width: int, height: int) -> np.ndarray:
    return cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)


def _resize_crop(frame: np.ndarray, width: int, height: int) -> np.ndarray:
    h_src, w_src = frame.shape[:2]
    target_ratio = width / height
    src_ratio = w_src / h_src
    if src_ratio > target_ratio:
        new_w = int(round(h_src * target_ratio))
        x_off = (w_src - new_w) // 2
        frame = frame[:, x_off:x_off + new_w]
    else:
        new_h = int(round(w_src / target_ratio))
        y_off = (h_src - new_h) // 2
        frame = frame[y_off:y_off + new_h, :]
    return cv2.resize(frame, (width, height), interpolation=cv2.INTER_AREA)


def resize_frame(frame: np.ndarray, width: int, height: int, mode: str) -> np.ndarray:
    if mode == "stretch":
        return _resize_stretch(frame, width, height)
    if mode == "crop":
        return _resize_crop(frame, width, height)
    return _resize_letterbox(frame, width, height)


# --------------------------------------------------------------------------- #
# Source detection
# --------------------------------------------------------------------------- #

def is_video(path: str) -> bool:
    if not os.path.isfile(path):
        return False
    cap = cv2.VideoCapture(path)
    ok = cap.isOpened()
    cap.release()
    return ok


def is_image(path: str) -> bool:
    if not os.path.isfile(path):
        return False
    try:
        Image.open(path).verify()
        return True
    except Exception:
        return False


# --------------------------------------------------------------------------- #
# Delta encoding
# --------------------------------------------------------------------------- #
# Per-frame binary payload format (before chunk-level LZ4):
#
#   uint8  frameType   0 = keyframe (full RGBA), 1 = delta
#   if keyframe:
#       width*height*4 bytes RGBA
#   if delta:
#       uint32 numSegments
#       for each segment:
#           uint32 skip   (unchanged pixels before this run)
#           uint32 run    (changed pixels in this run)
#           run * 4 bytes RGBA
#
# Delta tolerance: a pixel is "changed" if any channel differs by more than
# `tolerance` from the reference frame. tolerance=0 is lossless.

def encode_keyframe(rgba_bytes: bytes) -> bytes:
    return struct.pack("<B", 0) + rgba_bytes


def encode_delta(prev_rgba: np.ndarray, curr_rgba: np.ndarray,
                 tolerance: int) -> bytes:
    """Build a delta frame payload. Returns bytes starting with type byte 1.

    Binary layout (must match the Luau decoder exactly):
        uint8  type = 1
        uint32 numSegments
        for each segment:
            uint32 skip
            uint32 run
            run * 4 bytes RGBA   <-- inline, immediately after the run field
    """
    diff = np.abs(curr_rgba.astype(np.int16) - prev_rgba.astype(np.int16))
    changed = (diff[:, :, :3].max(axis=2) > tolerance).reshape(-1)

    out = bytearray()
    out += struct.pack("<B", 1)

    # First pass: count segments (a segment = one skip + one non-empty run).
    n = changed.shape[0]
    num_segments = 0
    i = 0
    while i < n:
        while i < n and not changed[i]:
            i += 1
        if i >= n:
            break  # trailing skip is not a segment; base already has those pixels
        while i < n and changed[i]:
            i += 1
        num_segments += 1
    out += struct.pack("<I", num_segments)

    # Second pass: write skip, run, and the run's RGBA bytes inline.
    flat = curr_rgba.reshape(-1)
    i = 0
    while i < n:
        skip = 0
        while i < n and not changed[i]:
            skip += 1
            i += 1
        if i >= n:
            break  # trailing skip; nothing to write
        run = 0
        run_start = i
        while i < n and changed[i]:
            run += 1
            i += 1
        out += struct.pack("<I", skip)
        out += struct.pack("<I", run)
        out += flat[run_start * 4:(run_start + run) * 4].tobytes()
    return bytes(out)


def build_frame_payload(prev_rgba: Optional[np.ndarray],
                        curr_rgba: np.ndarray,
                        is_keyframe: bool,
                        tolerance: int) -> bytes:
    if is_keyframe or prev_rgba is None:
        return encode_keyframe(curr_rgba.tobytes())
    return encode_delta(prev_rgba, curr_rgba, tolerance)


# --------------------------------------------------------------------------- #
# Chunk assembly + compression
# --------------------------------------------------------------------------- #
# Chunk binary (before LZ4):
#   for each frame:
#       uint32 framePayloadLen
#       framePayloadLen bytes   (the per-frame payload above)

def build_chunk_payload(frame_payloads: List[bytes]) -> bytes:
    out = bytearray()
    for p in frame_payloads:
        out += struct.pack("<I", len(p))
        out += p
    return bytes(out)


def lz4_compress(data: bytes) -> bytes:
    return lz4.block.compress(data, store_size=False, mode="high_compression")


def lz4_compress_fast(data: bytes) -> bytes:
    """Fast LZ4 compression for live streaming (lower CPU, slightly larger)."""
    return lz4.block.compress(data, store_size=False, mode="fast")


# --------------------------------------------------------------------------- #
# Video reading (incremental, chunked)
# --------------------------------------------------------------------------- #

def iter_video_frames(path: str, width: int, height: int, mode: str,
                      target_fps: float, max_seconds: Optional[float],
                      max_frames: Optional[int]):
    """Yield (rgba_bytes, src_frame_index) tuples, resizing on the fly."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise RuntimeError(f"could not open video: {path}")

    src_fps = cap.get(cv2.CAP_PROP_FPS) or target_fps
    src_fps = max(1.0, float(src_fps))
    if target_fps <= 0:
        target_fps = src_fps
    step = max(1.0, src_fps / target_fps)

    total_source = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    max_count = max_frames
    if max_seconds is not None:
        sec_limit = int(max_seconds * target_fps)
        max_count = sec_limit if max_count is None else min(max_count, sec_limit)

    frame_idx = 0.0
    next_grab = 0.0
    grabbed = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if frame_idx >= next_grab - 1e-6:
            resized = resize_frame(frame, width, height, mode)
            rgba = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
            rgba = np.dstack([rgba, np.full(rgba.shape[:2], 255, dtype=np.uint8)])
            yield rgba.tobytes(), int(frame_idx)
            next_grab += step
            grabbed += 1
            if max_count is not None and grabbed >= max_count:
                break
            if total_source > 0 and grabbed % 30 == 0:
                pct = (frame_idx / total_source) * 100
                sys.stderr.write(
                    f"\r  read {grabbed} frames ({pct:5.1f}% of source)...")
                sys.stderr.flush()
        frame_idx += 1
    cap.release()
    if total_source > 0 and grabbed > 0:
        sys.stderr.write("\n")


def iter_video_frames_np(path: str, width: int, height: int, mode: str,
                         target_fps: float, max_seconds: Optional[float],
                         max_frames: Optional[int]):
    """Like iter_video_frames but yields rgba np arrays (for delta math)."""
    cap = cv2.VideoCapture(path)
    if not cap.isOpened():
        raise RuntimeError(f"could not open video: {path}")
    src_fps = cap.get(cv2.CAP_PROP_FPS) or target_fps
    src_fps = max(1.0, float(src_fps))
    if target_fps <= 0:
        target_fps = src_fps
    step = max(1.0, src_fps / target_fps)
    total_source = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    max_count = max_frames
    if max_seconds is not None:
        sec_limit = int(max_seconds * target_fps)
        max_count = sec_limit if max_count is None else min(max_count, sec_limit)
    frame_idx = 0.0
    next_grab = 0.0
    grabbed = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if frame_idx >= next_grab - 1e-6:
            resized = resize_frame(frame, width, height, mode)
            rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
            rgba = np.dstack([rgb, np.full(rgb.shape[:2], 255, dtype=np.uint8)])
            yield rgba
            next_grab += step
            grabbed += 1
            if max_count is not None and grabbed >= max_count:
                break
            if total_source > 0 and grabbed % 30 == 0:
                pct = (frame_idx / total_source) * 100
                sys.stderr.write(
                    f"\r  read {grabbed} frames ({pct:5.1f}% of source)...")
                sys.stderr.flush()
        frame_idx += 1
    cap.release()
    if total_source > 0 and grabbed > 0:
        sys.stderr.write("\n")


# --------------------------------------------------------------------------- #
# Multithreaded frame encoding
# --------------------------------------------------------------------------- #

def encode_one_frame(args):
    """Worker: takes (prev_rgba, curr_rgba, is_keyframe, tolerance) and returns
    the frame payload bytes. prev_rgba may be None."""
    prev, curr, is_keyframe, tolerance = args
    return build_frame_payload(prev, curr, is_keyframe, tolerance)


def encode_chunk_threaded(frames: List[np.ndarray], prev_last: Optional[np.ndarray],
                          tolerance: int, executor: ThreadPoolExecutor) -> List[bytes]:
    """Encode a list of rgba arrays into frame payloads, using a thread pool.
    The first frame is a keyframe if prev_last is None."""
    tasks = []
    prev = prev_last
    for i, curr in enumerate(frames):
        is_key = (prev is None)
        # capture prev per-task (it's the same object reference, fine for read)
        tasks.append((prev, curr, is_key, tolerance))
        prev = curr
    payloads = list(executor.map(encode_one_frame, tasks))
    return payloads


# --------------------------------------------------------------------------- #
# v3 output writer
# --------------------------------------------------------------------------- #

def write_v3_video(path: str, out_dir: str, width: int, height: int, mode: str,
                   target_fps: float, max_seconds: Optional[float],
                   max_frames: Optional[int], chunk_frames: int,
                   tolerance: int, workers: int) -> dict:
    os.makedirs(out_dir, exist_ok=True)
    manifest = {
        "version": SUPPORTED_VERSION,
        "type": "video",
        "width": width,
        "height": height,
        "fps": target_fps,
        "encoding": "rgba32",
        "compression": "lz4",
        "delta": True,
        "deltaTolerance": tolerance,
        "keyframeInterval": chunk_frames,
        "chunkFrames": chunk_frames,
        "frameCount": 0,
        "chunks": [],
    }

    executor = ThreadPoolExecutor(max_workers=workers)
    chunk_index = 0
    frame_start = 0
    total_frames = 0
    prev_last: Optional[np.ndarray] = None
    buffer_frames: List[np.ndarray] = []

    try:
        for rgba in iter_video_frames_np(path, width, height, mode,
                                         target_fps, max_seconds, max_frames):
            buffer_frames.append(rgba)
            if len(buffer_frames) >= chunk_frames:
                payloads = encode_chunk_threaded(
                    buffer_frames, prev_last, tolerance, executor)
                chunk_payload = build_chunk_payload(payloads)
                compressed = lz4_compress(chunk_payload)
                chunk_file = os.path.join(out_dir, f"chunk_{chunk_index:06d}.bin")
                with open(chunk_file, "wb") as f:
                    f.write(compressed)
                manifest["chunks"].append({
                    "index": chunk_index,
                    "frameStart": frame_start,
                    "frameCount": len(buffer_frames),
                    "compressedSize": len(compressed),
                    "uncompressedSize": len(chunk_payload),
                })
                total_frames += len(buffer_frames)
                frame_start += len(buffer_frames)
                prev_last = buffer_frames[-1].copy()
                buffer_frames = []
                chunk_index += 1
                sys.stderr.write(
                    f"\r  wrote chunk {chunk_index} "
                    f"({total_frames} frames, {len(compressed)/1024:.0f} KB)")
                sys.stderr.flush()

        # flush remaining frames (INSIDE the try, before executor shutdown)
        if buffer_frames:
            payloads = encode_chunk_threaded(
                buffer_frames, prev_last, tolerance, executor)
            chunk_payload = build_chunk_payload(payloads)
            compressed = lz4_compress(chunk_payload)
            chunk_file = os.path.join(out_dir, f"chunk_{chunk_index:06d}.bin")
            with open(chunk_file, "wb") as f:
                f.write(compressed)
            manifest["chunks"].append({
                "index": chunk_index,
                "frameStart": frame_start,
                "frameCount": len(buffer_frames),
                "compressedSize": len(compressed),
                "uncompressedSize": len(chunk_payload),
            })
            total_frames += len(buffer_frames)
            sys.stderr.write(
                f"\r  wrote chunk {chunk_index} "
                f"({total_frames} frames, {len(compressed)/1024:.0f} KB)\n")
            buffer_frames = []
    finally:
        executor.shutdown(wait=True)

    manifest["frameCount"] = total_frames
    if total_frames == 0:
        raise RuntimeError(f"no frames decoded from {path}")

    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    return manifest


def write_v3_image(path: str, out_dir: str, width: int, height: int,
                   mode: str) -> dict:
    os.makedirs(out_dir, exist_ok=True)
    img = Image.open(path).convert("RGB")
    arr = np.array(img)
    resized = resize_frame(arr, width, height, mode)
    rgb = cv2.cvtColor(resized, cv2.COLOR_RGB2BGR) if resized.ndim == 3 else resized
    # arr is RGB already; keep RGB and add alpha
    rgba = np.dstack([resized, np.full(resized.shape[:2], 255, dtype=np.uint8)])

    payload = encode_keyframe(rgba.tobytes())
    chunk_payload = build_chunk_payload([payload])
    compressed = lz4_compress(chunk_payload)

    with open(os.path.join(out_dir, "chunk_000.bin"), "wb") as f:
        f.write(compressed)

    manifest = {
        "version": SUPPORTED_VERSION,
        "type": "image",
        "width": width,
        "height": height,
        "fps": 1,
        "encoding": "rgba32",
        "compression": "lz4",
        "delta": False,
        "deltaTolerance": 0,
        "keyframeInterval": 1,
        "chunkFrames": 1,
        "frameCount": 1,
        "chunks": [{
            "index": 0,
            "frameStart": 0,
            "frameCount": 1,
            "compressedSize": len(compressed),
            "uncompressedSize": len(chunk_payload),
        }],
    }
    with open(os.path.join(out_dir, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    return manifest


# --------------------------------------------------------------------------- #
# Legacy v2 single-file output (one .lua table)
# --------------------------------------------------------------------------- #

def write_legacy_lua(path: str, out_path: str, width: int, height: int,
                     mode: str, target_fps: float, max_seconds: Optional[float],
                     max_frames: Optional[int]) -> None:
    frames: List[str] = []
    effective_fps = target_fps
    cap = cv2.VideoCapture(path)
    src_fps = cap.get(cv2.CAP_PROP_FPS) or target_fps
    src_fps = max(1.0, float(src_fps))
    if target_fps <= 0:
        target_fps = src_fps
    step = max(1.0, src_fps / target_fps)
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    max_count = max_frames
    if max_seconds is not None:
        max_count = int(max_seconds * target_fps) if max_count is None else min(max_count, int(max_seconds * target_fps))
    fi = 0.0
    ng = 0.0
    grabbed = 0
    while True:
        ret, frame = cap.read()
        if not ret:
            break
        if fi >= ng - 1e-6:
            resized = resize_frame(frame, width, height, mode)
            frames.append(base64.b64encode(_to_rgba_bytes(resized)).decode())
            ng += step
            grabbed += 1
            if max_count is not None and grabbed >= max_count:
                break
        fi += 1
    cap.release()
    effective_fps = min(target_fps, src_fps)

    lines = [
        "-- Auto-generated by converter.py (legacy v2) -- do not edit by hand.",
        f"-- {width}x{height} @ {effective_fps:.2f} fps, {len(frames)} frames",
        "",
        "return {",
        f"\tversion    = 2,",
        f'\ttype       = "video",',
        f"\twidth      = {width},",
        f"\theight     = {height},",
        f"\tfps        = {effective_fps:g},",
        f"\tframeCount = {len(frames)},",
        f'\tencoding   = "rgba32",',
        "\tframes     = {",
    ]
    last = len(frames) - 1
    for i, fb in enumerate(frames):
        comma = "," if i < last else ""
        lines.append(f'\t\t"{fb}"{comma}')
    lines.append("\t},")
    lines.append("}")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


# --------------------------------------------------------------------------- #
# Live streaming (real-time HTTP server)
# --------------------------------------------------------------------------- #
# Reads a video in real-time at `fps`, encodes small self-contained chunks
# (each starts with a keyframe so viewers can join mid-stream), and serves
# them via a built-in HTTP server. A rolling window of chunks is kept on
# disk; old chunks are deleted. manifest.json is updated atomically each time
# a new chunk is written.
#
# Roblox side:  renderer:loadLiveStream("http://localhost:PORT/manifest.json")

class _SilentHandler(SimpleHTTPRequestHandler):
    """SimpleHTTPRequestHandler that suppresses logging, adds CORS headers,
    and intercepts /ping to signal the streamer to start."""
    def log_message(self, fmt, *args):
        pass  # quiet

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        super().end_headers()

    def do_GET(self):
        # Intercept /ping and /start — these signal the streamer to begin.
        path = self.path.split("?")[0]
        if path in ("/ping", "/start"):
            # Signal the start event (set on the server instance)
            start_event = getattr(self.server, "start_event", None)
            if start_event is not None:
                start_event.set()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"ok")
            return
        # Otherwise, serve files as normal
        super().do_GET()


def _start_http_server(serve_dir: str, port: int,
                       start_event: threading.Event = None) -> ThreadingHTTPServer:
    def handler(*args, **kw):
        return _SilentHandler(*args, directory=serve_dir, **kw)
    server = ThreadingHTTPServer(("0.0.0.0", port), handler)
    server.start_event = start_event  # handler reads this via self.server
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


def _write_manifest_atomic(manifest: dict, serve_dir: str) -> None:
    path = os.path.join(serve_dir, "manifest.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(manifest, f)
    os.replace(tmp, path)  # atomic on Unix and Windows


def run_live_stream(path: str, serve_dir: str, width: int, height: int,
                    mode: str, fps: float, chunk_frames: int,
                    tolerance: int, buffer_chunks: int, port: int,
                    loop_video: bool, workers: int,
                    wait_for_ping: bool = True) -> None:
    """Read `path` in real-time at `fps`, encode + serve chunks over HTTP.

    If wait_for_ping is True, the HTTP server starts immediately but video
    reading waits until a GET /ping is received (the Roblox server relay
    auto-pings when a client connects)."""
    os.makedirs(serve_dir, exist_ok=True)
    # clean any stale chunks from a previous run
    for f in os.listdir(serve_dir):
        if f.startswith("chunk_") and f.endswith(".bin"):
            try: os.remove(os.path.join(serve_dir, f))
            except: pass

    # Create the start event — the /ping endpoint sets this
    start_event = threading.Event() if wait_for_ping else None
    server = _start_http_server(serve_dir, port, start_event)

    print(f"Live stream server: http://0.0.0.0:{port}/")
    print(f"  manifest: http://localhost:{port}/manifest.json")
    print(f"  {width}x{height} @ {fps} fps, {chunk_frames} frames/chunk "
          f"({chunk_frames/fps*1000:.0f} ms latency)")
    print(f"  rolling buffer: {buffer_chunks} chunks "
          f"({buffer_chunks*chunk_frames/fps:.1f} s)")
    if loop_video:
        print("  loop: ON (restarts video when it ends)")

    executor = ThreadPoolExecutor(max_workers=max(1, workers))
    manifest = {
        "version": SUPPORTED_VERSION,
        "type": "video",
        "live": True,
        "liveEnded": False,
        "width": width,
        "height": height,
        "fps": fps,
        "encoding": "rgba32",
        "compression": "lz4",
        "delta": True,
        "deltaTolerance": tolerance,
        "chunkFrames": chunk_frames,
        "liveHead": -1,      # 0-based index of the latest available frame
        "frameCount": 0,     # grows as frames are streamed
        "chunks": [],
    }
    # Write the initial (empty) manifest BEFORE waiting for ping, so the
    # relay can fetch a valid manifest even before the stream starts.
    _write_manifest_atomic(manifest, serve_dir)

    if wait_for_ping:
        print("\n  >>> WAITING FOR PING <<<")
        print("  The streamer will NOT start until the Roblox game pings it.")
        print("  In Roblox, run your LocalScript — the server relay auto-pings.")
        print(f"  Or manually:  curl http://localhost:{port}/ping")
        print("  Ctrl+C to stop.\n")
        start_event.wait()  # blocks until /ping is hit
        print("  >>> PING RECEIVED — STARTING STREAM <<<\n")
    else:
        print("  Ctrl+C to stop.\n")

    chunk_index = 0
    global_frame = 0   # 0-based, total frames streamed
    frame_interval = 1.0 / fps
    next_time = time.time()

    try:
        while True:
            cap = cv2.VideoCapture(path)
            if not cap.isOpened():
                print(f"ERROR: could not open {path}", file=sys.stderr)
                break

            src_fps = cap.get(cv2.CAP_PROP_FPS) or fps
            src_fps = max(1.0, float(src_fps))
            step = max(1.0, src_fps / fps)
            total_source = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))

            buffer: List[np.ndarray] = []
            prev_last: Optional[np.ndarray] = None  # None => chunk starts with keyframe
            frame_idx = 0.0
            next_grab = 0.0
            grabbed_this_pass = 0

            while True:
                ret, frame = cap.read()
                if not ret:
                    break
                if frame_idx >= next_grab - 1e-6:
                    resized = resize_frame(frame, width, height, mode)
                    rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
                    rgba = np.dstack([rgb, np.full(rgb.shape[:2], 255, dtype=np.uint8)])
                    buffer.append(rgba)

                    if len(buffer) >= chunk_frames:
                        # encode chunk (self-contained: prev_last=None per chunk)
                        tasks = []
                        prev = None  # each chunk starts with a keyframe
                        for curr in buffer:
                            is_key = (prev is None)
                            tasks.append((prev, curr, is_key, tolerance))
                            prev = curr
                        payloads = list(executor.map(encode_one_frame, tasks))
                        chunk_payload = build_chunk_payload(payloads)
                        compressed = lz4_compress_fast(chunk_payload)

                        chunk_file = os.path.join(serve_dir,
                                                  f"chunk_{chunk_index:06d}.bin")
                        with open(chunk_file, "wb") as f:
                            f.write(compressed)

                        chunk_entry = {
                            "index": chunk_index,
                            "frameStart": global_frame,
                            "frameCount": len(buffer),
                            "compressedSize": len(compressed),
                            "uncompressedSize": len(chunk_payload),
                        }
                        manifest["chunks"].append(chunk_entry)
                        manifest["liveHead"] = global_frame + len(buffer) - 1
                        manifest["frameCount"] = global_frame + len(buffer)

                        # prune old chunks (rolling window)
                        while len(manifest["chunks"]) > buffer_chunks:
                            old = manifest["chunks"].pop(0)
                            old_file = os.path.join(serve_dir,
                                                   f"chunk_{old['index']:06d}.bin")
                            try: os.remove(old_file)
                            except: pass

                        _write_manifest_atomic(manifest, serve_dir)

                        global_frame += len(buffer)
                        chunk_index += 1
                        buffer = []

                        sys.stderr.write(
                            f"\r  stream: chunk {chunk_index}, "
                            f"frame {global_frame}, "
                            f"head={manifest['liveHead']}, "
                            f"last chunk {len(compressed)/1024:.0f} KB   ")
                        sys.stderr.flush()

                    next_grab += step
                    grabbed_this_pass += 1

                    # pace to real-time
                    next_time += frame_interval
                    sleep_time = next_time - time.time()
                    if sleep_time > 0:
                        time.sleep(sleep_time)
                    elif sleep_time < -2.0:
                        # fell behind by >2s; resync to avoid runaway lag
                        next_time = time.time()

                frame_idx += 1

            cap.release()

            # flush any partial chunk
            if buffer:
                tasks = []
                prev = None
                for curr in buffer:
                    is_key = (prev is None)
                    tasks.append((prev, curr, is_key, tolerance))
                    prev = curr
                payloads = list(executor.map(encode_one_frame, tasks))
                chunk_payload = build_chunk_payload(payloads)
                compressed = lz4_compress_fast(chunk_payload)
                chunk_file = os.path.join(serve_dir,
                                          f"chunk_{chunk_index:06d}.bin")
                with open(chunk_file, "wb") as f:
                    f.write(compressed)
                manifest["chunks"].append({
                    "index": chunk_index,
                    "frameStart": global_frame,
                    "frameCount": len(buffer),
                    "compressedSize": len(compressed),
                    "uncompressedSize": len(chunk_payload),
                })
                manifest["liveHead"] = global_frame + len(buffer) - 1
                manifest["frameCount"] = global_frame + len(buffer)
                while len(manifest["chunks"]) > buffer_chunks:
                    old = manifest["chunks"].pop(0)
                    try: os.remove(os.path.join(serve_dir,
                                               f"chunk_{old['index']:06d}.bin"))
                    except: pass
                _write_manifest_atomic(manifest, serve_dir)
                global_frame += len(buffer)
                chunk_index += 1
                buffer = []

            if not loop_video:
                break
            print("\n  (looping video)")
            # brief pause before restarting
            time.sleep(0.5)

        # mark stream ended
        manifest["liveEnded"] = True
        _write_manifest_atomic(manifest, serve_dir)
        sys.stderr.write("\n  stream ended. Keeping server alive for late clients. "
                         "Ctrl+C to stop.\n")
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n  stopping...")
    finally:
        executor.shutdown(wait=False)
        server.shutdown()


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="Convert video/image to PixelRenderer v3 chunked data.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("input", help="path to a video or image file")
    p.add_argument("-o", "--output", required=True,
                   help="output dir (v3/live) or file (legacy-lua)")

    p.add_argument("--width", type=int, default=None)
    p.add_argument("--height", type=int, default=None)
    p.add_argument("--preset", choices=list(PRESETS.keys()), default=None,
                   help="display preset (default: p480, or p360 for --live)")

    p.add_argument("--fps", type=float, default=None,
                   help=f"target fps (capped at {MAX_FPS}; default: adaptive, or 40 for --live)")
    p.add_argument("--max-frames", type=int, default=None)
    p.add_argument("--max-seconds", type=float, default=None)

    p.add_argument("--mode", choices=["letterbox", "stretch", "crop"],
                   default="letterbox")

    p.add_argument("--chunk-frames", type=int, default=None,
                   help="frames per chunk (default: 10, or 4 for --live)")
    p.add_argument("--delta-tolerance", type=int, default=DEFAULT_DELTA_TOLERANCE,
                   help="per-channel delta tolerance (0=lossless). "
                        "Compressed video benefits from 4-10.")
    p.add_argument("--lossless", action="store_true",
                   help="shortcut for --delta-tolerance 0")

    p.add_argument("--workers", type=int, default=2,
                   help="thread pool size for encoding (default: 2)")

    p.add_argument("--format", choices=["v3", "legacy-lua"], default="v3",
                   help="output format (default: v3 chunked)")

    # Live streaming options
    p.add_argument("--live", action="store_true",
                   help="live-stream the video in real-time via a built-in HTTP server "
                        "(defaults to 360p @ 40fps)")
    p.add_argument("--port", type=int, default=LIVE_DEFAULT_PORT,
                   help=f"HTTP server port for --live (default: {LIVE_DEFAULT_PORT})")
    p.add_argument("--live-buffer", type=int, default=LIVE_DEFAULT_BUFFER_CHUNKS,
                   help=f"rolling buffer in chunks for --live (default: {LIVE_DEFAULT_BUFFER_CHUNKS})")
    p.add_argument("--live-loop", action="store_true",
                   help="loop the video when it ends (for --live)")
    p.add_argument("--no-wait", action="store_true",
                   help="don't wait for a ping from Roblox before starting "
                        "the stream (default: wait for ping)")
    return p.parse_args()


def resolve_dims_and_fps(args: argparse.Namespace) -> Tuple[int, int, float]:
    # pick preset (live defaults to p360, otherwise p480)
    preset = args.preset
    if preset is None:
        preset = LIVE_DEFAULT_PRESET if args.live else "p480"

    if args.width and args.height:
        w, h = args.width, args.height
    else:
        w, h = PRESETS[preset]

    if w > MAX_WIDTH or h > MAX_HEIGHT:
        print(
            f"ERROR: {w}x{h} exceeds the {MAX_WIDTH}x{MAX_HEIGHT} (720p) limit. "
            f"Use a smaller preset (p240/p360/p480/p720) or lower --width/--height.",
            file=sys.stderr)
        sys.exit(1)

    # pick fps (live defaults to 40, otherwise adaptive)
    if args.fps is not None:
        fps = args.fps
    elif args.live:
        fps = LIVE_DEFAULT_FPS
    else:
        fps = ADAPTIVE_FPS[preset]

    if fps > MAX_FPS:
        print(f"NOTE: requested {fps} fps exceeds the {MAX_FPS} cap; clamping.",
              file=sys.stderr)
        fps = MAX_FPS
    if fps < 1:
        fps = 1
    return w, h, fps


def main() -> int:
    args = parse_args()
    width, height, fps = resolve_dims_and_fps(args)
    tolerance = 0 if args.lossless else args.delta_tolerance

    if not os.path.isfile(args.input):
        print(f"ERROR: input not found: {args.input}", file=sys.stderr)
        return 1

    src_is_video = is_video(args.input)
    src_is_image = (not src_is_video) and is_image(args.input)
    if not (src_is_video or src_is_image):
        print(f"ERROR: could not open {args.input} as video or image",
              file=sys.stderr)
        return 1

    # -- live streaming mode --
    if args.live:
        if not src_is_video:
            print("ERROR: --live requires a video input", file=sys.stderr)
            return 1
        chunk_frames = args.chunk_frames or LIVE_DEFAULT_CHUNK_FRAMES
        print(f"Live streaming {args.input}")
        print(f"  -> {width}x{height} @ {fps} fps, "
              f"delta tolerance {tolerance}, {args.workers} workers")
        run_live_stream(
            args.input, args.output, width, height, args.mode, fps,
            chunk_frames, tolerance, args.live_buffer, args.port,
            args.live_loop, args.workers,
            wait_for_ping=not args.no_wait)
        return 0

    print(f"Converting {args.input}")
    print(f"  -> {width}x{height} @ {fps} fps, "
          f"delta tolerance {tolerance}, {args.workers} workers")

    if args.format == "legacy-lua":
        if not src_is_video:
            print("ERROR: legacy-lua format only supports video", file=sys.stderr)
            return 1
        write_legacy_lua(args.input, args.output, width, height, args.mode,
                         fps, args.max_seconds, args.max_frames)
        size_kb = os.path.getsize(args.output) / 1024
        print(f"Wrote {args.output} ({size_kb:,.1f} KB)")
        return 0

    # v3 chunked
    chunk_frames = args.chunk_frames or DEFAULT_CHUNK_FRAMES
    if src_is_video:
        manifest = write_v3_video(
            args.input, args.output, width, height, args.mode,
            fps, args.max_seconds, args.max_frames,
            chunk_frames, tolerance, args.workers)
    else:
        manifest = write_v3_image(args.input, args.output, width, height, args.mode)

    total_compressed = sum(c["compressedSize"] for c in manifest["chunks"])
    total_uncompressed = sum(c["uncompressedSize"] for c in manifest["chunks"])
    ratio = (total_uncompressed / total_compressed) if total_compressed else 0
    print(f"\nDone.")
    print(f"  frames        : {manifest['frameCount']}")
    print(f"  chunks        : {len(manifest['chunks'])} "
          f"({args.chunk_frames} frames/chunk)")
    print(f"  raw size      : {total_uncompressed/1024:,.0f} KB")
    print(f"  compressed    : {total_compressed/1024:,.0f} KB  "
          f"({ratio:.1f}x)")
    print(f"  avg/frame     : {total_compressed/max(1,manifest['frameCount'])/1024:.1f} KB")
    print(f"  output dir    : {args.output}")
    print(f"  manifest      : {os.path.join(args.output, 'manifest.json')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
