local _cfg = getgenv().CW_CONFIG or {}

local function boolOr(v, default)
    if v == nil then return default end
    return v
end

local function numOr(v, default, minValue)
    v = tonumber(v)
    if v == nil then v = default end
    if minValue and v < minValue then v = minValue end
    return v
end

local CURSOR_FILE    = _cfg.CURSOR_FILE    or "CycleWare/Assets/cursor.png"
local HITMARKER_FILE = _cfg.HITMARKER_FILE or "CycleWare/Assets/hitmarker.png"
local SOUND_FILE     = _cfg.SOUND_FILE     or "CycleWare/Assets/sound.mp3"

local HITMARKER_SIZE             = numOr(_cfg.HITMARKER_SIZE, 50, 1)
local SOUND_VOLUME               = numOr(_cfg.SOUND_VOLUME, 1, 0)
local CURSOR_TARGET_SIZE         = numOr(_cfg.CURSOR_TARGET_SIZE, 82, 1)
local HITMARKER_VISIBLE_DURATION = numOr(_cfg.HITMARKER_VISIBLE_DURATION, 0.05, 0)
local HITMARKER_FADEOUT_DURATION = numOr(_cfg.HITMARKER_FADEOUT_DURATION, 0.15, 0)

local HITMARKER_RANDOM_ROTATION = boolOr(_cfg.HITMARKER_RANDOM_ROTATION, true)
local HITMARKER_FOLLOW_MOUSE    = boolOr(_cfg.HITMARKER_FOLLOW_MOUSE, true)
local HITMARKER_FADEOUT         = boolOr(_cfg.HITMARKER_FADEOUT, true)

local Players           = game:GetService("Players")
local SoundService      = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local GuiService        = game:GetService("GuiService")
local Debris            = game:GetService("Debris")
local TweenService      = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()

local CW = getgenv().__CW_CORE_STATE
local isFirstRun = false
if not CW then
    isFirstRun = true
    CW = {
        Settings = {},
        Assets   = {},

        ActiveFollowClones = {},
        State    = {
            cursorsReady     = false,
            currentCursorKey = nil,
            settingCursor    = false,
            lastTarget       = nil,
            enforcerConn     = nil,
            enableConn       = nil,
        },
    }
    getgenv().__CW_CORE_STATE = CW
end

local ShootEvent = CW.ShootEvent
if not ShootEvent then
    ShootEvent = ReplicatedStorage:WaitForChild("GunRemotes"):WaitForChild("ShootEvent")
    CW.ShootEvent = ShootEvent
end

CW.Settings.SOUND_VOLUME               = SOUND_VOLUME
CW.Settings.HITMARKER_SIZE             = HITMARKER_SIZE
CW.Settings.CURSOR_TARGET_SIZE         = CURSOR_TARGET_SIZE
CW.Settings.HITMARKER_RANDOM_ROTATION  = HITMARKER_RANDOM_ROTATION
CW.Settings.HITMARKER_FOLLOW_MOUSE     = HITMARKER_FOLLOW_MOUSE
CW.Settings.HITMARKER_VISIBLE_DURATION = HITMARKER_VISIBLE_DURATION
CW.Settings.HITMARKER_FADEOUT          = HITMARKER_FADEOUT
CW.Settings.HITMARKER_FADEOUT_DURATION = HITMARKER_FADEOUT_DURATION

print("[CW] " .. (isFirstRun and "First run — initializing." or "Re-run detected — updating settings only."))

local cachedTeamColor = LocalPlayer.TeamColor
local CachedMouseX, CachedMouseY = 0, 0
do local loc = UserInputService:GetMouseLocation()
    CachedMouseX, CachedMouseY = loc.X, loc.Y end

if isFirstRun then
    LocalPlayer:GetPropertyChangedSignal("TeamColor"):Connect(function()
        cachedTeamColor = LocalPlayer.TeamColor
    end)

    UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
        local inset = GuiService:GetGuiInset()
        CachedMouseX = input.Position.X + inset.X
        CachedMouseY = input.Position.Y + inset.Y

        for clone in pairs(CW.ActiveFollowClones) do
            local ok = pcall(function()
                clone.Position = UDim2.fromOffset(CachedMouseX, CachedMouseY)
            end)
            if not ok then CW.ActiveFollowClones[clone] = nil end
        end
    end)
end

local floor   = math.floor
local mmin    = math.min
local mabs    = math.abs
local sbyte   = string.byte
local schar   = string.char
local sformat = string.format
local tconcat = table.concat
local tunpack = table.unpack
local band    = bit32.band
local bxor    = bit32.bxor
local rshift  = bit32.rshift

local CURSOR_ROOT            = "CycleWare"
local CURSOR_FOLDER          = "CycleWare/Assets"
local CACHE_FOLDER           = CURSOR_FOLDER.."/Cache"
local TINTED_FOLDER          = CACHE_FOLDER.."/Tinted"
local HITMARKER_CACHE_FOLDER = CACHE_FOLDER.."/HitmarkerCache"
local SOUND_CACHE_FOLDER     = CACHE_FOLDER.."/SoundCache"

local CURSOR_SIG_FILE    = CACHE_FOLDER.."/cursor.sig"
local HITMARKER_SIG_FILE = CACHE_FOLDER.."/hitmarker.sig"
local SOUND_SIG_FILE     = CACHE_FOLDER.."/sound.sig"

local ALL_FOLDERS = {
    CURSOR_ROOT, CURSOR_FOLDER, CACHE_FOLDER,
    TINTED_FOLDER, HITMARKER_CACHE_FOLDER, SOUND_CACHE_FOLDER,
}

local function ensureFolders()
    for _, folder in ipairs(ALL_FOLDERS) do
        if not isfolder(folder) then
            pcall(makefolder, folder)
        end
    end
end
ensureFolders()

local function readSigFile(path)
    if not isfile(path) then return nil end
    local ok, data = pcall(readfile, path)
    if ok then return data end
    return nil
end

local function pruneOldFiles(folder, prefix, keepHash, label)
    local ok, files = pcall(listfiles, folder)
    if not ok or not files then return end
    local deleted = 0
    for _, path in ipairs(files) do
        local name = path:match("([^/\\]+)$")
        if name and name:sub(1, #prefix) == prefix and not name:find(keepHash, 1, true) then
            if pcall(delfile, path) then deleted = deleted + 1 end
        end
    end
    if deleted > 0 then
        print(sformat("[CW] Pruned %d stale %s file(s)", deleted, label))
    end
end

if not CW._crcT then
    local t = {}
    for i = 0, 255 do
        local c = i
        for _ = 1, 8 do
            c = band(c, 1) == 1
                and bxor(0xEDB88320, rshift(c, 1))
                or  rshift(c, 1)
        end
        t[i] = c
    end
    CW._crcT = t
end
local _crcT = CW._crcT

local function crc32(s)
    local c = 0xFFFFFFFF
    for i = 1, #s do
        c = bxor(_crcT[band(bxor(c, sbyte(s, i)), 0xFF)], rshift(c, 8))
    end
    return bxor(c, 0xFFFFFFFF)
end

local function computeFileSignature(path, prefix, extra)
    extra = extra or ""
    if not isfile(path) then
        return prefix..":none"..extra, nil
    end
    local ok, data = pcall(readfile, path)
    if not ok or not data then
        return prefix..":readfail"..extra, nil
    end
    return prefix..":"..crc32(data)..extra, data
end

local function adler32(s)
    local s1, s2 = 1, 0
    for i = 1, #s do
        local b = sbyte(s, i)
        s1 = (s1 + b) % 65521
        s2 = (s2 + s1) % 65521
    end
    return s2 * 65536 + s1
end

local function u32be(n)
    return schar(rshift(n,24), band(rshift(n,16),0xFF),
        band(rshift(n,8),0xFF), band(n,0xFF))
end

local function pngChunk(t, data)
    local p = t..data
    return u32be(#data)..p..u32be(crc32(p))
end

local function literalCode(n)
    if n <= 143 then
        return 0x30 + n, 8
    else
        return 0x190 + (n - 144), 9
    end
end

local function deflateFixedHuffman(raw)
    local outBytes = {}
    local bitbuf, bitcnt = 0, 0

    local function pushBit(bit)
        bitbuf = bitbuf + bit * (2 ^ bitcnt)
        bitcnt = bitcnt + 1
        if bitcnt == 8 then
            outBytes[#outBytes + 1] = schar(bitbuf)
            bitbuf, bitcnt = 0, 0
        end
    end

    local function writeBitsLSB(value, n)
        for i = 0, n - 1 do
            pushBit(band(rshift(value, i), 1))
        end
    end

    local function writeHuffman(code, len)
        for i = len - 1, 0, -1 do
            pushBit(band(rshift(code, i), 1))
        end
    end

    writeBitsLSB(1, 1)
    writeBitsLSB(1, 2)

    for i = 1, #raw do
        local code, len = literalCode(sbyte(raw, i))
        writeHuffman(code, len)
    end

    writeHuffman(0, 7)

    if bitcnt > 0 then
        outBytes[#outBytes + 1] = schar(bitbuf)
    end

    return tconcat(outBytes)
end

local function encodePNG(px, w, h)
    local rows = {}
    for y = 0, h-1 do
        local row = {"\0"}
        for x = 0, w-1 do
            local i = (y*w+x)*4+1
            row[#row+1] = schar(px[i], px[i+1], px[i+2], px[i+3])
        end
        rows[y+1] = tconcat(row)
    end
    local raw = tconcat(rows)
    return "\137\80\78\71\13\10\26\10"
        .. pngChunk("IHDR", u32be(w)..u32be(h).."\8\6\0\0\0")
        .. pngChunk("IDAT", "\120\1"..deflateFixedHuffman(raw)..u32be(adler32(raw)))
        .. pngChunk("IEND", "")
end

local COLOR_CHANNELS = {[0]=1, [2]=3, [3]=1, [4]=2, [6]=4}

local function inflate(data)
    local bytes = {}
    for i = 1, #data do bytes[i] = sbyte(data, i) end
    local pos, bitbuf, bitcount = 1, 0, 0
    local out, opos = {}, 1

    local function readbits(n)
        while bitcount < n do
            if pos <= #bytes then bitbuf = bitbuf + bytes[pos] * (2^bitcount); pos = pos+1 end
            bitcount = bitcount + 8
        end
        local v = bitbuf % (2^n)
        bitbuf = floor(bitbuf / (2^n)); bitcount = bitcount - n
        return v
    end

    local function buildTable(lens, nsym)
        local counts, nextcode = {}, {}
        for i = 0, 15 do counts[i] = 0 end
        for i = 0, nsym-1 do local l = lens[i] or 0; counts[l] = counts[l]+1 end
        counts[0] = 0
        local code = 0
        for b = 1, 15 do code = (code + counts[b-1])*2; nextcode[b] = code end
        local tbl = {}
        for sym = 0, nsym-1 do
            local l = lens[sym] or 0
            if l > 0 then
                local c = nextcode[l]; nextcode[l] = c+1
                local rev, tmp = 0, c
                for _ = 1, l do rev = rev*2 + tmp%2; tmp = floor(tmp/2) end
                tbl[rev*16+l] = sym
            end
        end
        return tbl
    end

    local function decode(tbl, maxbits)
        while bitcount < maxbits and pos <= #bytes do
            bitbuf = bitbuf + bytes[pos] * (2^bitcount); pos = pos+1; bitcount = bitcount+8
        end
        for b = 1, maxbits do
            if bitcount >= b then
                local key = (bitbuf % (2^b))*16 + b
                local sym = tbl[key]
                if sym ~= nil then
                    bitbuf = floor(bitbuf/(2^b)); bitcount = bitcount-b; return sym
                end
            end
        end
        error("inflate: decode failed at byte "..pos)
    end

    local fixLL, fixD = {}, {}
    for i=0,143 do fixLL[i]=8 end; for i=144,255 do fixLL[i]=9 end
    for i=256,279 do fixLL[i]=7 end; for i=280,287 do fixLL[i]=8 end
    for i=0,31 do fixD[i]=5 end
    local FLL = buildTable(fixLL,288); local FDT = buildTable(fixD,32)

    local LBASE={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
    local LEXT ={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
    local DBASE={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
    local DEXT ={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
    local CLORD={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

    local function decodeBlock(llt, ddt, mLL, mD)
        while true do
            local sym = decode(llt, mLL)
            if sym < 256 then out[opos]=sym; opos=opos+1
            elseif sym == 256 then break
            else
                local len  = LBASE[sym-256] + readbits(LEXT[sym-256])
                local dc   = decode(ddt, mD)
                local dist = DBASE[dc+1] + readbits(DEXT[dc+1])
                local src  = opos - dist
                for _ = 1, len do out[opos]=out[src]; opos=opos+1; src=src+1 end
            end
        end
    end

    repeat
        local bfinal, btype = readbits(1), readbits(2)
        if btype == 0 then
            if bitcount%8 ~= 0 then readbits(bitcount%8) end
            local len = bytes[pos] + bytes[pos+1]*256; pos = pos+4
            for i = 0, len-1 do out[opos]=bytes[pos+i]; opos=opos+1 end
            pos = pos+len
        elseif btype == 1 then decodeBlock(FLL, FDT, 9, 5)
        elseif btype == 2 then
            local hlit  = readbits(5)+257
            local hdist = readbits(5)+1
            local hclen = readbits(4)+4
            local clLens = {}
            for i = 0,18 do clLens[i]=0 end
            for i = 1,hclen do clLens[CLORD[i]]=readbits(3) end
            local CLT = buildTable(clLens, 19)
            local combined, ci = {}, 0
            while ci < hlit+hdist do
                local s = decode(CLT, 7)
                if s <= 15 then combined[ci]=s; ci=ci+1
                elseif s == 16 then local r=readbits(2)+3; for _=1,r do combined[ci]=combined[ci-1]; ci=ci+1 end
                elseif s == 17 then local r=readbits(3)+3; for _=1,r do combined[ci]=0; ci=ci+1 end
                else local r=readbits(7)+11; for _=1,r do combined[ci]=0; ci=ci+1 end end
            end
            local llLens, distLens, mLL, mD = {}, {}, 0, 0
            for i=0,hlit-1  do llLens[i]=combined[i];       if combined[i]>(mLL or 0) then mLL=combined[i] end end
            for i=0,hdist-1 do distLens[i]=combined[hlit+i]; if combined[hlit+i]>(mD or 0) then mD=combined[hlit+i] end end
            decodeBlock(buildTable(llLens,hlit), buildTable(distLens,hdist), mLL, mD)
        else error("inflate: reserved block type") end
    until bfinal == 1

    local parts = {}
    for i = 1, opos-1, 4096 do
        parts[#parts+1] = schar(tunpack(out, i, mmin(i+4095, opos-1)))
    end
    return tconcat(parts)
end

local function parsePNG(data)
    assert(data:sub(1,8) == "\137\80\78\71\13\10\26\10", "not a PNG")
    local pos, w, h, bitDepth, colorType = 9
    local idatParts, palette, transAlpha = {}, {}, {}

    while pos <= #data do
        local len   = sbyte(data,pos)*16777216 + sbyte(data,pos+1)*65536
                    + sbyte(data,pos+2)*256    + sbyte(data,pos+3)
        local typ   = data:sub(pos+4, pos+7)
        local chunk = data:sub(pos+8, pos+8+len-1)
        pos = pos + 12 + len

        if typ == "IHDR" then
            w         = sbyte(chunk,1)*16777216+sbyte(chunk,2)*65536+sbyte(chunk,3)*256+sbyte(chunk,4)
            h         = sbyte(chunk,5)*16777216+sbyte(chunk,6)*65536+sbyte(chunk,7)*256+sbyte(chunk,8)
            bitDepth  = sbyte(chunk,9)
            colorType = sbyte(chunk,10)
            assert(bitDepth==8 or (colorType==3 and bitDepth<=8), "parsePNG: unsupported bit depth "..bitDepth)
        elseif typ == "PLTE" then
            for i = 0, floor(#chunk/3)-1 do
                palette[i] = {sbyte(chunk,i*3+1), sbyte(chunk,i*3+2), sbyte(chunk,i*3+3)}
            end
        elseif typ == "tRNS" then
            if colorType == 3 then for i=1,#chunk do transAlpha[i-1]=sbyte(chunk,i) end end
        elseif typ == "IDAT" then idatParts[#idatParts+1] = chunk
        elseif typ == "IEND" then break end
    end

    local ch = COLOR_CHANNELS[colorType]
    assert(ch, "parsePNG: unsupported colorType "..tostring(colorType))

    local rawData = inflate(tconcat(idatParts):sub(3, -5))
    local stride, px, rpos, prev = w*ch, {}, 1, {}
    for i = 1, stride do prev[i] = 0 end

    for y = 0, h-1 do
        local ftype = sbyte(rawData, rpos); rpos = rpos+1
        local row = {}
        for x = 1, stride do
            local b  = sbyte(rawData, rpos); rpos = rpos+1
            local a  = row[x-ch] or 0
            local up = prev[x]   or 0
            local ul = prev[x-ch] or 0
            if     ftype==0 then row[x]=b
            elseif ftype==1 then row[x]=(b+a)%256
            elseif ftype==2 then row[x]=(b+up)%256
            elseif ftype==3 then row[x]=(b+floor((a+up)/2))%256
            elseif ftype==4 then
                local p=a+up-ul
                local pa,pb,pc=mabs(p-a),mabs(p-up),mabs(p-ul)
                row[x]=(b+(pa<=pb and pa<=pc and a or pb<=pc and up or ul))%256
            end
        end
        prev = row
        for x = 0, w-1 do
            local dst, s = (y*w+x)*4+1, x*ch+1
            if     colorType==6 then px[dst]=row[s];px[dst+1]=row[s+1];px[dst+2]=row[s+2];px[dst+3]=row[s+3]
            elseif colorType==2 then px[dst]=row[s];px[dst+1]=row[s+1];px[dst+2]=row[s+2];px[dst+3]=255
            elseif colorType==0 then px[dst]=row[s];px[dst+1]=row[s];  px[dst+2]=row[s];  px[dst+3]=255
            elseif colorType==4 then px[dst]=row[s];px[dst+1]=row[s];  px[dst+2]=row[s];  px[dst+3]=row[s+1]
            elseif colorType==3 then
                local pal=palette[row[s]] or {255,255,255}
                px[dst]=pal[1];px[dst+1]=pal[2];px[dst+2]=pal[3]
                px[dst+3]=transAlpha[row[s]] ~= nil and transAlpha[row[s]] or 255
            end
        end
    end
    return px, w, h
end

local function resizePixels(px, w, h, tw, th)
    if tw==w and th==h then return px,w,h end
    local out, scaleX, scaleY = {}, w/tw, h/th
    for y=0,th-1 do
        local srcY = mmin(floor(y*scaleY), h-1)
        for x=0,tw-1 do
            local srcX = mmin(floor(x*scaleX), w-1)
            local src=(srcY*w+srcX)*4+1; local dst=(y*tw+x)*4+1
            out[dst]=px[src] or 0; out[dst+1]=px[src+1] or 0
            out[dst+2]=px[src+2] or 0; out[dst+3]=px[src+3] or 0
        end
    end
    print(sformat("[CW] Resized to %d×%d", tw, th))
    return out, tw, th
end

local function applyTint(px, w, h, tR, tG, tB)
    local out = {}
    for i=1, w*h*4, 4 do
        local r,g,b,a = px[i] or 0, px[i+1] or 0, px[i+2] or 0, px[i+3] or 0
        if a > 10 then
            local lum = (0.299*r + 0.587*g + 0.114*b) / 255
            out[i]  =mmin(255,floor(lum*tR+0.5))
            out[i+1]=mmin(255,floor(lum*tG+0.5))
            out[i+2]=mmin(255,floor(lum*tB+0.5))
            out[i+3]=a
        else out[i]=0; out[i+1]=0; out[i+2]=0; out[i+3]=0 end
    end
    return out
end

local TINT_VARIANTS = {
    {key="red",   tR=255, tG=56,  tB=56},
    {key="green", tR=56,  tG=255, tB=56},
}

local function computeCursorSourceSignature()

    local tintSig = ""
    for _, v in ipairs(TINT_VARIANTS) do
        tintSig = tintSig.."|"..v.key..":"..v.tR..","..v.tG..","..v.tB
    end
    return computeFileSignature(CURSOR_FILE, "cur", "|size:"..tostring(CW.Settings.CURSOR_TARGET_SIZE)..tintSig)
end

local function buildCursorFiles(sigHash)
    return {
        white = TINTED_FOLDER.."/cur_white_"..sigHash..".png",
        red   = TINTED_FOLDER.."/cur_red_"..sigHash..".png",
        green = TINTED_FOLDER.."/cur_green_"..sigHash..".png",
    }
end

local function setOSCursor(key)
    if CW.State.currentCursorKey == key then return end
    CW.State.currentCursorKey = key
    local url = CW.Assets[key]
    if url then
        CW.State.settingCursor = true
        UserInputService.MouseIcon = url
        CW.State.settingCursor = false
    end
end

local function connectEnforcer()
    if CW.State.enforcerConn then CW.State.enforcerConn:Disconnect() end
    if CW.State.enableConn   then CW.State.enableConn:Disconnect()   end

    CW.State.enforcerConn = UserInputService:GetPropertyChangedSignal("MouseIcon"):Connect(function()
        if CW.State.settingCursor then return end
        if not CW.State.cursorsReady or not CW.State.currentCursorKey then return end
        local expected = CW.Assets[CW.State.currentCursorKey]
        if expected and UserInputService.MouseIcon ~= expected then
            CW.State.settingCursor = true
            UserInputService.MouseIcon = expected
            CW.State.settingCursor = false
        end
    end)

    CW.State.enableConn = UserInputService:GetPropertyChangedSignal("MouseIconEnabled"):Connect(function()
        if CW.State.cursorsReady and not UserInputService.MouseIconEnabled then
            UserInputService.MouseIconEnabled = true
        end
    end)
end

local function activateCursors()
    CW.State.cursorsReady = true
    UserInputService.MouseIconEnabled = true
    CW.State.currentCursorKey = nil
    setOSCursor("white")
    connectEnforcer()
end

local function loadCachedAssets(files)
    CW.Assets.white = getcustomasset(files.white)
    CW.Assets.red   = getcustomasset(files.red)
    CW.Assets.green = getcustomasset(files.green)
end

local function reloadCursorFromSource(sigHash, data)
    if not data then
        print("[CW] No valid cursor image found at "..CURSOR_FILE.." — place a PNG there and re-run.")
        return false
    end
    local ok2, px, w, h = pcall(parsePNG, data)
    if not ok2 then
        print("[CW] parsePNG failed: "..tostring(px)); return false
    end
    print(sformat("[CW] Loaded new cursor.png (%d×%d)", w, h))

    local targetSize = CW.Settings.CURSOR_TARGET_SIZE
    if targetSize then
        px, w, h = resizePixels(px, w, h, targetSize, targetSize)
    end

    local files = buildCursorFiles(sigHash)

    writefile(files.white, encodePNG(px, w, h))
    CW.Assets.white = getcustomasset(files.white)

    for _, v in ipairs(TINT_VARIANTS) do
        writefile(files[v.key], encodePNG(applyTint(px, w, h, v.tR, v.tG, v.tB), w, h))
        CW.Assets[v.key] = getcustomasset(files[v.key])
    end

    writefile(CURSOR_SIG_FILE, sigHash)
    pruneOldFiles(TINTED_FOLDER, "cur_", sigHash, "cursor")
    return true
end

local function generateCursors()
    local currentSig, data = computeCursorSourceSignature()
    local sigHash    = sformat("%08x", crc32(currentSig))
    local storedHash = readSigFile(CURSOR_SIG_FILE)

    local files = buildCursorFiles(sigHash)
    local filesExist = isfile(files.white) and isfile(files.red) and isfile(files.green)

    if filesExist and storedHash == sigHash then
        print("[CW] cursor.png unchanged — tinted variants match, using cache")
        loadCachedAssets(files)
        activateCursors()
        print("[CW] OS cursor active (cached).")
        return
    end

    if storedHash and storedHash ~= sigHash then
        print("[CW] cursor.png changed since last run — reloading original and regenerating tints")
    elseif not filesExist then
        print("[CW] Tinted cache incomplete — regenerating from current cursor.png")
    end

    if reloadCursorFromSource(sigHash, data) then
        activateCursors()
        print("[CW] OS cursor active (regenerated from new original).")
    end
end

task.spawn(generateCursors)

if isFirstRun then
    CW.IAPortable = Instance.new("ScreenGui")
    CW.IAPortable.Name           = "CW_SA"
    CW.IAPortable.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    CW.IAPortable.ResetOnSpawn   = false
    CW.IAPortable.IgnoreGuiInset = true
    CW.IAPortable.DisplayOrder   = 9998
    CW.IAPortable.Parent         = gethui()

    CW.HMTemplate = Instance.new("ImageLabel")
    CW.HMTemplate.AnchorPoint            = Vector2.new(0.5,0.5)
    CW.HMTemplate.BackgroundTransparency = 1
    CW.HMTemplate.Image                  = ""
end

CW.HMTemplate.Size = UDim2.new(0, CW.Settings.HITMARKER_SIZE, 0, CW.Settings.HITMARKER_SIZE)

local function buildHitmarkerFile(sigHash)
    return HITMARKER_CACHE_FOLDER.."/hm_"..sigHash..".png"
end

local function reloadHitmarker()
    if not isfile(HITMARKER_FILE) then
        print("[CW] No hitmarker.png found at "..HITMARKER_FILE.." — place one there and re-run.")
        return
    end

    local currentSig, data = computeFileSignature(HITMARKER_FILE, "hm")
    local sigHash    = sformat("%08x", crc32(currentSig))
    local storedHash = readSigFile(HITMARKER_SIG_FILE)
    local cachedPath = buildHitmarkerFile(sigHash)

    if storedHash == sigHash and isfile(cachedPath) and CW.HMTemplate.Image ~= "" then
        print("[CW] hitmarker.png unchanged — keeping current asset")
        return
    end

    if storedHash and storedHash ~= sigHash then
        print("[CW] hitmarker.png changed since last run — reloading new image")
    else
        print("[CW] Hitmarker " .. (isFirstRun and "loaded" or "reloaded") .. " from file.")
    end

    if not data then
        print("[CW] readfile failed for hitmarker.png")
        return
    end
    writefile(cachedPath, data)

    local ok2, newAsset = pcall(getcustomasset, cachedPath)
    if not ok2 or not newAsset then
        print("[CW] getcustomasset failed for hitmarker.png")
        return
    end

    CW.HMTemplate.Image = newAsset
    writefile(HITMARKER_SIG_FILE, sigHash)
    pruneOldFiles(HITMARKER_CACHE_FOLDER, "hm_", sigHash, "hitmarker")
end

reloadHitmarker()

local function buildSoundFile(sigHash)
    return SOUND_CACHE_FOLDER.."/snd_"..sigHash..".mp3"
end

local function reloadSound()
    if not isfile(SOUND_FILE) then
        print("[CW] No sound.mp3 found at "..SOUND_FILE.." — hit sound disabled until you add one.")
        CW.Settings.SOUND_ID = nil
        return
    end

    local currentSig, data = computeFileSignature(SOUND_FILE, "snd")
    local sigHash    = sformat("%08x", crc32(currentSig))
    local storedHash = readSigFile(SOUND_SIG_FILE)
    local cachedPath = buildSoundFile(sigHash)

    if storedHash == sigHash and isfile(cachedPath) and CW.Settings.SOUND_ID then
        print("[CW] sound.mp3 unchanged — keeping current asset")
        return
    end

    if storedHash and storedHash ~= sigHash then
        print("[CW] sound.mp3 changed since last run — reloading new sound")
    else
        print("[CW] Sound " .. (isFirstRun and "loaded" or "reloaded") .. " from file.")
    end

    if not data then
        print("[CW] readfile failed for sound.mp3")
        CW.Settings.SOUND_ID = nil
        return
    end
    writefile(cachedPath, data)

    local ok2, newAsset = pcall(getcustomasset, cachedPath)
    if not ok2 or not newAsset then
        print("[CW] getcustomasset failed for sound.mp3")
        CW.Settings.SOUND_ID = nil
        return
    end

    CW.Settings.SOUND_ID = newAsset
    writefile(SOUND_SIG_FILE, sigHash)
    pruneOldFiles(SOUND_CACHE_FOLDER, "snd_", sigHash, "sound")
end

reloadSound()

local function playHitSound()
    if not CW.Settings.SOUND_ID then return end

    local ok, s = pcall(function()
        local snd = Instance.new("Sound")
        snd.SoundId = CW.Settings.SOUND_ID
        snd.Volume  = CW.Settings.SOUND_VOLUME
        SoundService:PlayLocalSound(snd)
        return snd
    end)
    if not ok or not s then return end

    local cleaned = false
    local function cleanup()
        if cleaned then return end
        cleaned = true
        pcall(function() s:Destroy() end)
    end

    s.Ended:Connect(cleanup)
    Debris:AddItem(s, 10)
end

if isFirstRun then
    CW.Bindable = Instance.new("BindableEvent")

    CW.Bindable.Event:Connect(function(bullets)
        local ShotHit = false
        for _, bullet in pairs(bullets) do
            local Hit = bullet[3]
            if not Hit or not Hit.Parent then continue end
            local Player = Players:GetPlayerFromCharacter(Hit.Parent)
                or (Hit.Parent.Parent and Players:GetPlayerFromCharacter(Hit.Parent.Parent))
            if Player and Player ~= LocalPlayer and Player.TeamColor ~= cachedTeamColor then
                ShotHit = true; break
            end
        end
        if not ShotHit then return end
        playHitSound()

        local Clone = CW.HMTemplate:Clone()
        Clone.Size              = UDim2.new(0, CW.Settings.HITMARKER_SIZE, 0, CW.Settings.HITMARKER_SIZE)
        Clone.Position          = UDim2.fromOffset(CachedMouseX, CachedMouseY)
        Clone.Rotation          = CW.Settings.HITMARKER_RANDOM_ROTATION and math.random(0,90) or 0
        Clone.ImageTransparency = 0
        Clone.Parent            = CW.IAPortable

        if CW.Settings.HITMARKER_FOLLOW_MOUSE then
            CW.ActiveFollowClones[Clone] = true
        end

        local function finishClone()
            CW.ActiveFollowClones[Clone] = nil
            if Clone.Parent then Clone:Destroy() end
        end

        task.delay(CW.Settings.HITMARKER_VISIBLE_DURATION, function()
            if not Clone.Parent then return end

            if CW.Settings.HITMARKER_FADEOUT then

                local baseSize = Clone.Size
                local growSize = UDim2.new(
                    0, baseSize.X.Offset * 1.35,
                    0, baseSize.Y.Offset * 1.35
                )

                local ok = pcall(function()
                    local tween = TweenService:Create(
                        Clone,
                        TweenInfo.new(
                            CW.Settings.HITMARKER_FADEOUT_DURATION,
                            Enum.EasingStyle.Quad,
                            Enum.EasingDirection.Out
                        ),
                        { ImageTransparency = 1, Size = growSize }
                    )
                    tween.Completed:Connect(finishClone)
                    tween:Play()
                end)
                if not ok then finishClone() end
            else
                finishClone()
            end
        end)
    end)

    local OldNameCall
    OldNameCall = hookmetamethod(ShootEvent, "__namecall", newcclosure(function(self, ...)
        if checkcaller() then return OldNameCall(self, ...) end
        if getnamecallmethod() == "FireServer" and self == ShootEvent then
            CW.Bindable.Fire(CW.Bindable, ...)
        end
        return OldNameCall(self, ...)
    end))
end

if isFirstRun then
    RunService.PreRender:Connect(function()
        if not CW.State.cursorsReady then return end
        local Target = Mouse.Target
        if Target == CW.State.lastTarget then return end
        CW.State.lastTarget = Target
        if not Target or not Target.Parent then setOSCursor("white"); return end

        local Player = Players:GetPlayerFromCharacter(Target.Parent)
            or (Target.Parent.Parent and Players:GetPlayerFromCharacter(Target.Parent.Parent))

        if Player and Player ~= LocalPlayer then
            setOSCursor(Player.TeamColor == cachedTeamColor and "green" or "red")
        else
            setOSCursor("white")
        end
    end)
end

if isFirstRun then
    LocalPlayer.AncestryChanged:Connect(function()
        if LocalPlayer:IsDescendantOf(game) then return end
        pcall(function() UserInputService.MouseIconEnabled=true end)
        pcall(function() UserInputService.MouseIcon="" end)
        pcall(function() CW.IAPortable:Destroy() end)
        pcall(function() if CW.State.enforcerConn then CW.State.enforcerConn:Disconnect() end end)
        pcall(function() if CW.State.enableConn   then CW.State.enableConn:Disconnect()   end end)
        CW.ActiveFollowClones = {}
    end)
end
