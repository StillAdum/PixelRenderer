#!/usr/bin/env python3
"""
generate_localscript.py — Generates a ready-to-use Roblox LocalScript that
plays a PixelRenderer video hosted on GitHub raw.

USAGE
-----
    python3 generate_localscript.py \
        --repo "user/repo" \
        --branch "main" \
        --video-name "myclip" \
        --output "LocalScript.lua"

The generated LocalScript points at:
    https://raw.githubusercontent.com/<repo>/<branch>/output/<video-name>/manifest.json
"""

import argparse
import os


def generate(repo: str, branch: str, video_name: str) -> str:
    raw_base = f"https://raw.githubusercontent.com/{repo}/{branch}/output/{video_name}"

    return f'''local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PixelRenderer = require(ReplicatedStorage:WaitForChild("PixelRenderer"))

local r = PixelRenderer.new({{
    pixelSize = Vector2.new(640, 360),
    position = UDim2.fromScale(0.5, 0.5),
    anchorPoint = Vector2.new(0.5, 0.5),
    backend = "auto",
}})

local MANIFEST_URL = "{raw_base}/manifest.json"

local ok, err = pcall(function()
    r:loadFromManifestUrl(MANIFEST_URL)
end)
if not ok then
    warn("[PixelRenderer] failed:", err)
    return
end

r:setLoop(true)
r:play()
'''


def main():
    p = argparse.ArgumentParser(description="Generate a PixelRenderer LocalScript")
    p.add_argument("--repo", required=True, help="GitHub repo (user/repo)")
    p.add_argument("--branch", required=True, help="Branch name (e.g. main)")
    p.add_argument("--video-name", required=True, help="Video name (folder in output/)")
    p.add_argument("--output", required=True, help="Output LocalScript path")
    args = p.parse_args()

    script = generate(args.repo, args.branch, args.video_name)
    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    with open(args.output, "w") as f:
        f.write(script)
    print(f"Generated: {args.output}")
    print(f"  Manifest URL: https://raw.githubusercontent.com/{args.repo}/{args.branch}/output/{args.video_name}/manifest.json")


if __name__ == "__main__":
    main()
