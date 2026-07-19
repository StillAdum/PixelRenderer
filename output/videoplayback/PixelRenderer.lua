local HttpService = game:GetService("HttpService")
local RunService  = game:GetService("RunService")
local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PixelRenderer = {}
PixelRenderer.__index = PixelRenderer

PixelRenderer.SUPPORTED_VERSION = 3
PixelRenderer.DEFAULT_FPS = 30
local MAX_EDITABLE_DIM = 1024

local IS_SERVER = RunService:IsServer()

local function getRelay()
        return ReplicatedStorage:FindFirstChild("PixelRendererRelay")
end

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_DECODE = table.create(256)
for i = 1, #B64_ALPHABET do
        B64_DECODE[string.byte(B64_ALPHABET, i)] = i - 1
end

local function base64ToBuffer(str: string): buffer
        str = string.gsub(str, "%s", "")
        str = string.gsub(str, "=", "")
        local len = #str
        if len == 0 then return buffer.create(0) end
        local outLen = math.floor(len * 3 / 4)
        local buf = buffer.create(outLen)
        local bi, i = 0, 1
        while i <= len - 3 do
                local c1, c2, c3, c4 = string.byte(str, i, i + 3)
                local n = (B64_DECODE[c1] or 0) * 262144 + (B64_DECODE[c2] or 0) * 4096
                        + (B64_DECODE[c3] or 0) * 64 + (B64_DECODE[c4] or 0)
                buffer.writeu8(buf, bi,     math.floor(n / 65536) % 256)
                buffer.writeu8(buf, bi + 1, math.floor(n / 256)   % 256)
                buffer.writeu8(buf, bi + 2, n % 256)
                bi += 3
                i += 4
        end
        local rem = len - i + 1
        if rem == 2 then
                local c1, c2 = string.byte(str, i, i + 1)
                local n = (B64_DECODE[c1] or 0) * 4 + math.floor((B64_DECODE[c2] or 0) / 16)
                buffer.writeu8(buf, bi, n)
        elseif rem == 3 then
                local c1, c2, c3 = string.byte(str, i, i + 2)
                local n = (B64_DECODE[c1] or 0) * 1024 + (B64_DECODE[c2] or 0) * 16
                        + math.floor((B64_DECODE[c3] or 0) / 4)
                buffer.writeu8(buf, bi,     math.floor(n / 256))
                buffer.writeu8(buf, bi + 1, n % 256)
        end
        return buf
end

local function lz4Decode(input: buffer, outputLen: number): buffer
        local output = buffer.create(outputLen)
        local inLen = buffer.len(input)
        local ip = 0
        local op = 0

        while ip < inLen do
                local token = buffer.readu8(input, ip)
                ip += 1

                local litLen = bit32.rshift(token, 4)
                if litLen == 15 then
                        repeat
                                local b = buffer.readu8(input, ip)
                                ip += 1
                                litLen += b
                        until b ~= 255
                end

                if litLen > 0 then
                        buffer.copy(output, op, input, ip, litLen)
                        op += litLen
                        ip += litLen
                end

                if ip >= inLen then
                        break
                end

                local offset = buffer.readu16(input, ip)
                ip += 2

                local matchLen = bit32.band(token, 0x0F)
                if matchLen == 15 then
                        repeat
                                local b = buffer.readu8(input, ip)
                                ip += 1
                                matchLen += b
                        until b ~= 255
                end
                matchLen += 4

                if offset < matchLen then
                        local src = op - offset
                        for _ = 1, matchLen do
                                buffer.writeu8(output, op, buffer.readu8(output, src))
                                op += 1
                                src += 1
                        end
                else
                        buffer.copy(output, op, output, op - offset, matchLen)
                        op += matchLen
                end
        end

        return output
end

local function computeTileGrid(width: number, height: number)
        local cols = math.max(1, math.ceil(width  / MAX_EDITABLE_DIM))
        local rows = math.max(1, math.ceil(height / MAX_EDITABLE_DIM))
        local tileW = math.ceil(width  / cols)
        local tileH = math.ceil(height / rows)
        local tiles = {}
        for row = 0, rows - 1 do
                for col = 0, cols - 1 do
                        local srcX = col * tileW
                        local srcY = row * tileH
                        local tw = math.min(tileW, width  - srcX)
                        local th = math.min(tileH, height - srcY)
                        table.insert(tiles, {
                                srcX = srcX, srcY = srcY,
                                width = tw, height = th,
                                col = col, row = row,
                        })
                end
        end
        return tiles
end

local _bindingErrors = {}   
local _bindingMethod = ""   
local function bindEditableImage(label: ImageLabel, ei): boolean
        table.clear(_bindingErrors)

        local ok, err = pcall(function()
                label.ImageContent = Content.fromObject(ei)
        end)
        if ok then _bindingMethod = "ImageContent = Content.fromObject"; return true end
        table.insert(_bindingErrors, "ImageContent: " .. tostring(err))

        ok, err = pcall(function()
                label.Image = Content.fromObject(ei)
        end)
        if ok then _bindingMethod = "Image = Content.fromObject"; return true end
        table.insert(_bindingErrors, "Image=Content.fromObject: " .. tostring(err))

        ok, err = pcall(function()
                label.ImageContent = ei
        end)
        if ok then _bindingMethod = "ImageContent = ei"; return true end
        table.insert(_bindingErrors, "ImageContent=ei: " .. tostring(err))

        ok, err = pcall(function()
                label.Image = ei
        end)
        if ok then _bindingMethod = "Image = ei"; return true end
        table.insert(_bindingErrors, "Image=ei: " .. tostring(err))

        return false
end

local function getBindingErrors(): string
        return table.concat(_bindingErrors, " | ")
end

local function buildTilesEditableImage(container: Frame, width: number, height: number): { any }?
        local tiles = computeTileGrid(width, height)
        local anyBound = false

        for _, tile in ipairs(tiles) do
                local ei
                local ok = pcall(function()
                        ei = AssetService:CreateEditableImage({
                                Size = Vector2.new(tile.width, tile.height),
                        })
                end)
                if not ok or not ei then
                         
                        for _, t in ipairs(tiles) do
                                if t.editableImage then t.editableImage:Destroy() end
                                if t.imageLabel  then t.imageLabel:Destroy()  end
                        end
                        return nil
                end
                tile.editableImage = ei
                tile.size = Vector2.new(tile.width, tile.height)
                if #tiles > 1 then
                        tile.buffer = buffer.create(tile.width * tile.height * 4)
                end

                local label = Instance.new("ImageLabel")
                label.Name = ("Tile_%d_%d"):format(tile.col, tile.row)
                label.ScaleType = Enum.ScaleType.Stretch
                label.BorderSizePixel = 0
                label.BackgroundColor3 = Color3.new(0, 0, 0)
                label.AnchorPoint = Vector2.new(0, 0)
                label.Position = UDim2.fromScale(tile.srcX / width, tile.srcY / height)
                label.Size = UDim2.fromScale(tile.width / width, tile.height / height)
                label.Parent = container
                tile.imageLabel = label

                if bindEditableImage(label, ei) then
                        anyBound = true
                end
        end

        if not anyBound then
                 
                for _, t in ipairs(tiles) do
                        if t.editableImage then t.editableImage:Destroy() end
                        if t.imageLabel  then t.imageLabel:Destroy()  end
                end
                return nil
        end
        return tiles
end

local function buildFramePixels(container: Frame, width: number, height: number): { Frame }
        local total = width * height
        local pixels = table.create(total)
        local cellW = 1 / width
        local cellH = 1 / height
        for y = 0, height - 1 do
                for x = 0, width - 1 do
                        local px = Instance.new("Frame")
                        px.Name = ("P_%d_%d"):format(x, y)
                        px.Size = UDim2.fromScale(cellW, cellH)
                        px.Position = UDim2.fromScale(x * cellW, y * cellH)
                        px.AnchorPoint = Vector2.new(0, 0)
                        px.BorderSizePixel = 0
                        px.BackgroundColor3 = Color3.new(0, 0, 0)
                        px.Parent = container
                        pixels[y * width + x + 1] = px
                end
        end
        return pixels
end

local function paintTilesEditableImage(tiles: { any }, width: number, rgba: buffer)
        if #tiles == 1 then
                local t = tiles[1]
                local ok, err = pcall(function()
                        t.editableImage:WritePixelsBuffer(Vector2.zero, t.size, rgba)
                end)
                if not ok then
                        warn(("[PixelRenderer] WritePixelsBuffer failed: %s"):format(tostring(err)))
                end
        else
                for _, t in ipairs(tiles) do
                        local tw, th = t.width, t.height
                        local tb = t.buffer
                        for row = 0, th - 1 do
                                local srcOff = ((t.srcY + row) * width + t.srcX) * 4
                                local dstOff = row * tw * 4
                                buffer.copy(tb, dstOff, rgba, srcOff, tw * 4)
                        end
                        local ok, err = pcall(function()
                                t.editableImage:WritePixelsBuffer(Vector2.zero, t.size, tb)
                        end)
                        if not ok then
                                warn(("[PixelRenderer] WritePixelsBuffer (tile %d,%d) failed: %s")
                                        :format(t.col, t.row, tostring(err)))
                        end
                end
        end
end

local function paintFramePixels(pixels: { Frame }, width: number, height: number,
                rgba: buffer, prevRgba: buffer?)
        local total = width * height
        if prevRgba and buffer.len(prevRgba) == buffer.len(rgba) then
                 
                local bi = 0
                for i = 1, total do
                        local cur = buffer.readu32(rgba, bi)
                        local old = buffer.readu32(prevRgba, bi)
                        if cur ~= old then
                                 
                                local r = bit32.band(cur, 0xFF)
                                local g = bit32.band(bit32.rshift(cur, 8), 0xFF)
                                local b = bit32.band(bit32.rshift(cur, 16), 0xFF)
                                pixels[i].BackgroundColor3 = Color3.fromRGB(r, g, b)
                        end
                        bi += 4
                end
        else
                 
                local bi = 0
                for i = 1, total do
                        local r = buffer.readu8(rgba, bi)
                        local g = buffer.readu8(rgba, bi + 1)
                        local b = buffer.readu8(rgba, bi + 2)
                        pixels[i].BackgroundColor3 = Color3.fromRGB(r, g, b)
                        bi += 4
                end
        end
end

function PixelRenderer.new(config: table?)
        config = config or {}
        local parent = config.parent
        if not parent then
                local player = game:GetService("Players").LocalPlayer
                if player then parent = player:WaitForChild("PlayerGui") end
        end
        assert(parent, "[PixelRenderer] could not resolve a parent for the ScreenGui")

        local screenGui = Instance.new("ScreenGui")
        screenGui.Name = config.guiName or "PixelRendererGui"
        screenGui.ResetOnSpawn = false
        screenGui.IgnoreGuiInset = config.ignoreGuiInset ~= false
        screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
        screenGui.Parent = parent

        local container = Instance.new("Frame")
        container.Name = "PixelContainer"
        container.AnchorPoint = config.anchorPoint or Vector2.new(0.5, 0.5)
        container.Position = config.position or UDim2.fromScale(0.5, 0.5)
        container.Size = UDim2.fromOffset(
                (config.pixelSize and config.pixelSize.X) or 640,
                (config.pixelSize and config.pixelSize.Y) or 360)
        container.BackgroundColor3 = config.backgroundColor or Color3.new(0, 0, 0)
        container.BorderSizePixel = 0
        container.ClipsDescendants = true
        container.Parent = screenGui

        local aspect = Instance.new("UIAspectRatioConstraint")
        aspect.AspectRatio = 16 / 9
        aspect.Parent = container

        local baseSize = Vector2.new(
                (config.pixelSize and config.pixelSize.X) or 640,
                (config.pixelSize and config.pixelSize.Y) or 360)

        local self = setmetatable({
                _gui          = screenGui,
                _container    = container,
                _aspect       = aspect,
                _tiles        = nil,           
                _framePixels  = nil,           
                _prevPaintBuf = nil,           
                _backend      = config.backend or "auto",   
                _width        = 0,
                _height       = 0,
                _fps          = PixelRenderer.DEFAULT_FPS,
                _frameCount   = 0,
                _currentFrame = 0,
                 
                _manifest     = nil,
                _chunkFrames  = 10,
                _chunks       = nil,         
                _baseUrl      = nil,         
                _streamUrl    = nil,         
                 
                _chunkCache   = {},
                _chunkCacheLimit = 3,
                _currentChunk = -1,
                 
                _legacyFrames = nil,         
                _legacyCache  = {},
                _legacyCacheLimit = 32,
                 
                _playing      = false,
                _looping      = false,
                _connection   = nil,
                _startTime    = 0,
                _destroyed    = false,
                _onEnded      = nil,
                _baseSize     = baseSize,
                _prefetchThread = nil,
                _dlThread     = nil,
                 
                _prevDecoded  = nil,
                 
                _onError      = nil,
                 
                _live         = false,
                _liveHead     = -1,
                _liveEnded    = false,
                _pollThread   = nil,
                _liveStartFrame = 0,   
        }, PixelRenderer)
        return self
end

local function paintTiles(tiles: { any }, width: number, rgba: buffer)
        if #tiles == 1 then
                local t = tiles[1]
                t.editableImage:WritePixelsBuffer(Vector2.zero, t.size, rgba)
        else
                for _, t in ipairs(tiles) do
                        local tw, th = t.width, t.height
                        local tb = t.buffer
                        for row = 0, th - 1 do
                                local srcOff = ((t.srcY + row) * width + t.srcX) * 4
                                local dstOff = row * tw * 4
                                buffer.copy(tb, dstOff, rgba, srcOff, tw * 4)
                        end
                        t.editableImage:WritePixelsBuffer(Vector2.zero, t.size, tb)
                end
        end
end

local function decodeFrameFromChunk(chunkBuf: buffer, localFrameIndex: number,
                width: number, height: number, prevBuf: buffer?): buffer
        local pixelBytes = width * height * 4
         
        local ip = 0
        local frameStart = 0
        local currentFrame = 0
         
        while currentFrame <= localFrameIndex do
                 
                if ip + 4 > buffer.len(chunkBuf) then break end
                local payloadLen = buffer.readu32(chunkBuf, ip)
                ip += 4
                local payloadStart = ip
                if currentFrame == localFrameIndex then
                        local frameType = buffer.readu8(chunkBuf, ip)
                        ip += 1
                        if frameType == 0 then
                                 
                                local out = buffer.create(pixelBytes)
                                buffer.copy(out, 0, chunkBuf, ip, pixelBytes)
                                return out
                        else
                                 
                                local base = prevBuf
                                if not base then
                                         
                                        return buffer.create(pixelBytes)
                                end
                                local out = buffer.create(pixelBytes)
                                buffer.copy(out, 0, base, 0, pixelBytes)
                                local numSeg = buffer.readu32(chunkBuf, ip)
                                ip += 4
                                local pixPos = 0   
                                for _ = 1, numSeg do
                                        local skip = buffer.readu32(chunkBuf, ip); ip += 4
                                        local run  = buffer.readu32(chunkBuf, ip); ip += 4
                                        pixPos += skip
                                        if run > 0 then
                                                local byteCount = run * 4
                                                buffer.copy(out, pixPos * 4, chunkBuf, ip, byteCount)
                                                ip += byteCount
                                                pixPos += run
                                        end
                                end
                                return out
                        end
                end
                 
                ip = payloadStart + payloadLen
                currentFrame += 1
        end
         
        return buffer.create(pixelBytes)
end

function PixelRenderer:_findChunkForFrame(frameIndex: number)
        local f0 = frameIndex - 1   
        for _, c in ipairs(self._chunks) do
                if f0 >= c.frameStart and f0 < c.frameStart + c.frameCount then
                        return c, f0 - c.frameStart
                end
        end
        return nil, nil
end

function PixelRenderer:_getDecompressedChunk(chunkMeta): buffer?
        if not chunkMeta then return nil end
        local idx = chunkMeta.index
        local entry = self._chunkCache[idx]
        if entry and entry.decompressed then
                return entry.decompressed
        end

        local compressed
        if entry and entry.compressed then
                compressed = entry.compressed
        elseif self._chunkBuffers and self._chunkBuffers[idx] then
                compressed = self._chunkBuffers[idx]
        else
                return nil   
        end

        local decomp = lz4Decode(compressed, chunkMeta.uncompressedSize)
        if not entry then
                entry = {}
                self._chunkCache[idx] = entry
        end
        entry.decompressed = decomp
        entry.compressed = nil   
        return decomp
end

function PixelRenderer:_evictChunks(keepIndex: number)
        local count = 0
        for _ in pairs(self._chunkCache) do count += 1 end
        while count > self._chunkCacheLimit do
                local farthest, farthestDist = nil, -1
                for idx in pairs(self._chunkCache) do
                        local d = math.abs(idx - keepIndex)
                        if d > farthestDist then
                                farthestDist = d
                                farthest = idx
                        end
                end
                if farthest == nil then break end
                self._chunkCache[farthest] = nil
                count -= 1
        end
end

function PixelRenderer:renderFrame(frameIndex: number)
        if self._destroyed then return end
        if not self._tiles and not self._framePixels then return end

        if self._legacyFrames then
                return self:_renderFrameLegacy(frameIndex)
        end

        local manifest = self._manifest
        if not manifest then return end

        if frameIndex < 1 then frameIndex = 1 end
        if not self._live and frameIndex > self._frameCount then
                frameIndex = self._frameCount
        end

        local chunkMeta, localIndex = self:_findChunkForFrame(frameIndex)
        if not chunkMeta then return end

        local decomp = self:_getDecompressedChunk(chunkMeta)
        if not decomp then
                 
                return
        end

        local chunkIdx = chunkMeta.index
        if not self._decodedFrames then self._decodedFrames = {} end
        if not self._decodedFrames[chunkIdx] then
                self._decodedFrames[chunkIdx] = {}
        end
        local cached = self._decodedFrames[chunkIdx][localIndex]
        local rgba
        if cached then
                rgba = cached
        else
                 
                local prevBuf
                if localIndex > 0 then
                        prevBuf = self:_decodeChunkFrame(chunkMeta, localIndex - 1)
                else
                        prevBuf = self._live and nil or self._prevDecoded
                end
                rgba = decodeFrameFromChunk(decomp, localIndex,
                        self._width, self._height, prevBuf)
                self._decodedFrames[chunkIdx][localIndex] = rgba
        end

        self:_paint(rgba)

        if not self._live and (localIndex == self._chunkFrames - 1
                or frameIndex == self._frameCount) then
                self._prevDecoded = rgba
        end

        self._currentFrame = frameIndex
end

function PixelRenderer:_decodeChunkFrame(chunkMeta, localIndex: number): buffer?
        if not self._decodedFrames then self._decodedFrames = {} end
        local chunkIdx = chunkMeta.index
        if not self._decodedFrames[chunkIdx] then
                self._decodedFrames[chunkIdx] = {}
        end

        local cached = self._decodedFrames[chunkIdx][localIndex]
        if cached then return cached end

        local decomp = self:_getDecompressedChunk(chunkMeta)
        if not decomp then return nil end

        local prevBuf
        if localIndex > 0 then
                prevBuf = self:_decodeChunkFrame(chunkMeta, localIndex - 1)
        else
                prevBuf = self._live and nil or self._prevDecoded
        end

        local rgba = decodeFrameFromChunk(decomp, localIndex,
                self._width, self._height, prevBuf)
        self._decodedFrames[chunkIdx][localIndex] = rgba
        return rgba
end

function PixelRenderer:_getLegacyFrameBuffer(frameIndex: number): buffer?
        local cached = self._legacyCache[frameIndex]
        if cached then return cached end
        local str = self._legacyFrames[frameIndex]
        if not str then return nil end
        local buf = base64ToBuffer(str)
        local count = 0
        for _ in pairs(self._legacyCache) do count += 1 end
        if count >= self._legacyCacheLimit then
                local oldest = math.huge
                for idx in pairs(self._legacyCache) do
                        if idx ~= frameIndex and idx < oldest then oldest = idx end
                end
                if oldest ~= math.huge then self._legacyCache[oldest] = nil end
        end
        self._legacyCache[frameIndex] = buf
        return buf
end

function PixelRenderer:_renderFrameLegacy(frameIndex: number)
        local buf = self:_getLegacyFrameBuffer(frameIndex)
        if not buf then return end
        self:_paint(buf)
        self._currentFrame = frameIndex
end

function PixelRenderer:_paint(rgba: buffer)
        if self._backend == "frames" then
                if not self._framePixels then return end
                 
                if not self._prevPaintBuf and buffer.len(rgba) >= 4 then
                        local r = buffer.readu8(rgba, 0)
                        local g = buffer.readu8(rgba, 1)
                        local b = buffer.readu8(rgba, 2)
                        print(("[PixelRenderer] first paint: %dx%d, %d pixels, "
                                .. "first pixel RGB=(%d,%d,%d), bufLen=%d")
                                :format(self._width, self._height,
                                        #self._framePixels, r, g, b, buffer.len(rgba)))
                end
                paintFramePixels(self._framePixels, self._width, self._height,
                        rgba, self._prevPaintBuf)
                self._prevPaintBuf = rgba
        else
                if not self._tiles then return end
                paintTilesEditableImage(self._tiles, self._width, rgba)
        end
end

function PixelRenderer:_setupSurface(width: number, height: number, fps: number, frameCount: number)
         
        if self._tiles then
                for _, t in ipairs(self._tiles) do
                        if t.editableImage then t.editableImage:Destroy() end
                        if t.imageLabel  then t.imageLabel:Destroy()  end
                end
                self._tiles = nil
        end
        if self._framePixels then
                for _, p in ipairs(self._framePixels) do
                        p:Destroy()
                end
                self._framePixels = nil
        end
        self._prevPaintBuf = nil
        table.clear(self._chunkCache)
        table.clear(self._legacyCache)
        self._decodedFrames = {}   
        self._prevDecoded = nil
         
        self._live = false
        self._liveHead = -1
        self._liveEnded = false

        self._width = width
        self._height = height
        self._fps = fps
        self._frameCount = frameCount
        self._currentFrame = 0

        if self._aspect then
                self._aspect.AspectRatio = width / height
        end

        local backend = self._backend
        if backend == "auto" then
                 
                local probeOk = pcall(function()
                        local testEi = AssetService:CreateEditableImage({ Size = Vector2.new(2, 2) })
                        print(("[PixelRenderer] EditableImage type: %s"):format(typeof(testEi)))

                        local membersOk, members = pcall(function()
                                local list = {}
                                for k, v in pairs(testEi) do
                                        table.insert(list, tostring(k) .. "(" .. type(v) .. ")")
                                end
                                return list
                        end)
                        if membersOk and #members > 0 then
                                print("[PixelRenderer] EditableImage members: " .. table.concat(members, ", "))
                        end

                        local isInstance = pcall(function() return testEi.IsA end) and type(testEi.IsA) == "function"
                        print(("[PixelRenderer] EditableImage isInstance: %s"):format(tostring(isInstance)))

                        local tsOk, tsVal = pcall(function() return tostring(testEi) end)
                        if tsOk then
                                print(("[PixelRenderer] EditableImage tostring: %s"):format(tsVal))
                        end

                        local testLabel = Instance.new("ImageLabel")
                        local bound = bindEditableImage(testLabel, testEi)
                        if bound then
                                print(("[PixelRenderer] EditableImage bound via: %s"):format(_bindingMethod))
                        end
                        if not bound then
                                error("binding failed")
                        end
                        testLabel:Destroy()
                        testEi:Destroy()
                end)
                backend = probeOk and "editableImage" or "frames"
                if backend == "frames" then
                        local errs = getBindingErrors()
                        print("[PixelRenderer] EditableImage binding failed. Errors: " .. errs)
                        print("[PixelRenderer] Falling back to frames backend.")
                end
        end
        self._backend = backend

        if backend == "editableImage" then
                self._tiles = buildTilesEditableImage(self._container, width, height)
                if not self._tiles then
                         
                        warn("[PixelRenderer] EditableImage binding failed; falling back to frames backend. "
                                .. "")
                        self._backend = "frames"
                        self._framePixels = buildFramePixels(self._container, width, height)
                end
        else
                self._framePixels = buildFramePixels(self._container, width, height)
        end
end

function PixelRenderer:loadData(manifest: table, chunks: table?)
        assert(type(manifest) == "table", "[PixelRenderer] manifest must be a table")
        assert(manifest.version == 3, "[PixelRenderer] loadData expects v3 manifest; use loadDataLegacy for v2")

        self._setupSurface(manifest.width, manifest.height,
                manifest.fps or self.DEFAULT_FPS,
                manifest.frameCount or 0)

        self._manifest = manifest
        self._chunks = manifest.chunks
        self._chunkFrames = manifest.chunkFrames or 10
        self._legacyFrames = nil
        self._baseUrl = nil

        self._chunkBuffers = {}
        if chunks then
                for k, v in pairs(chunks) do
                        local idx = (type(k) == "number") and (k < 1 and 0 or k - 1) or tonumber(k) or 0
                        if idx < 1 and k == 1 then idx = 0 end
                        if type(v) == "string" then
                                v = buffer.fromstring(v)
                        end
                        self._chunkBuffers[idx] = v
                end
        end

        if self._frameCount > 0 then
                self:renderFrame(1)
                self._currentFrame = 1
        end
        return self
end

function PixelRenderer:_fetchManifest(url: string): table?
        if IS_SERVER then
                local ok, text = pcall(function() return HttpService:GetAsync(url, true) end)
                if not ok then
                        warn(("[PixelRenderer] (server) manifest GET failed: %s"):format(tostring(text)))
                        return nil
                end
                local pok, m = pcall(function() return HttpService:JSONDecode(text) end)
                if pok and type(m) == "table" then return m end
                warn(("[PixelRenderer] (server) manifest JSON decode failed: %s"):format(tostring(m)))
                return nil
        else
                local relay = getRelay()
                if not relay then
                        warn("[PixelRenderer] server relay RemoteFunction not found in ReplicatedStorage. "
                                .. "Ensure PixelRendererServer is in ServerScriptService and required.")
                        return nil
                end
                local ok, result = pcall(function() return relay:InvokeServer("manifest", url) end)
                if not ok then
                        warn(("[PixelRenderer] relay InvokeServer failed: %s"):format(tostring(result)))
                        return nil
                end
                if type(result) ~= "table" then
                        warn(("[PixelRenderer] relay returned non-table manifest: %s (type=%s)")
                                :format(tostring(result), type(result)))
                        return nil
                end
                return result
        end
end

function PixelRenderer:_fetchChunk(url: string, chunkIndex: number): buffer?
        if IS_SERVER then
                local baseUrl = self._baseUrl
                if not baseUrl then return nil end
                local curl = baseUrl .. ("chunk_%06d.bin"):format(chunkIndex)
                local ok, text = pcall(function() return HttpService:GetAsync(curl, true) end)
                if not ok then return nil end
                return buffer.fromstring(text)
        else
                local relay = getRelay()
                if not relay then return nil end
                local ok, text = pcall(function() return relay:InvokeServer("chunk", url, chunkIndex) end)
                if not ok or type(text) ~= "string" then return nil end
                 
                return buffer.fromstring(text)
        end
end

function PixelRenderer:_fetchLiveHead(url: string): (number, boolean)
        if IS_SERVER then
                 
                return self._liveHead, self._liveEnded
        else
                local relay = getRelay()
                if not relay then return self._liveHead, self._liveEnded end
                local ok, head, ended = pcall(function() return relay:InvokeServer("head", url) end)
                if ok and type(head) == "number" then
                        return head, ended or false
                end
                return self._liveHead, self._liveEnded
        end
end

function PixelRenderer:loadFromManifestUrl(url: string, cacheKey: string?)
        assert(type(url) == "string" and #url > 0,
                "[PixelRenderer] loadFromManifestUrl expects a non-empty url")

        self._streamUrl = url   

        local baseUrl = url
        local slash = string.find(baseUrl, "/[^/]*$")
        if slash then baseUrl = string.sub(baseUrl, 1, slash) end
        if string.sub(baseUrl, -1) ~= "/" then baseUrl = baseUrl .. "/" end
        self._baseUrl = baseUrl

        local manifest = self:_fetchManifest(url)
        if not manifest then
                error(("[PixelRenderer] manifest fetch failed for %s"):format(url), 0)
        end

        self:_setupSurface(manifest.width, manifest.height,
                manifest.fps or self.DEFAULT_FPS,
                manifest.frameCount or 0)
        self._manifest = manifest
        self._chunks = manifest.chunks
        self._chunkFrames = manifest.chunkFrames or 10
        self._legacyFrames = nil
        self._chunkBuffers = {}

        self:_downloadChunk(0)
        if self._frameCount > 0 then
                self:renderFrame(1)
                self._currentFrame = 1
        end
        return self
end

function PixelRenderer:loadLiveStream(url: string)
        assert(type(url) == "string" and #url > 0,
                "[PixelRenderer] loadLiveStream expects a non-empty url")

        self._streamUrl = url   

        local baseUrl = url
        local slash = string.find(baseUrl, "/[^/]*$")
        if slash then baseUrl = string.sub(baseUrl, 1, slash) end
        if string.sub(baseUrl, -1) ~= "/" then baseUrl = baseUrl .. "/" end
        self._baseUrl = baseUrl

        local manifest = nil
        for attempt = 1, 5 do
                manifest = self:_fetchManifest(url)
                if manifest then break end
                print(("[PixelRenderer] manifest fetch attempt %d/5 failed, retrying in 1s...")
                        :format(attempt))
                task.wait(1)
        end
        if not manifest then
                error(("[PixelRenderer] live manifest fetch failed for %s after 5 retries. "
                        .. "Check: (1) is the live streamer running? "
                        .. "(2) is PixelRendererServer in ServerScriptService and required? "
                        .. "(3) is the port correct (default 8080)? "
                        .. "(4) is 'Allow HTTP Requests' enabled in Game Settings?")
                        :format(url), 0)
        end

        self:_setupSurface(manifest.width, manifest.height,
                manifest.fps or self.DEFAULT_FPS, 0)
        self._manifest = manifest
        self._chunks = manifest.chunks or {}
        self._chunkFrames = manifest.chunkFrames or 4
        self._legacyFrames = nil
        self._chunkBuffers = {}
        self._live = true
        self._liveHead = manifest.liveHead or -1
        self._liveEnded = manifest.liveEnded or false

        print(("[PixelRenderer] live stream loaded: %dx%d @ %dfps, backend=%s, "
                .. "%d chunks available, liveHead=%d")
                :format(manifest.width, manifest.height, manifest.fps or 0,
                        self._backend, #self._chunks, self._liveHead))

        self:_startLivePolling(url)

        if #self._chunks > 0 then
                 
                local edgeIdx = #self._chunks        
                local startIdx = math.max(1, edgeIdx - 2)
                local firstChunk = self._chunks[startIdx]
                local startFrame = firstChunk.frameStart + 1   
                self._liveStartFrame = startFrame
                self._currentFrame = startFrame - 1

                print(("[PixelRenderer] joining at live edge: chunk %d (frame %d), "
                        .. "edge chunk %d (frame %d)")
                        :format(firstChunk.index, startFrame,
                                self._chunks[edgeIdx].index,
                                self._chunks[edgeIdx].frameStart + 1))

                local downloaded = false
                for attempt = 1, 5 do
                        if self:_downloadChunk(firstChunk.index) then
                                downloaded = true
                                break
                        end
                        task.wait(0.5)
                end

                if downloaded then
                        self:renderFrame(startFrame)
                        print(("[PixelRenderer] first frame rendered (frame %d, chunk %d)")
                                :format(startFrame, firstChunk.index))
                else
                        warn(("[PixelRenderer] could not download chunk %d. "
                                .. "The stream may have advanced past it.")
                                :format(firstChunk.index))
                end
        else
                print("[PixelRenderer] no chunks available yet; waiting for stream to produce data...")
        end
        return self
end

function PixelRenderer:_startLivePolling(url: string)
        self:_stopLivePolling()
        self._pollThread = task.spawn(function()
                local fetchCooldown = 0.2   
                local lastFetch = 0
                while not self._destroyed do
                        local now = os.clock()
                        if now - lastFetch < fetchCooldown then
                                task.wait(0.05)
                                continue
                        end
                        lastFetch = now

                        local m = self:_fetchManifest(url)
                        if m and m.chunks then
                                self._chunks = m.chunks
                                self._liveHead = m.liveHead or self._liveHead
                                self._liveEnded = m.liveEnded or false
                                self._frameCount = m.frameCount or self._frameCount
                                self._manifest = m

                                local curFrame = self._currentFrame
                                local toDownload = {}
                                for _, c in ipairs(self._chunks) do
                                        local chunkEndFrame = c.frameStart + c.frameCount
                                         
                                        if chunkEndFrame >= curFrame
                                                and c.frameStart < curFrame + self._chunkFrames * 6 then
                                                if not (self._chunkBuffers and self._chunkBuffers[c.index]) then
                                                        table.insert(toDownload, c.index)
                                                end
                                        end
                                end

                                for _, idx in ipairs(toDownload) do
                                        task.spawn(function()
                                                self:_downloadChunk(idx)
                                        end)
                                end

                                local curChunkIdx = nil
                                for _, c in ipairs(self._chunks) do
                                        if curFrame >= c.frameStart + 1
                                                and curFrame <= c.frameStart + c.frameCount then
                                                curChunkIdx = c.index
                                                break
                                        end
                                end
                                local evictThreshold = (curChunkIdx or 0) - 3
                                local toRemove = {}
                                for idx in pairs(self._chunkCache) do
                                        if idx < evictThreshold then
                                                table.insert(toRemove, idx)
                                        end
                                end
                                for _, idx in ipairs(toRemove) do
                                        self._chunkCache[idx] = nil
                                        if self._chunkBuffers then
                                                self._chunkBuffers[idx] = nil
                                        end
                                         
                                        if self._decodedFrames then
                                                self._decodedFrames[idx] = nil
                                        end
                                end
                        end
                        task.wait(0.1)
                end
        end)
end

function PixelRenderer:_stopLivePolling()
        if self._pollThread then
                task.cancel(self._pollThread)
                self._pollThread = nil
        end
end

function PixelRenderer:isLiveEnded(): boolean
        return self._liveEnded
end

function PixelRenderer:getLiveHead(): number
        return self._liveHead + 1   
end

function PixelRenderer:_downloadChunk(chunkIndex: number): boolean
        if self._chunkBuffers and self._chunkBuffers[chunkIndex] then return true end
         
        local chunkMeta
        for _, c in ipairs(self._chunks) do
                if c.index == chunkIndex then chunkMeta = c; break end
        end
        if not chunkMeta then return false end

        local url = self._streamUrl or ""
        local buf = self:_fetchChunk(url, chunkIndex)
        if not buf then
                if self._onError then
                        task.spawn(self._onError, ("chunk %d download failed"):format(chunkIndex))
                end
                return false
        end
        if not self._chunkBuffers then self._chunkBuffers = {} end
        self._chunkBuffers[chunkIndex] = buf
        return true
end

function PixelRenderer:loadDataLegacy(data: table)
        assert(type(data) == "table", "[PixelRenderer] data must be a table")
        assert(type(data.frames) == "table", "[PixelRenderer] v2 data needs a frames table")

        self:_setupSurface(data.width, data.height,
                data.fps or self.DEFAULT_FPS,
                data.frameCount or #data.frames)
        self._legacyFrames = data.frames
        self._manifest = nil
        self._chunks = nil
        self._chunkBuffers = nil

        if self._frameCount > 0 then
                self:renderFrame(1)
                self._currentFrame = 1
        end
        return self
end

function PixelRenderer:loadFromString(text: string)
        local fn, err = loadstring(text, "PixelRendererData")
        if not fn then
                error(("[PixelRenderer] parse error: %s"):format(err), 0)
        end
        local ok, result = pcall(fn)
        if not ok then
                error(("[PixelRenderer] chunk error: %s"):format(tostring(result)), 0)
        end
        if result.version == 3 then
                return self:loadData(result, result._chunks)
        end
        return self:loadDataLegacy(result)
end

function PixelRenderer:_startPrefetch()
        if self._live then return end   
        self:_stopPrefetch()
        self._prefetchThread = task.spawn(function()
                while self._playing and not self._destroyed do
                        local cur = self._currentFrame
                        local curMeta = self:_findChunkForFrame(cur)
                        if curMeta then
                                local curIdx = curMeta.index
                                 
                                local toDownload = {}
                                for offset = 0, 5 do
                                        local targetIdx = curIdx + offset
                                         
                                        local meta
                                        for _, c in ipairs(self._chunks) do
                                                if c.index == targetIdx then meta = c; break end
                                        end
                                        if meta and not (self._chunkBuffers and self._chunkBuffers[targetIdx]) then
                                                table.insert(toDownload, targetIdx)
                                        end
                                end
                                 
                                for _, idx in ipairs(toDownload) do
                                        task.spawn(function()
                                                self:_downloadChunk(idx)
                                        end)
                                end
                                 
                                for offset = 0, 5 do
                                        local targetIdx = curIdx + offset
                                        local meta
                                        for _, c in ipairs(self._chunks) do
                                                if c.index == targetIdx then meta = c; break end
                                        end
                                        if meta and self._chunkBuffers and self._chunkBuffers[targetIdx] then
                                                if not (self._chunkCache[targetIdx] and self._chunkCache[targetIdx].decompressed) then
                                                        self:_getDecompressedChunk(meta)
                                                        task.wait()
                                                end
                                        end
                                end
                                self:_evictChunks(curIdx)
                                task.wait(0.05)
                        else
                                task.wait(0.1)
                        end
                end
        end)
end

function PixelRenderer:_stopPrefetch()
        if self._prefetchThread then
                task.cancel(self._prefetchThread)
                self._prefetchThread = nil
        end
end

function PixelRenderer:play()
        if self._destroyed then return end
        if self._playing then return end
        if not self._live and self._frameCount == 0 then
                warn("[PixelRenderer] no data loaded")
                return
        end
        self._playing = true
        self._startTime = os.clock() - ((self._currentFrame - 1) / self._fps)
        if self._connection then self._connection:Disconnect() end
        if not self._live then
                self:_startPrefetch()
        end

        self._connection = RunService.Heartbeat:Connect(function()
                if not self._playing then return end
                local elapsed = os.clock() - self._startTime
                local target = math.floor(elapsed * self._fps) + 1

                if self._live then
                         
                        local liveHead1 = self._liveHead + 1   
                         
                        local oldest = target
                        if #self._chunks > 0 then
                                oldest = self._chunks[1].frameStart + 1
                        end
                         
                        if target < oldest then
                                target = oldest
                                self._startTime = os.clock() - ((target - 1) / self._fps)
                        end
                         
                        if target > liveHead1 then
                                target = liveHead1
                                self._startTime = os.clock() - ((target - 1) / self._fps)
                        end
                         
                        if self._liveEnded and target >= liveHead1 then
                                if self._currentFrame >= liveHead1 then
                                        self._playing = false
                                        if self._connection then
                                                self._connection:Disconnect()
                                                self._connection = nil
                                        end
                                        if self._onEnded then task.spawn(self._onEnded) end
                                        return
                                end
                        end
                else
                         
                        if target > self._frameCount then
                                if self._looping then
                                        self._startTime = os.clock()
                                        target = 1
                                        self._prevDecoded = nil
                                        table.clear(self._chunkCache)
                                else
                                        self._playing = false
                                        self._currentFrame = self._frameCount
                                        self:renderFrame(self._frameCount)
                                        if self._connection then
                                                self._connection:Disconnect()
                                                self._connection = nil
                                        end
                                        self:_stopPrefetch()
                                        if self._onEnded then task.spawn(self._onEnded) end
                                        return
                                end
                        end
                end

                if target ~= self._currentFrame then
                        self:renderFrame(target)
                end
        end)
end

function PixelRenderer:pause()
        if not self._playing then return end
        self._playing = false
        if self._connection then
                self._connection:Disconnect()
                self._connection = nil
        end
        self:_stopPrefetch()
end

function PixelRenderer:stop()
        self:pause()
        if not self._live then
                self._currentFrame = 1
                if self._frameCount > 0 then
                        self:renderFrame(1)
                end
        end
end

function PixelRenderer:seek(frameIndex: number)
        if frameIndex < 1 then frameIndex = 1 end
        if not self._live and frameIndex > self._frameCount then
                frameIndex = self._frameCount
        end
        self._currentFrame = frameIndex
        if self._playing then
                self._startTime = os.clock() - ((frameIndex - 1) / self._fps)
        end
        self:renderFrame(frameIndex)
end

function PixelRenderer:setLoop(enabled: boolean) self._looping = enabled and true or false end
function PixelRenderer:isLooping(): boolean return self._looping end
function PixelRenderer:isPlaying(): boolean return self._playing end
function PixelRenderer:getProgress(): number
        if self._frameCount == 0 then return 0 end
        return self._currentFrame / self._frameCount
end
function PixelRenderer:getFrameCount(): number return self._frameCount end
function PixelRenderer:getCurrentFrame(): number return self._currentFrame end
function PixelRenderer:onEnded(cb: () -> ()) self._onEnded = cb end
function PixelRenderer:onError(cb: (string) -> ()) self._onError = cb end
function PixelRenderer:getBackend(): string return self._backend or "auto" end

function PixelRenderer:setPixelSize(size: Vector2)
        self._baseSize = size
        self._container.Size = UDim2.fromOffset(size.X, size.Y)
end

function PixelRenderer:setScale(scale: number)
        local base = self._baseSize
        if not base then return end
        self._container.Size = UDim2.fromOffset(
                math.max(1, math.floor(base.X * scale)),
                math.max(1, math.floor(base.Y * scale)))
end

function PixelRenderer:setPosition(position: UDim2, anchorPoint: Vector2?)
        self._container.Position = position
        if anchorPoint then self._container.AnchorPoint = anchorPoint end
end

function PixelRenderer:setVisible(visible: boolean) self._container.Visible = visible end

function PixelRenderer:destroy()
        self:pause()
        self._destroyed = true
        self:_stopPrefetch()
        self:_stopLivePolling()
        if self._connection then
                self._connection:Disconnect()
                self._connection = nil
        end
        if self._tiles then
                for _, t in ipairs(self._tiles) do
                        if t.editableImage then t.editableImage:Destroy() end
                        if t.imageLabel  then t.imageLabel:Destroy()  end
                end
                self._tiles = nil
        end
        if self._framePixels then
                for _, p in ipairs(self._framePixels) do
                        p:Destroy()
                end
                self._framePixels = nil
        end
        self._prevPaintBuf = nil
        table.clear(self._chunkCache)
        table.clear(self._legacyCache)
        if self._gui and self._gui.Parent then self._gui:Destroy() end
        self._manifest = nil
        self._legacyFrames = nil
end

PixelRenderer._lz4Decode = lz4Decode

return PixelRenderer
