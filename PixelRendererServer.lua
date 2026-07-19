local HttpService     = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService      = game:GetService("RunService")

local PixelRendererServer = {}

local streams = {}

local remote = ReplicatedStorage:FindFirstChild("PixelRendererRelay")
if not remote then
        remote = Instance.new("RemoteFunction")
        remote.Name = "PixelRendererRelay"
        remote.Parent = ReplicatedStorage
end

print("[PixelRendererServer] relay initialized — RemoteFunction 'PixelRendererRelay' is in ReplicatedStorage")
print("[PixelRendererServer] waiting for client requests...")

local function baseUrlOf(url: string): string
        local base = url
        local slash = string.find(base, "/[^/]*$")
        if slash then base = string.sub(base, 1, slash) end
        if string.sub(base, -1) ~= "/" then base = base .. "/" end
        return base
end

local function ackStreamer(state)
        local ackUrl = state.baseUrl .. "ack"
        pcall(function()
                return HttpService:GetAsync(ackUrl, true)
        end)
end

local function downloadChunk(state, index)
        if state.chunks[index] then return state.chunks[index] end
        local curl = state.baseUrl .. ("chunk_%06d.bin"):format(index)

        while state._downloading do
                task.wait(0.05)
        end
        state._downloading = true

        for attempt = 1, 5 do
                local cok, ctext = pcall(function()
                         
                        local response = HttpService:RequestAsync({
                                Url = curl,
                                Method = "GET",
                                Timeout = 30,
                        })
                        if response.Success then
                                return response.Body
                        end
                        error("HTTP " .. response.StatusCode)
                end)
                if cok and type(ctext) == "string" and #ctext > 0 then
                        state.chunks[index] = ctext
                        state._downloading = false
                        return ctext
                end
                 
                if attempt < 5 then
                        task.wait(1 * attempt)
                end
        end

        state._downloading = false

        if not state._warned404 then
                state._warned404 = {}
        end
        if not state._warned404[index] then
                state._warned404[index] = true
                warn(("[PixelRendererServer] chunk %d unavailable after 5 retries")
                        :format(index))
        end
        return nil
end

function PixelRendererServer.startStream(url: string)
        if streams[url] then return streams[url] end

        local state = {
                url        = url,
                baseUrl    = baseUrlOf(url),
                manifest   = nil,
                chunks     = {},         
                liveHead   = -1,
                liveEnded  = false,
                pollThread = nil,
        }
        streams[url] = state

        local ok, text = pcall(function()
                return HttpService:GetAsync(url, true)
        end)
        if not ok then
                warn(("[PixelRendererServer] manifest fetch failed: %s"):format(tostring(text)))
                return state
        end

        local pok, m = pcall(function()
                return HttpService:JSONDecode(text)
        end)
        if not pok or type(m) ~= "table" then
                warn("[PixelRendererServer] manifest JSON decode failed")
                return state
        end

        state.manifest = m
        state.liveHead = m.liveHead or (m.frameCount and m.frameCount - 1) or -1
        state.liveEnded = m.liveEnded or false

        print(("[PixelRendererServer] manifest loaded: %dx%d @ %dfps, %d chunks, live=%s")
                :format(m.width or 0, m.height or 0, m.fps or 0, #m.chunks,
                        tostring(m.live or false)))

        state.pollThread = task.spawn(function()
                if not m.live then
                        return   
                else
                         
                        while true do
                                local ok2, text2 = pcall(function()
                                        return HttpService:GetAsync(url, true)
                                end)
                                if ok2 then
                                        local pok2, m2 = pcall(function()
                                                return HttpService:JSONDecode(text2)
                                        end)
                                        if pok2 and m2 and m2.chunks then
                                                state.manifest = m2
                                                state.liveHead = m2.liveHead or state.liveHead
                                                state.liveEnded = m2.liveEnded or false

                                                for _, c in ipairs(m2.chunks) do
                                                        if not state.chunks[c.index] then
                                                                downloadChunk(state, c.index)
                                                        end
                                                end

                                                if not state.liveEnded then
                                                        ackStreamer(state)
                                                end

                                                local valid = {}
                                                for _, c in ipairs(m2.chunks) do
                                                        valid[c.index] = true
                                                end
                                                for idx in pairs(state.chunks) do
                                                        if not valid[idx] then
                                                                state.chunks[idx] = nil
                                                        end
                                                end
                                        end
                                end
                                task.wait(0.2)
                        end
                end
        end)

        return state
end

function PixelRendererServer.getManifest(url: string)
        local state = streams[url] or PixelRendererServer.startStream(url)
        return state.manifest
end

function PixelRendererServer.getChunk(url: string, index: number)
        local state = streams[url] or PixelRendererServer.startStream(url)
        return state.chunks[index] or downloadChunk(state, index)
end

remote.OnServerInvoke = function(player: Player, action: string, url: string, arg: any)
        if type(action) ~= "string" or type(url) ~= "string" then
                return nil
        end

        local ok, state = pcall(function()
                return streams[url] or PixelRendererServer.startStream(url)
        end)
        if not ok or not state then
                return nil
        end

        if action == "manifest" then
                return state.manifest
        elseif action == "chunk" then
                 
                return state.chunks[arg] or downloadChunk(state, arg)
        elseif action == "head" then
                return state.liveHead, state.liveEnded
        end
        return nil
end

return PixelRendererServer
