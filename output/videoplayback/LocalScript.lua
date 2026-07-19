local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PixelRenderer = require(ReplicatedStorage:WaitForChild("PixelRenderer"))

local r = PixelRenderer.new({
    pixelSize = Vector2.new(640, 360),
    position = UDim2.fromScale(0.5, 0.5),
    anchorPoint = Vector2.new(0.5, 0.5),
    backend = "auto",
})

local MANIFEST_URL = "https://raw.githubusercontent.com/StillAdum/PixelRenderer/main/output/videoplayback/manifest.json"

local ok, err = pcall(function()
    r:loadFromManifestUrl(MANIFEST_URL)
end)
if not ok then
    warn("[PixelRenderer] failed:", err)
    return
end

r:setLoop(true)
r:play()
