local ServerScriptService = game:GetService("ServerScriptService")

local PixelRendererServer = require(ServerScriptService:WaitForChild("PixelRendererServer"))

print("[PixelRendererServer] relay ready. Clients can now use loadLiveStream/loadFromManifestUrl.")
