-- Standalone entry point; module bodies below are kept in isolated scopes.
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

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local GuiService        = game:GetService("GuiService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()

local CW = getgenv().__CW_CORE_STATE
local isFirstRun = false

if not CW then
	isFirstRun = true
	CW = {
		Settings = {},
		Paths    = {},
		Assets   = {},
		ActiveFollowClones = {},
		State    = {
			cursorsReady     = false,
			currentCursorKey = nil,
			settingCursor    = false,
			lastTarget       = nil,
			enforcerConn     = nil,
			enableConn       = nil,
			cachedTeamColor  = LocalPlayer.TeamColor,
			mouseX           = 0,
			mouseY           = 0,
		},
	}
	getgenv().__CW_CORE_STATE = CW
end

CW.IsFirstRun  = isFirstRun
CW.LocalPlayer = LocalPlayer
CW.Mouse       = Mouse

if CW.Debug == nil then CW.Debug = true end
CW.Debug = boolOr(_cfg.DEBUG, CW.Debug)

function CW.Log(msg)
	if CW.Debug then
		print("[CW] " .. msg)
	end
end

function CW.Warn(msg)
	warn("[CW] " .. msg)
end

CW.Log(isFirstRun and "First run — initializing." or "Re-run detected — updating settings only.")

CW.Paths.CURSOR_FILE    = _cfg.CURSOR_FILE    or "CycleWare/Assets/cursor.png"
CW.Paths.HITMARKER_FILE = _cfg.HITMARKER_FILE or "CycleWare/Assets/hitmarker.png"
CW.Paths.SOUND_FILE     = _cfg.SOUND_FILE     or "CycleWare/Assets/sound.mp3"

CW.Paths.CURSOR_ROOT            = "CycleWare"
CW.Paths.CURSOR_FOLDER          = "CycleWare/Assets"
CW.Paths.CACHE_FOLDER           = CW.Paths.CURSOR_FOLDER.."/Cache"
CW.Paths.TINTED_FOLDER          = CW.Paths.CACHE_FOLDER.."/Tinted"
CW.Paths.HITMARKER_CACHE_FOLDER = CW.Paths.CACHE_FOLDER.."/HitmarkerCache"
CW.Paths.SOUND_CACHE_FOLDER     = CW.Paths.CACHE_FOLDER.."/SoundCache"

CW.Paths.CURSOR_SIG_FILE    = CW.Paths.CACHE_FOLDER.."/cursor.sig"
CW.Paths.HITMARKER_SIG_FILE = CW.Paths.CACHE_FOLDER.."/hitmarker.sig"
CW.Paths.SOUND_SIG_FILE     = CW.Paths.CACHE_FOLDER.."/sound.sig"

CW.Settings.HITMARKER_SIZE             = numOr(_cfg.HITMARKER_SIZE, 50, 1)
CW.Settings.SOUND_VOLUME               = numOr(_cfg.SOUND_VOLUME, 1, 0)
CW.Settings.CURSOR_TARGET_SIZE         = numOr(_cfg.CURSOR_TARGET_SIZE, 82, 1)
CW.Settings.HITMARKER_VISIBLE_DURATION = numOr(_cfg.HITMARKER_VISIBLE_DURATION, 0.05, 0)
CW.Settings.HITMARKER_FADEOUT_DURATION = numOr(_cfg.HITMARKER_FADEOUT_DURATION, 0.15, 0)

CW.Settings.HITMARKER_RANDOM_ROTATION = boolOr(_cfg.HITMARKER_RANDOM_ROTATION, true)
CW.Settings.HITMARKER_FOLLOW_MOUSE    = boolOr(_cfg.HITMARKER_FOLLOW_MOUSE, true)
CW.Settings.HITMARKER_FADEOUT         = boolOr(_cfg.HITMARKER_FADEOUT, true)

CW.Paths.TEXTURE_FILE = _cfg.TEXTURE_FILE or "CycleWare/Assets/texture.png"

CW.resolveAssetPath = function(input)
	if not input then return nil end

	local trimmed = tostring(input):match("^%s*(.-)%s*$")
	if trimmed == "" then return nil end

	if trimmed:find("/") or trimmed:find("\\") then
		return trimmed
	end

	return CW.Paths.CURSOR_FOLDER .. "/" .. trimmed
end

local SETTINGS_FILE = CW.Paths.CACHE_FOLDER .. "/ui_settings.json"
local settingsFileExists = false
pcall(function()
	settingsFileExists = isfile(SETTINGS_FILE)
end)

if settingsFileExists then
	local ok, raw = pcall(readfile, SETTINGS_FILE)

	if ok then
		local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)

		if ok2 and type(data) == "table" then
			local function readPath(flag)
				local entry = data[flag]

				if type(entry) == "table" and entry[2] then
					return CW.resolveAssetPath(entry[2])
				end

				return nil
			end

			local hm  = readPath("Hitmarker_FilePath")
			local cur = readPath("Cursor_FilePath")
			local tex = readPath("Texture_FilePath")
			local snd = readPath("Sound_FilePath")

			if hm then
				CW.Paths.HITMARKER_FILE = hm
			end

			if cur then
				CW.Paths.CURSOR_FILE = cur
			end

			if tex then
				CW.Paths.TEXTURE_FILE = tex
			end

			if snd then
				CW.Paths.SOUND_FILE = snd
			end

			CW.Log("Loaded saved asset filenames from ui_settings.json")
		end
	end
end

if not CW.ShootEvent then
	CW.ShootEvent = ReplicatedStorage:WaitForChild("GunRemotes"):WaitForChild("ShootEvent")
end

do
	local loc = UserInputService:GetMouseLocation()
	CW.State.mouseX, CW.State.mouseY = loc.X, loc.Y
end

if isFirstRun then
	LocalPlayer:GetPropertyChangedSignal("TeamColor"):Connect(function()
		CW.State.cachedTeamColor = LocalPlayer.TeamColor
	end)

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		local inset = GuiService:GetGuiInset()

		CW.State.mouseX = input.Position.X + inset.X
		CW.State.mouseY = input.Position.Y + inset.Y

		for clone in pairs(CW.ActiveFollowClones) do
			local ok = pcall(function()
				clone.Position = UDim2.fromOffset(
					CW.State.mouseX,
					CW.State.mouseY
				)
			end)

			if not ok then
				CW.ActiveFollowClones[clone] = nil
			end
		end
	end)
end

do
-- Cache.lua
local CW = getgenv().__CW_CORE_STATE

local sbyte   = string.byte
local sformat = string.format
local band    = bit32.band
local bxor    = bit32.bxor
local rshift  = bit32.rshift

local ALL_FOLDERS = {
	CW.Paths.CURSOR_ROOT, CW.Paths.CURSOR_FOLDER, CW.Paths.CACHE_FOLDER,
	CW.Paths.TINTED_FOLDER, CW.Paths.HITMARKER_CACHE_FOLDER, CW.Paths.SOUND_CACHE_FOLDER,
}

function CW.ensureFolders()
	for _, folder in ipairs(ALL_FOLDERS) do
		if not isfolder(folder) then
			pcall(makefolder, folder)
		end
	end
end
CW.ensureFolders()

function CW.readSigFile(path)
	if not isfile(path) then return nil end
	local ok, data = pcall(readfile, path)
	if ok then return data end
	return nil
end

function CW.pruneOldFiles(folder, prefix, keepHash, label)
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
		CW.Log(sformat("Pruned %d stale %s file(s)", deleted, label))
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

function CW.crc32(s)
	local c = 0xFFFFFFFF
	for i = 1, #s do
		c = bxor(_crcT[band(bxor(c, sbyte(s, i)), 0xFF)], rshift(c, 8))
	end
	return bxor(c, 0xFFFFFFFF)
end

function CW.computeFileSignature(path, prefix, extra)
	extra = extra or ""
	if not isfile(path) then
		return prefix..":none"..extra, nil
	end
	local ok, data = pcall(readfile, path)
	if not ok or not data then
		return prefix..":readfail"..extra, nil
	end
	return prefix..":"..CW.crc32(data)..extra, data
end

function CW.loadCachedAsset(cfg)
	if not isfile(cfg.file) then
		CW.Log(cfg.label .. " file not found — place one at " .. cfg.file)
		return nil, "missing"
	end

	local sig, data  = CW.computeFileSignature(cfg.file, cfg.prefix)
	local sigHash     = sformat("%08x", CW.crc32(sig))
	local storedHash  = CW.readSigFile(cfg.sigFile)
	local cachedPath  = cfg.cacheFolder.."/"..cfg.prefix.."_"..sigHash..cfg.ext

	local unchanged = storedHash == sigHash and isfile(cachedPath)
	if cfg.isUnchanged then
		unchanged = unchanged and cfg.isUnchanged()
	end
	
	if unchanged then
		CW.Log(cfg.label .. " unchanged — keeping current asset")
		return nil, nil
	end

	if storedHash and storedHash ~= sigHash then
		CW.Log(cfg.label .. " changed since last run — reloading new file")
	else
		CW.Log(cfg.label .. " " .. (CW.IsFirstRun and "loaded" or "reloaded") .. " from file.")
	end

	if not data then
		CW.Warn("readfile failed for " .. cfg.label)
		return nil, "error"
	end
	writefile(cachedPath, data)

	local ok, asset = pcall(getcustomasset, cachedPath)
	if not ok or not asset then
		CW.Warn("getcustomasset failed for " .. cfg.label)
		return nil, "error"
	end

	writefile(cfg.sigFile, sigHash)
	CW.pruneOldFiles(cfg.cacheFolder, cfg.prefix.."_", sigHash, cfg.label)
	return asset, nil
end
end


do
-- PNG.lua
local CW = getgenv().__CW_CORE_STATE

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
	return u32be(#data)..p..u32be(CW.crc32(p))
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

function CW.encodePNG(px, w, h)
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

function CW.parsePNG(data)
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

function CW.resizePixels(px, w, h, tw, th)
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
	CW.Log(sformat("Resized to %d×%d", tw, th))
	return out, tw, th
end

function CW.applyTint(px, w, h, tR, tG, tB)
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
end


do
-- Cursor.lua
local CW = getgenv().__CW_CORE_STATE

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local LocalPlayer = CW.LocalPlayer
local Mouse       = CW.Mouse

local sformat = string.format

local TINT_VARIANTS = {
	{key="red",   tR=255, tG=56,  tB=56},
	{key="green", tR=56,  tG=255, tB=56},
}

local function computeCursorSourceSignature()
	local tintSig = ""
	for _, v in ipairs(TINT_VARIANTS) do
		tintSig = tintSig.."|"..v.key..":"..v.tR..","..v.tG..","..v.tB
	end
	return CW.computeFileSignature(
		CW.Paths.CURSOR_FILE, "cur",
		"|size:"..tostring(CW.Settings.CURSOR_TARGET_SIZE)..tintSig
	)
end

local function buildCursorFiles(sigHash)
	return {
		white = CW.Paths.TINTED_FOLDER.."/cur_white_"..sigHash..".png",
		red   = CW.Paths.TINTED_FOLDER.."/cur_red_"..sigHash..".png",
		green = CW.Paths.TINTED_FOLDER.."/cur_green_"..sigHash..".png",
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

local function loadCachedCursorAssets(files)
	CW.Assets.white = getcustomasset(files.white)
	CW.Assets.red   = getcustomasset(files.red)
	CW.Assets.green = getcustomasset(files.green)
end

local function reloadCursorFromSource(sigHash, data)
	if not data then
		CW.Warn("No valid cursor image found at "..CW.Paths.CURSOR_FILE.." — place a PNG there and re-run.")
		return false
	end
	local ok2, px, w, h = pcall(CW.parsePNG, data)
	if not ok2 then
		CW.Warn("parsePNG failed: "..tostring(px))
		return false
	end
	CW.Log(sformat("Loaded new cursor.png (%d×%d)", w, h))

	local targetSize = CW.Settings.CURSOR_TARGET_SIZE
	if targetSize then
		px, w, h = CW.resizePixels(px, w, h, targetSize, targetSize)
	end

	local files = buildCursorFiles(sigHash)

	writefile(files.white, CW.encodePNG(px, w, h))
	CW.Assets.white = getcustomasset(files.white)

	for _, v in ipairs(TINT_VARIANTS) do
		writefile(files[v.key], CW.encodePNG(CW.applyTint(px, w, h, v.tR, v.tG, v.tB), w, h))
		CW.Assets[v.key] = getcustomasset(files[v.key])
	end

	writefile(CW.Paths.CURSOR_SIG_FILE, sigHash)
	CW.pruneOldFiles(CW.Paths.TINTED_FOLDER, "cur_", sigHash, "cursor")
	return true
end

local function generateCursors()
	local currentSig, data = computeCursorSourceSignature()
	local sigHash    = sformat("%08x", CW.crc32(currentSig))
	local storedHash = CW.readSigFile(CW.Paths.CURSOR_SIG_FILE)

	local files = buildCursorFiles(sigHash)
	local filesExist = isfile(files.white) and isfile(files.red) and isfile(files.green)

	if filesExist and storedHash == sigHash then
		CW.Log("cursor.png unchanged — tinted variants match, using cache")
		loadCachedCursorAssets(files)
		activateCursors()
		CW.Log("OS cursor active (cached).")
		return
	end

	if storedHash and storedHash ~= sigHash then
		CW.Log("cursor.png changed since last run — reloading original and regenerating tints")
	elseif not filesExist then
		CW.Log("Tinted cache incomplete — regenerating from current cursor.png")
	end

	if reloadCursorFromSource(sigHash, data) then
		activateCursors()
		CW.Log("OS cursor active (regenerated from new original).")
	end
end

CW.reloadCursor = generateCursors
task.spawn(generateCursors)

if CW.IsFirstRun then
	RunService.PreRender:Connect(function()
		if not CW.State.cursorsReady then return end
		local Target = Mouse.Target
		if Target == CW.State.lastTarget then return end
		CW.State.lastTarget = Target
		if not Target or not Target.Parent then setOSCursor("white"); return end

		local Player = Players:GetPlayerFromCharacter(Target.Parent)
			or (Target.Parent.Parent and Players:GetPlayerFromCharacter(Target.Parent.Parent))

		if Player and Player ~= LocalPlayer then
			setOSCursor(Player.TeamColor == CW.State.cachedTeamColor and "green" or "red")
		else
			setOSCursor("white")
		end
	end)
end
end


do
-- Hitmarker.lua
local CW = getgenv().__CW_CORE_STATE

if CW.IsFirstRun then
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

local function reloadHitmarker()
	local asset = CW.loadCachedAsset({
		file        = CW.Paths.HITMARKER_FILE,
		sigFile     = CW.Paths.HITMARKER_SIG_FILE,
		cacheFolder = CW.Paths.HITMARKER_CACHE_FOLDER,
		prefix      = "hm",
		ext         = ".png",
		label       = "hitmarker.png",
		isUnchanged = function() return CW.HMTemplate.Image ~= "" end,
	})
	if asset then
		CW.HMTemplate.Image = asset
	end
end

CW.reloadHitmarkerAsset = reloadHitmarker
reloadHitmarker()
end


do
-- Sound.lua
local CW = getgenv().__CW_CORE_STATE

local SoundService = game:GetService("SoundService")
local Debris       = game:GetService("Debris")

local function reloadSound()
	local asset, failReason = CW.loadCachedAsset({
		file        = CW.Paths.SOUND_FILE,
		sigFile     = CW.Paths.SOUND_SIG_FILE,
		cacheFolder = CW.Paths.SOUND_CACHE_FOLDER,
		prefix      = "snd",
		ext         = ".mp3",
		label       = "sound.mp3",
		isUnchanged = function() return CW.Settings.SOUND_ID ~= nil end,
	})
	if asset then
		CW.Settings.SOUND_ID = asset
	elseif failReason == "missing" or failReason == "error" then
		CW.Settings.SOUND_ID = nil
	end
end

CW.reloadSoundAsset = reloadSound
reloadSound()

function CW.playHitSound()
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
end


do
-- Texture.lua
local CW = getgenv().__CW_CORE_STATE

local Players     = game:GetService("Players")
local LocalPlayer = CW.LocalPlayer

local _cfg = getgenv().CW_CONFIG or {}

CW.Paths.TEXTURE_FILE         = CW.Paths.TEXTURE_FILE or _cfg.TEXTURE_FILE or "CycleWare/Assets/texture.png"
CW.Paths.TEXTURE_CACHE_FOLDER = CW.Paths.CACHE_FOLDER.."/TextureCache"
CW.Paths.TEXTURE_SIG_FILE     = CW.Paths.CACHE_FOLDER.."/texture.sig"

if not isfolder(CW.Paths.TEXTURE_CACHE_FOLDER) then
	pcall(makefolder, CW.Paths.TEXTURE_CACHE_FOLDER)
end

local WEAPON_MESHES = _cfg.WEAPON_MESHES or {
	["M9"]            = "Meshes/M9_3",
	["M4A1"]          = "Meshes/m4_7",
	["Remington 870"] = "Meshes/r870_2",
	["Revolver"]      = "Meshes/revolver (3)",
	["MP5"]           = "GunMesh",
	["AK-47"]         = "Meshes/AK47_7",
}

local CUSTOM_MESH_WEAPONS = _cfg.CUSTOM_MESH_WEAPONS or {
	["FAL"] = {
		meshId      = "rbxassetid://90772329772088",
		meshName    = "FAL/Meshes",
		removeNames = { ["Smooth Block Model"] = true, ["Black"] = true },
		offset      = Vector3.new(0.05, 0.2, -0.55),
		rotation    = Vector3.new(0, 90, 0),
		size        = Vector3.new(0.4, 0.4, 0.4),
	},
	["M700"] = {
		meshId      = "rbxassetid://109235772617313",
		meshName    = "M700/Meshes",
		removeNames = { ["Smooth Block Model"] = true },
		offset      = Vector3.new(0, 0.43, -0.8),
		rotation    = Vector3.new(0, 90, 0),
		size        = Vector3.new(1, 1, 1),
	},
}

local function normalizeKey(s)
	return (s:gsub("%W", "")):lower()
end

local WEAPON_LIST = {}
local SEEN_WEAPONS = {}
for weaponName in pairs(WEAPON_MESHES) do
	if not SEEN_WEAPONS[weaponName] then
		SEEN_WEAPONS[weaponName] = true
		table.insert(WEAPON_LIST, weaponName)
	end
end
for weaponName in pairs(CUSTOM_MESH_WEAPONS) do
	if not SEEN_WEAPONS[weaponName] then
		SEEN_WEAPONS[weaponName] = true
		table.insert(WEAPON_LIST, weaponName)
	end
end
table.sort(WEAPON_LIST)

CW.WeaponList          = WEAPON_LIST
CW.normalizeTextureKey = normalizeKey
CW.Assets.weaponTextures = nil
CW.Settings.WeaponTextureFiles = nil
CW.Settings.WeaponTextureFilesByKey = nil

local function reloadGenericTexture()
	local asset, failReason = CW.loadCachedAsset({
		file        = CW.Paths.TEXTURE_FILE,
		sigFile     = CW.Paths.TEXTURE_SIG_FILE,
		cacheFolder = CW.Paths.TEXTURE_CACHE_FOLDER,
		prefix      = "tex",
		ext         = ".png",
		label       = "generic texture ("..CW.Paths.TEXTURE_FILE..")",
		isUnchanged = function() return CW.Assets.weaponTexture ~= nil end,
	})
	if asset then
		CW.Assets.weaponTexture = asset
	elseif failReason == "missing" or failReason == "error" then
		CW.Assets.weaponTexture = nil
	end
end

local function buildCustomMesh(tool, cfg)
	for _, desc in ipairs(tool:GetDescendants()) do
		if cfg.removeNames[desc.Name] then
			desc:Destroy()
		end
	end

	local old = tool:FindFirstChild(cfg.meshName)
	if old then old:Destroy() end

	local handle = tool:FindFirstChild("Handle")
	local mesh = Instance.new("MeshPart")
	mesh.Name       = cfg.meshName
	mesh.MeshId     = cfg.meshId
	mesh.Material   = Enum.Material.SmoothPlastic
	mesh.Size       = cfg.size
	mesh.Anchored   = false
	mesh.CanCollide = false
	mesh.CanQuery   = false
	mesh.CanTouch   = false
	mesh.Massless   = true

	if handle then
		mesh.CFrame = handle.CFrame
			* CFrame.new(cfg.offset)
			* CFrame.Angles(math.rad(cfg.rotation.X), math.rad(cfg.rotation.Y), math.rad(cfg.rotation.Z))
		mesh.Parent = tool
		local weld  = Instance.new("WeldConstraint")
		weld.Part0  = handle
		weld.Part1  = mesh
		weld.Parent = mesh
	else
		mesh.Parent = tool
	end

	CW.Log("Custom mesh built for "..tool.Name)
	return mesh
end

local function applyTexture(tool)
	if not tool:IsA("Tool") then return end
	local textureId = CW.Assets.weaponTexture
	if not textureId then return end

	local customCfg = CUSTOM_MESH_WEAPONS[tool.Name]
	if customCfg then
		local mesh = buildCustomMesh(tool, customCfg)
		mesh.TextureID = textureId
		return
	end

	local meshName = WEAPON_MESHES[tool.Name]
	if not meshName then return end

	local mesh = tool:FindFirstChild(meshName, true)
	if mesh and mesh:IsA("MeshPart") then
		mesh.TextureID = textureId
	end
end
CW.applyWeaponTexture = applyTexture

local function applyToContainer(container)
	for _, child in ipairs(container:GetChildren()) do
		applyTexture(child)
	end
end

local function monitor(container)
	container.ChildAdded:Connect(function(child)
		task.wait(0.1)
		applyTexture(child)
	end)
	applyToContainer(container)
end

local function reloadTexturesAndApply()
	reloadGenericTexture()

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then applyToContainer(backpack) end
	if LocalPlayer.Character then applyToContainer(LocalPlayer.Character) end
end
CW.reloadTextures = reloadTexturesAndApply
reloadTexturesAndApply()

if CW.IsFirstRun then
	monitor(LocalPlayer:WaitForChild("Backpack"))

	LocalPlayer.CharacterAdded:Connect(function(character)
		monitor(character)
	end)

	if LocalPlayer.Character then
		monitor(LocalPlayer.Character)
	end
end
end


do
-- Tracers.lua
local CW = getgenv().__CW_CORE_STATE

local Workspace         = game:GetService("Workspace")
local Debris            = game:GetService("Debris")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = CW.LocalPlayer

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

CW.Settings.CUSTOM_BULLET_TRACERS  = boolOr(_cfg.customBulletTracers, false)
CW.Settings.TRACER_COLOR           = _cfg.tracerColor or Color3.fromRGB(170, 0, 255)
CW.Settings.TRACER_GLOW_COLOR      = _cfg.glowColor or Color3.fromRGB(200, 100, 255)
CW.Settings.TRACER_WIDTH           = numOr(_cfg.tracerWidth, 0.05, 0.01)
CW.Settings.TRACER_LIFETIME        = numOr(_cfg.tracerLifetime, 0.05, 0.01)

CW.Settings.TRACER_APPLY_TO_OTHERS = boolOr(_cfg.applyToOthers, false)

local function isLocalPlayerShot()
	local char = LocalPlayer.Character
	if not char then return false end
	local tool = char:FindFirstChildOfClass("Tool")
	if not tool then return false end
	return tool:GetAttribute("Local_IsShooting") == true
end

local function createEnergyTracer(startPos, endPos)
	local distance = (startPos - endPos).Magnitude
	local midpoint  = (startPos + endPos) / 2
	local width = CW.Settings.TRACER_WIDTH
	local life  = CW.Settings.TRACER_LIFETIME

	local core = Instance.new("Part")
	core.Anchored     = true
	core.CanCollide   = false
	core.CanQuery     = false
	core.CanTouch     = false
	core.Material     = Enum.Material.Neon
	core.Color        = CW.Settings.TRACER_COLOR
	core.Size         = Vector3.new(width, width, distance)
	core.CFrame       = CFrame.new(midpoint, endPos)
	core.Transparency = 0.1
	core.Parent       = Workspace.CurrentCamera

	local glow = Instance.new("Part")
	glow.Anchored     = true
	glow.CanCollide   = false
	glow.CanQuery     = false
	glow.CanTouch     = false
	glow.Material     = Enum.Material.Neon
	glow.Color        = CW.Settings.TRACER_GLOW_COLOR
	glow.Size         = Vector3.new(width * 2, width * 2, distance)
	glow.CFrame       = core.CFrame
	glow.Transparency = 0.6
	glow.Parent       = Workspace.CurrentCamera

	local light = Instance.new("PointLight")
	light.Color      = CW.Settings.TRACER_COLOR
	light.Range      = 8
	light.Brightness = 2
	light.Parent     = core

	TweenService:Create(core, TweenInfo.new(life), { Transparency = 1 }):Play()
	TweenService:Create(glow, TweenInfo.new(life), { Transparency = 1 }):Play()

	Debris:AddItem(core, life)
	Debris:AddItem(glow, life)
end

if CW.IsFirstRun then
	local ok, TracersModule = pcall(function()
		return require(ReplicatedStorage.SharedModules.GunTracers)
	end)

	if ok and TracersModule then
		CW.TracersModule          = TracersModule
		CW._originalCreateBullet  = TracersModule.createBullet
		CW._originalCreateTaser   = TracersModule.createTaser
		CW._originalCreateSniper  = TracersModule.createSniper

		local function shouldUseCustom()
			if not CW.Settings.CUSTOM_BULLET_TRACERS then return false end
			if CW.Settings.TRACER_APPLY_TO_OTHERS then return true end
			return isLocalPlayerShot()
		end

		TracersModule.createBullet = function(startPos, endPos)
			if shouldUseCustom() then
				createEnergyTracer(startPos, endPos)
			else
				CW._originalCreateBullet(startPos, endPos)
			end
		end

		TracersModule.createTaser = function(startPos, endPos)
			if shouldUseCustom() then
				createEnergyTracer(startPos, endPos)
			else
				CW._originalCreateTaser(startPos, endPos)
			end
		end

		TracersModule.createSniper = function(startPos, endPos)
			if shouldUseCustom() then
				createEnergyTracer(startPos, endPos)
			else
				CW._originalCreateSniper(startPos, endPos)
			end
		end

		CW.Log("Tracer override installed.")
	else
		CW.Warn("GunTracers module not found — custom tracers disabled.")
	end
end
end


do
-- Hook.lua
local CW = getgenv().__CW_CORE_STATE

local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LocalPlayer = CW.LocalPlayer

if CW.IsFirstRun then
	CW.Bindable = Instance.new("BindableEvent")

	CW.Bindable.Event:Connect(function(bullets)
		if type(bullets) ~= "table" then return end

		local shotHit = false
		for _, bullet in pairs(bullets) do
			if type(bullet) == "table" then
				local hit = bullet[3]
				if typeof(hit) == "Instance" and hit:IsA("BasePart") and hit.Parent then
					local character = hit.Parent
					local player = Players:GetPlayerFromCharacter(character)
						or (character.Parent and Players:GetPlayerFromCharacter(character.Parent))
					if player and player ~= LocalPlayer and player.TeamColor ~= CW.State.cachedTeamColor then
						shotHit = true
						break
					end
				end
			end
		end
		if not shotHit then return end
		CW.playHitSound()

		local Clone = CW.HMTemplate:Clone()
		Clone.Size              = UDim2.new(0, CW.Settings.HITMARKER_SIZE, 0, CW.Settings.HITMARKER_SIZE)
		Clone.Position           = UDim2.fromOffset(CW.State.mouseX, CW.State.mouseY)
		Clone.Rotation           = CW.Settings.HITMARKER_RANDOM_ROTATION and math.random(0,90) or 0
		Clone.ImageTransparency = 0
		Clone.Parent             = CW.IAPortable

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
	OldNameCall = hookmetamethod(CW.ShootEvent, "__namecall", newcclosure(function(self, ...)
		if checkcaller() then return OldNameCall(self, ...) end
		if getnamecallmethod() == "FireServer" and self == CW.ShootEvent then
			CW.Bindable.Fire(CW.Bindable, ...)
		end
		return OldNameCall(self, ...)
	end))
end
end


do
-- Cleanup.lua
local CW = getgenv().__CW_CORE_STATE

local UserInputService = game:GetService("UserInputService")

local LocalPlayer = CW.LocalPlayer

if CW.IsFirstRun then
	LocalPlayer.AncestryChanged:Connect(function()
		if LocalPlayer:IsDescendantOf(game) then return end
		pcall(function() UserInputService.MouseIconEnabled=true end)
		pcall(function() UserInputService.MouseIcon="" end)
		pcall(function() CW.IAPortable:Destroy() end)
		pcall(function() if CW.State.enforcerConn then CW.State.enforcerConn:Disconnect() end end)
		pcall(function() if CW.State.enableConn   then CW.State.enableConn:Disconnect()   end end)
		pcall(function() if CW.State.sprintCharacterConn then CW.State.sprintCharacterConn:Disconnect() end end)
		pcall(function() if CW.State.chatToggleConn then CW.State.chatToggleConn:Disconnect() end end)
		pcall(function() if CW.State.ammoGuiConn then CW.State.ammoGuiConn:Disconnect() end end)
		pcall(function() if CW.State.ammoCharacterConn then CW.State.ammoCharacterConn:Disconnect() end end)
		pcall(function() CW.Settings.AUTO_RELOAD_ENABLED = false end)
		pcall(function() if CW.State.clearAmmoLabelWatchers then CW.State.clearAmmoLabelWatchers() end end)
		pcall(function() if CW.State.stopWeaponShootSoundOverrides then CW.State.stopWeaponShootSoundOverrides() end end)
		pcall(function()
			local contextActions = game:GetService("ContextActionService")
			contextActions:UnbindAction("CycleWareSprintToggle")
			contextActions:UnbindAction("CycleWareProtectSprint")
		end)
		CW.ActiveFollowClones = {}
	end)
end
end


do
-- UI.lua
local uiOk, uiError = pcall(function()
local CW = getgenv().__CW_CORE_STATE
assert(CW, "CycleWare must be loaded before UI.lua")

local HttpService = game:GetService("HttpService")

local Elastic = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/53845052/roblox-uis/refs/heads/main/ElasticLib.lua"
))()

local Icons = {
	Combat  = "rbxassetid://10734950020",
	Visuals = "rbxassetid://10709790948",
	Weapons = "rbxassetid://83313626819084",
	Sounds  = "rbxassetid://10734896206",
	Tracers = "rbxassetid://94654949230438",
}

Elastic:SetWindowKeybind(nil)

local Window = Elastic:Window()

local resolveAssetPath = CW.resolveAssetPath

local function filenameOnly(fullPath)
	return fullPath:match("([^/\\]+)$") or fullPath
end


local EffectsTab = Window:Tab({
	Title = "Effects",
	Icon = Icons.Combat
})

local function applyHitmarkerFile(value)
	local resolved = resolveAssetPath(value)
	if resolved then
		CW.Paths.HITMARKER_FILE = resolved
		if CW.reloadHitmarkerAsset then CW.reloadHitmarkerAsset() end
	end
end

local function applyHitmarkerSize(v)
	CW.Settings.HITMARKER_SIZE = v

	if CW.HMTemplate then
		CW.HMTemplate.Size = UDim2.new(0, v, 0, v)
	end
end

local function applyHitmarkerRandomRotation(s)
	CW.Settings.HITMARKER_RANDOM_ROTATION = s
end

local function applyHitmarkerFollowMouse(s)
	CW.Settings.HITMARKER_FOLLOW_MOUSE = s
end

local function applyHitmarkerVisibleDuration(v)
	CW.Settings.HITMARKER_VISIBLE_DURATION = v
end

local function applyHitmarkerFadeout(s)
	CW.Settings.HITMARKER_FADEOUT = s
end

local function applyHitmarkerFadeoutDuration(v)
	CW.Settings.HITMARKER_FADEOUT_DURATION = v
end

EffectsTab:Textbox({
	Title = "Hitmarker File",
	Default = CW.Paths.HITMARKER_FILE,
	Placeholder = filenameOnly(CW.Paths.HITMARKER_FILE),
	Flag = "Hitmarker_FilePath",
	Callback = applyHitmarkerFile,
})

EffectsTab:Slider({
	Title = "Hitmarker Size",
	Min = 8,
	Max = 200,
	Default = CW.Settings.HITMARKER_SIZE,
	Suffix = "px",
	Flag = "Hitmarker_Size",
	Callback = applyHitmarkerSize,
})

EffectsTab:Toggle({
	Title = "Random Rotation",
	Default = CW.Settings.HITMARKER_RANDOM_ROTATION,
	Flag = "Hitmarker_RandomRotation",
	Callback = applyHitmarkerRandomRotation,
})

EffectsTab:Toggle({
	Title = "Follow Mouse",
	Default = CW.Settings.HITMARKER_FOLLOW_MOUSE,
	Flag = "Hitmarker_FollowMouse",
	Callback = applyHitmarkerFollowMouse,
})

EffectsTab:Slider({
	Title = "Visible Duration",
	Min = 0,
	Max = 1,
	Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
	Decimal = 2,
	Suffix = "s",
	Flag = "Hitmarker_VisibleDuration",
	Callback = applyHitmarkerVisibleDuration,
})

EffectsTab:Toggle({
	Title = "Fadeout",
	Default = CW.Settings.HITMARKER_FADEOUT,
	Flag = "Hitmarker_Fadeout",
	Callback = applyHitmarkerFadeout,
})

EffectsTab:Slider({
	Title = "Fadeout Duration",
	Min = 0,
	Max = 1,
	Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
	Decimal = 2,
	Suffix = "s",
	Flag = "Hitmarker_FadeoutDuration",
	Callback = applyHitmarkerFadeoutDuration,
})

local VisualsTab = Window:Tab({
	Title = "Visuals",
	Icon = Icons.Visuals
})

local function applyCursorFile(value)
	local resolved = resolveAssetPath(value)
	if resolved then
		CW.Paths.CURSOR_FILE = resolved
		if CW.reloadCursor then CW.reloadCursor() end
	end
end

local cursorSizeDebounceThread = nil

local function applyCursorSize(v, skipDebounce)
	CW.Settings.CURSOR_TARGET_SIZE = v

	if cursorSizeDebounceThread then
		task.cancel(cursorSizeDebounceThread)
		cursorSizeDebounceThread = nil
	end

	if skipDebounce then
		if CW.reloadCursor then
			CW.reloadCursor()
		end

		return
	end

	cursorSizeDebounceThread = task.delay(2, function()
		cursorSizeDebounceThread = nil

		if CW.reloadCursor then
			CW.reloadCursor()
		end
	end)
end

VisualsTab:Textbox({
	Title = "Cursor File",
	Default = CW.Paths.CURSOR_FILE,
	Placeholder = filenameOnly(CW.Paths.CURSOR_FILE),
	Flag = "Cursor_FilePath",
	Callback = applyCursorFile,
})

VisualsTab:Slider({
	Title = "Cursor Size",
	Min = 16,
	Max = 256,
	Default = CW.Settings.CURSOR_TARGET_SIZE,
	Suffix = "px",
	Flag = "Cursor_Size",
	Callback = function(v)
		applyCursorSize(v, false)
	end,
})

local function applyTextureFile(value)
	local resolved = resolveAssetPath(value)
	if resolved then
		CW.Paths.TEXTURE_FILE = resolved
		if CW.reloadTextures then CW.reloadTextures() end
	end
end

VisualsTab:Textbox({
	Title = "Shared Weapon Texture",
	Default = CW.Paths.TEXTURE_FILE,
	Placeholder = filenameOnly(CW.Paths.TEXTURE_FILE),
	Flag = "Texture_FilePath",
	Callback = applyTextureFile,
})
local SoundsTab = Window:Tab({
	Title = "Audio",
	Icon = Icons.Sounds
})

local function applySoundFile(value)
	local resolved = resolveAssetPath(value)
	if resolved then
		CW.Paths.SOUND_FILE = resolved
		if CW.reloadSoundAsset then CW.reloadSoundAsset() end
	end
end

local function applySoundVolume(v)
	CW.Settings.SOUND_VOLUME = v
end

SoundsTab:Textbox({
	Title = "Hit Sound File",
	Default = CW.Paths.SOUND_FILE,
	Placeholder = filenameOnly(CW.Paths.SOUND_FILE),
	Flag = "Sound_FilePath",
	Callback = applySoundFile,
})

SoundsTab:Slider({
	Title = "Hit Sound Volume",
	Min = 0,
	Max = 2,
	Default = CW.Settings.SOUND_VOLUME,
	Decimal = 2,
	Suffix = "x",
	Flag = "Sound_Volume",
	Callback = applySoundVolume,
})

local configuredWeaponSounds = CW.Settings.WEAPON_SHOOT_SOUND_OVERRIDES
	or _cfg.WEAPON_SHOOT_SOUNDS
CW.Settings.WEAPON_SHOOT_SOUND_OVERRIDES = type(configuredWeaponSounds) == "table"
	and configuredWeaponSounds or {}
if CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED == nil then
	CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED = _cfg.WEAPON_SOUND_OVERRIDE_ENABLED ~= false
end
if CW.Settings.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS == nil then
	CW.Settings.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS = _cfg.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS == true
end

if CW.State.stopWeaponShootSoundOverrides then
	pcall(CW.State.stopWeaponShootSoundOverrides)
end

local weaponSoundOverrides = CW.Settings.WEAPON_SHOOT_SOUND_OVERRIDES
local activeWeaponSounds = setmetatable({}, { __mode = "k" })
local watchedSoundContainers = setmetatable({}, { __mode = "k" })
local weaponSoundPlayerConnections = {}
local weaponSoundGlobalConnections = {}
local weaponSoundRefreshScheduled = false
local weaponSoundRefreshGeneration = 0

local function disconnectList(connections)
	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(connections)
end

local function restoreWeaponSound(sound)
	local data = activeWeaponSounds[sound]
	if not data then return end
	activeWeaponSounds[sound] = nil
	if data.connection then
		pcall(function() data.connection:Disconnect() end)
	end
	if sound.Parent then
		pcall(function() sound.SoundId = data.originalId end)
	end
end

local function stopWeaponShootSoundOverrides()
	weaponSoundRefreshGeneration = weaponSoundRefreshGeneration + 1
	weaponSoundRefreshScheduled = false
	disconnectList(weaponSoundGlobalConnections)
	for _, connections in pairs(weaponSoundPlayerConnections) do
		disconnectList(connections)
	end
	table.clear(weaponSoundPlayerConnections)
	for container, data in pairs(watchedSoundContainers) do
		disconnectList(data.connections)
		watchedSoundContainers[container] = nil
	end
	for sound in pairs(activeWeaponSounds) do
		restoreWeaponSound(sound)
	end
end
CW.State.stopWeaponShootSoundOverrides = stopWeaponShootSoundOverrides

local function findSoundTool(sound)
	local ancestor = sound.Parent
	while ancestor do
		if ancestor:IsA("Tool") then return ancestor end
		ancestor = ancestor.Parent
	end
	return nil
end

local function applyWeaponSound(sound, targetId, tool, player, container)
	local data = activeWeaponSounds[sound]
	if not data then
		data = {
			originalId = sound.SoundId,
			tool = tool,
			player = player,
			container = container,
			targetId = targetId,
		}
		activeWeaponSounds[sound] = data
		local ok, connection = pcall(function()
			return sound:GetPropertyChangedSignal("SoundId"):Connect(function()
				local current = activeWeaponSounds[sound]
				if current and sound.Parent and sound.SoundId ~= current.targetId then
					pcall(function() sound.SoundId = current.targetId end)
				end
			end)
		end)
		if ok then data.connection = connection end
	else
		data.tool = tool
		data.player = player
		data.container = container
		data.targetId = targetId
	end

	if sound.SoundId ~= targetId then
		pcall(function() sound.SoundId = targetId end)
	end
end

local function applyWeaponSoundToTool(tool, player, container)
	if not tool:IsA("Tool") then return end
	if not CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED then return end
	if player ~= LocalPlayer and not CW.Settings.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS then return end

	local targetId = weaponSoundOverrides[tool.Name]
	if type(targetId) ~= "string" or targetId == "" then return end
	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("Sound") and descendant.Name == "ShootSound" then
			applyWeaponSound(descendant, targetId, tool, player, container)
		end
	end
end

local function unwatchSoundContainer(container)
	local data = watchedSoundContainers[container]
	if not data then return end
	watchedSoundContainers[container] = nil
	disconnectList(data.connections)
	for sound, soundData in pairs(activeWeaponSounds) do
		if soundData.container == container then
			restoreWeaponSound(sound)
		end
	end
end

local function watchSoundContainer(container, player)
	if watchedSoundContainers[container] then return end
	local data = { player = player, connections = {} }
	watchedSoundContainers[container] = data

	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") then
			applyWeaponSoundToTool(child, player, container)
		end
	end

	table.insert(data.connections, container.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("Tool") then
			task.defer(applyWeaponSoundToTool, descendant, player, container)
		elseif descendant:IsA("Sound") and descendant.Name == "ShootSound" then
			local tool = findSoundTool(descendant)
			if tool then applyWeaponSoundToTool(tool, player, container) end
		end
	end))

	table.insert(data.connections, container.DescendantRemoving:Connect(function(descendant)
		if descendant:IsA("Sound") then
			restoreWeaponSound(descendant)
		elseif descendant:IsA("Tool") then
			for sound, soundData in pairs(activeWeaponSounds) do
				if soundData.tool == descendant then restoreWeaponSound(sound) end
			end
		end
	end))
end

local function removeWeaponSoundPlayer(player)
	local connections = weaponSoundPlayerConnections[player]
	if connections then
		disconnectList(connections)
		weaponSoundPlayerConnections[player] = nil
	end
	for container, data in pairs(watchedSoundContainers) do
		if data.player == player then unwatchSoundContainer(container) end
	end
end

local function watchWeaponSoundPlayer(player)
	if weaponSoundPlayerConnections[player] then return end
	local connections = {}
	weaponSoundPlayerConnections[player] = connections

	table.insert(connections, player.CharacterAdded:Connect(function(character)
		watchSoundContainer(character, player)
	end))
	table.insert(connections, player.CharacterRemoving:Connect(unwatchSoundContainer))
	if player.Character then
		watchSoundContainer(player.Character, player)
	end

	if player == LocalPlayer then
		local backpack = player:FindFirstChildOfClass("Backpack")
		if backpack then watchSoundContainer(backpack, player) end
		table.insert(connections, player.ChildAdded:Connect(function(child)
			if child:IsA("Backpack") then watchSoundContainer(child, player) end
		end))
	end
end

local function refreshWeaponShootSoundOverrides()
	stopWeaponShootSoundOverrides()
	if not CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED then return end
	for _, player in ipairs(Players:GetPlayers()) do
		watchWeaponSoundPlayer(player)
	end
	table.insert(weaponSoundGlobalConnections, Players.PlayerAdded:Connect(watchWeaponSoundPlayer))
	table.insert(weaponSoundGlobalConnections, Players.PlayerRemoving:Connect(removeWeaponSoundPlayer))
end

local function scheduleWeaponShootSoundRefresh()
	if weaponSoundRefreshScheduled then return end
	weaponSoundRefreshScheduled = true
	local generation = weaponSoundRefreshGeneration
	task.defer(function()
		if generation ~= weaponSoundRefreshGeneration then return end
		weaponSoundRefreshScheduled = false
		refreshWeaponShootSoundOverrides()
	end)
end

local function normalizeWeaponSoundId(value)
	local trimmed = tostring(value or ""):match("^%s*(.-)%s*$")
	if trimmed == "" then return nil end
	local digits = trimmed:match("^(%d+)$") or trimmed:match("^rbxassetid://(%d+)$")
	if not digits or digits == "0" then return false end
	return "rbxassetid://" .. digits
end

for weapon, soundId in pairs(weaponSoundOverrides) do
	local normalizedId = normalizeWeaponSoundId(soundId)
	weaponSoundOverrides[weapon] = normalizedId ~= false and normalizedId or nil
end

local function setWeaponShootSound(weapon, value)
	local soundId = normalizeWeaponSoundId(value)
	if soundId == false then
		CW.Warn("Invalid sound asset ID for " .. weapon .. "; use a numeric ID or rbxassetid://<ID>.")
		weaponSoundOverrides[weapon] = nil
	else
		weaponSoundOverrides[weapon] = soundId
	end
	scheduleWeaponShootSoundRefresh()
end

local function applyWeaponSoundOverridesEnabled(enabled)
	CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED = enabled == true
	scheduleWeaponShootSoundRefresh()
end

local function applyWeaponSoundOverridesToOthers(enabled)
	CW.Settings.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS = enabled == true
	scheduleWeaponShootSoundRefresh()
end

SoundsTab:Toggle({
	Title = "Enable Weapon Sound Overrides",
	Default = CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED,
	Flag = "WeaponSoundOverrides_Enabled",
	Callback = applyWeaponSoundOverridesEnabled,
})

SoundsTab:Toggle({
	Title = "Apply to Other Players Locally",
	Default = CW.Settings.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS,
	Flag = "WeaponSoundOverrides_Others",
	Callback = applyWeaponSoundOverridesToOthers,
})

if CW.WeaponList then
	for _, weaponName in ipairs(CW.WeaponList) do
		local weapon = weaponName
		local key = CW.normalizeTextureKey and CW.normalizeTextureKey(weapon)
			or weapon:lower():gsub("%W", "")
		SoundsTab:Textbox({
			Title = weapon .. " Shoot Sound",
			Default = weaponSoundOverrides[weapon] or "",
			Placeholder = "Sound ID or rbxassetid://<ID>",
			Flag = "WeaponShootSound_" .. key,
			Callback = function(value)
				setWeaponShootSound(weapon, value)
			end,
		})
	end
end

local TracersTab = EffectsTab

local function applyTracerEnabled(s)
	CW.Settings.CUSTOM_BULLET_TRACERS = s
end

local function applyTracerColor(color)
	CW.Settings.TRACER_COLOR = color
end

local function applyTracerGlowColor(color)
	CW.Settings.TRACER_GLOW_COLOR = color
end

local function applyTracerWidth(v)
	CW.Settings.TRACER_WIDTH = v
end

local function applyTracerLifetime(v)
	CW.Settings.TRACER_LIFETIME = v
end

local function applyTracerApplyToOthers(s)
	CW.Settings.TRACER_APPLY_TO_OTHERS = s
end

TracersTab:Toggle({
	Title = "Custom Bullet Tracers",
	Default = CW.Settings.CUSTOM_BULLET_TRACERS,
	Flag = "Tracer_Enabled",
	Callback = applyTracerEnabled,
}):Colorpicker({
	Default = CW.Settings.TRACER_COLOR,
	Flag = "Tracer_Color",
	Callback = applyTracerColor,
})

TracersTab:Colorpicker({
	Title = "Glow Color",
	Default = CW.Settings.TRACER_GLOW_COLOR,
	Flag = "Tracer_GlowColor",
	Callback = applyTracerGlowColor,
})

TracersTab:Slider({
	Title = "Tracer Width",
	Min = 0.01,
	Max = 0.5,
	Default = CW.Settings.TRACER_WIDTH,
	Decimal = 2,
	Flag = "Tracer_Width",
	Callback = applyTracerWidth,
})

TracersTab:Slider({
	Title = "Tracer Lifetime",
	Min = 0.01,
	Max = 1,
	Default = CW.Settings.TRACER_LIFETIME,
	Decimal = 2,
	Suffix = "s",
	Flag = "Tracer_Lifetime",
	Callback = applyTracerLifetime,
})

TracersTab:Toggle({
	Title = "Apply To Others",
	Default = CW.Settings.TRACER_APPLY_TO_OTHERS,
	Flag = "Tracer_ApplyToOthers",
	Callback = applyTracerApplyToOthers,
})

local UtilityTab = Window:Tab({
	Title = "Utilities",
	Icon = Icons.Visuals,
})

local StarterGui = game:GetService("StarterGui")
local ContextActionService = game:GetService("ContextActionService")
local chatHidden = false
local sprinting = false
local allowSprintRelease = false
local heldShiftKeys = {}

local function onSprintShift(_, inputState, inputObject)
	local keyCode = inputObject and inputObject.KeyCode

	if inputState == Enum.UserInputState.Begin then
		if keyCode and heldShiftKeys[keyCode] then
			return Enum.ContextActionResult.Pass
		end

		local anotherShiftHeld = next(heldShiftKeys) ~= nil
		if keyCode then heldShiftKeys[keyCode] = true end
		if anotherShiftHeld or not CW.Settings.SHIFT_TOGGLE_ENABLED then
			return Enum.ContextActionResult.Pass
		end

		if sprinting then
			sprinting = false
			allowSprintRelease = true
		else
			sprinting = true
			allowSprintRelease = false
		end
		return Enum.ContextActionResult.Pass
	end

	if inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
		if keyCode then heldShiftKeys[keyCode] = nil end

		if not CW.Settings.SHIFT_TOGGLE_ENABLED then
			allowSprintRelease = false
			return Enum.ContextActionResult.Pass
		end

		if allowSprintRelease then
			allowSprintRelease = false
			return Enum.ContextActionResult.Pass
		elseif sprinting then
			return Enum.ContextActionResult.Sink
		end
	end

	return Enum.ContextActionResult.Pass
end

ContextActionService:UnbindAction("CycleWareSprintToggle")
ContextActionService:BindActionAtPriority(
	"CycleWareSprintToggle",
	onSprintShift,
	false,
	Enum.ContextActionPriority.High.Value,
	Enum.KeyCode.LeftShift
)

local function onRightShiftAction(_, inputState)
	if inputState == Enum.UserInputState.Begin then
		Window:ToggleVisibility()
	end

	if sprinting then
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

ContextActionService:UnbindAction("CycleWareProtectSprint")
ContextActionService:BindActionAtPriority(
	"CycleWareProtectSprint",
	onRightShiftAction,
	false,
	Enum.ContextActionPriority.High.Value + 1,
	Enum.KeyCode.RightShift
)

if CW.State.sprintCharacterConn then
	CW.State.sprintCharacterConn:Disconnect()
end
CW.State.sprintCharacterConn = LocalPlayer.CharacterAdded:Connect(function()
	sprinting = false
	allowSprintRelease = false
	table.clear(heldShiftKeys)
end)

local function applySprintToggle(enabled)
	CW.Settings.SHIFT_TOGGLE_ENABLED = enabled == true
	if not CW.Settings.SHIFT_TOGGLE_ENABLED then
		allowSprintRelease = sprinting or allowSprintRelease
		sprinting = false
	end
end

UtilityTab:Toggle({
	Title = "Toggle Sprint with Shift",
	Default = CW.Settings.SHIFT_TOGGLE_ENABLED == true,
	Flag = "Sprint_ToggleEnabled",
	Callback = applySprintToggle,
})

local function setChatVisible(visible)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, visible)
	end)
	pcall(function()
		StarterGui:SetCore("ChatActive", visible)
	end)
end

task.spawn(function()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	setChatVisible(true)
end)

local function applyChatToggle(enabled)
	CW.Settings.CHAT_TOGGLE_ENABLED = enabled == true
	if not CW.Settings.CHAT_TOGGLE_ENABLED then
		chatHidden = false
		setChatVisible(true)
	end
end

if CW.State.chatToggleConn then
	CW.State.chatToggleConn:Disconnect()
end
CW.State.chatToggleConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not CW.Settings.CHAT_TOGGLE_ENABLED then return end
	if input.KeyCode ~= Enum.KeyCode.Z then return end

	chatHidden = not chatHidden
	setChatVisible(not chatHidden)
end)

UtilityTab:Toggle({
	Title = "Toggle Chat with Z",
	Default = CW.Settings.CHAT_TOGGLE_ENABLED == true,
	Flag = "Chat_ToggleEnabled",
	Callback = applyChatToggle,
})

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local VirtualInputManager
pcall(function()
	VirtualInputManager = game:GetService("VirtualInputManager")
end)

local AMMO_LABEL_PATH = "Home.hud.BottomRightFrame.GunFrame.BulletsLabel"
CW.Settings.AUTO_RELOAD_LABEL_PATH = AMMO_LABEL_PATH
if CW.Settings.AUTO_RELOAD_ENABLED == nil then
	CW.Settings.AUTO_RELOAD_ENABLED = _cfg.AUTO_RELOAD_ENABLED ~= false
end

if CW.State.clearAmmoLabelWatchers then
	CW.State.clearAmmoLabelWatchers(true)
end

local ammoLabelConnections = {}
local ammoLabelStates = setmetatable({}, { __mode = "k" })
local autoReloadWarned = false
local autoReloadLabelWarned = false
local ammoScanGeneration = 0
local rebuildAmmoLabelWatchers

local function clearAmmoLabelWatchers(resetStates)
	for _, connection in pairs(ammoLabelConnections) do
		connection:Disconnect()
	end
	table.clear(ammoLabelConnections)
	if resetStates then
		table.clear(ammoLabelStates)
	end
end
CW.State.clearAmmoLabelWatchers = clearAmmoLabelWatchers

local function parseAmmoText(text)
	local current, capacity = tostring(text):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
	return tonumber(current), tonumber(capacity)
end

local function isTextGui(instance)
	return instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")
end

local function isNamedAmmoLabel(instance)
	local name = instance.Name:lower()
	return name:find("ammo", 1, true) ~= nil
		or name:find("magazine", 1, true) ~= nil
		or name:find("magcount", 1, true) ~= nil
		or name:find("clipammo", 1, true) ~= nil
		or name:find("bullet", 1, true) ~= nil
end

local function findConfiguredAmmoLabel()
	local current = PlayerGui
	for part in AMMO_LABEL_PATH:gmatch("[^%.]+") do
		current = current and current:FindFirstChild(part)
	end

	if current and isTextGui(current) then return current end
	return nil
end

local function findAmmoLabels()
	local configured = findConfiguredAmmoLabel()
	if configured then return { configured } end

	local namedLabels = {}
	local fractionLabels = {}
	for _, instance in ipairs(PlayerGui:GetDescendants()) do
		if isTextGui(instance) then
			if isNamedAmmoLabel(instance) then
				table.insert(namedLabels, instance)
			elseif parseAmmoText(instance.Text) then
				table.insert(fractionLabels, instance)
			end
		end
	end

	if #namedLabels == 1 then return namedLabels end
	if #namedLabels > 1 then return {} end
	if #fractionLabels == 1 then return fractionLabels end
	return {}
end

local function pressReloadKey()
	if VirtualInputManager then
		local pressed = pcall(function()
			VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.R, false, game)
		end)
		if pressed then
			task.wait(0.02)
			local released, releaseError = pcall(function()
				VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.R, false, game)
			end)
			if released then return true end
			if not autoReloadWarned then
				autoReloadWarned = true
				CW.Warn("Auto Reload could not release the R key: " .. tostring(releaseError))
			end
			return false
		end
	end

	if type(keypress) == "function" and type(keyrelease) == "function" then
		local pressed = pcall(keypress, 0x52)
		if pressed then
			task.wait(0.02)
			local released, releaseError = pcall(keyrelease, 0x52)
			if released then return true end
			if not autoReloadWarned then
				autoReloadWarned = true
				CW.Warn("Auto Reload could not release the R key: " .. tostring(releaseError))
			end
			return false
		end
	end

	if type(keytap) == "function" then
		local ok = pcall(keytap, 0x52)
		if ok then return true end
	end
	if type(keystroke) == "function" then
		local ok = pcall(keystroke, 0x52)
		if ok then return true end
	end

	if not autoReloadWarned then
		autoReloadWarned = true
		CW.Warn("Auto Reload requires VirtualInputManager or an executor key input function.")
	end
	return false
end

local function attemptReload(label)
	if not CW.Settings.AUTO_RELOAD_ENABLED or UserInputService:GetFocusedTextBox() then return end
	if UserInputService:IsKeyDown(Enum.KeyCode.R) then return end
	local character = LocalPlayer.Character
	if not character or not character:FindFirstChildOfClass("Tool") then return end

	local state = ammoLabelStates[label]
	local now = os.clock()
	if state and now - state.lastReload < 0.3 then return end
	state = state or { lastReload = 0 }
	state.lastReload = now
	ammoLabelStates[label] = state

	task.spawn(function()
		if not pressReloadKey() then return end
		task.wait(0.15)
		if not CW.Settings.AUTO_RELOAD_ENABLED or not label.Parent then return end
		if UserInputService:GetFocusedTextBox() then return end
		local current = parseAmmoText(label.Text)
		if current == 0 then
			pressReloadKey()
		end
	end)
end

local function onAmmoLabelChanged(label)
	if not CW.Settings.AUTO_RELOAD_ENABLED then return end
	local current, capacity = parseAmmoText(label.Text)
	if current == nil or capacity == nil then return end

	local state = ammoLabelStates[label]
	if not state or state.capacity ~= capacity then
		state = { capacity = capacity, lastReload = 0 }
		ammoLabelStates[label] = state
	end

	if current == 0 then
		attemptReload(label)
	else
		state.lastReload = 0
	end
end

rebuildAmmoLabelWatchers = function()
	clearAmmoLabelWatchers()
	ammoScanGeneration = ammoScanGeneration + 1
	local generation = ammoScanGeneration
	if not CW.Settings.AUTO_RELOAD_ENABLED then return end

	task.spawn(function()
		for _ = 1, 20 do
			if generation ~= ammoScanGeneration or not CW.Settings.AUTO_RELOAD_ENABLED then return end

			local labels = findAmmoLabels()
			if #labels > 0 then
				autoReloadLabelWarned = false
				for _, label in ipairs(labels) do
					ammoLabelConnections[label] = label:GetPropertyChangedSignal("Text"):Connect(function()
						onAmmoLabelChanged(label)
					end)
					onAmmoLabelChanged(label)
				end
				return
			end

			task.wait(0.5)
		end

		if generation == ammoScanGeneration and not autoReloadLabelWarned then
			autoReloadLabelWarned = true
			CW.Warn("Auto Reload could not find the ammo label at PlayerGui." .. AMMO_LABEL_PATH)
		end
	end)
end

local function applyAutoReload(enabled)
	CW.Settings.AUTO_RELOAD_ENABLED = enabled == true
	rebuildAmmoLabelWatchers()
end

if CW.State.ammoGuiConn then
	CW.State.ammoGuiConn:Disconnect()
end
CW.State.ammoGuiConn = PlayerGui.DescendantAdded:Connect(function(instance)
	if not CW.Settings.AUTO_RELOAD_ENABLED or not isTextGui(instance) then return end
	if isNamedAmmoLabel(instance) or parseAmmoText(instance.Text) then
		task.defer(rebuildAmmoLabelWatchers)
	end
end)

if CW.State.ammoCharacterConn then
	CW.State.ammoCharacterConn:Disconnect()
end
CW.State.ammoCharacterConn = LocalPlayer.CharacterAdded:Connect(function()
	task.wait(1)
	if CW.Settings.AUTO_RELOAD_ENABLED then
		rebuildAmmoLabelWatchers()
	end
end)

UtilityTab:Toggle({
	Title = "Auto Reload at 0 Ammo",
	Default = CW.Settings.AUTO_RELOAD_ENABLED == true,
	Flag = "AutoReload_Enabled",
	Callback = applyAutoReload,
})

local SettingsTab = Window.ConfigTab

do
	local Theme = Elastic:GetTheme()

	SettingsTab:Colorpicker({
		Title = "Accent Color",
		Default = Theme.Accent,
		Flag = "Config_ThemeAccent",

		Callback = function(color)
			local currentTheme = Elastic:GetTheme()
			currentTheme.Accent = color
			Elastic:SetTheme(currentTheme)
		end,
	})
end

local function reloadAllSettingsAssets()
	local reloaders = {
		{ "hitmarker", CW.reloadHitmarkerAsset },
		{ "cursor", CW.reloadCursor },
		{ "textures", CW.reloadTextures },
		{ "sound", CW.reloadSoundAsset },
	}

	for _, entry in ipairs(reloaders) do
		if type(entry[2]) == "function" then
			local ok, err = pcall(entry[2])
			if not ok then
				CW.Warn("Failed to reload " .. entry[1] .. ": " .. tostring(err))
			end
		end
	end

	refreshWeaponShootSoundOverrides()
	CW.Log("Settings and local assets reloaded.")
end

SettingsTab:Button({
	Title = "Reload Settings",
	Action = "Reload",
	Callback = reloadAllSettingsAssets,
})

local function serializeValue(componentType, value, component)
	if componentType == "Keybind" then
		if typeof(value) == "EnumItem" then
			return {
				EnumType = tostring(value.EnumType):gsub("^Enum%.", ""),
				Name = value.Name,
			}
		end
		return nil
	end

	if componentType == "Colorpicker" then
		local ok, transparency = pcall(function()
			return component:GetTransparency()
		end)

		return {
			R = value.R,
			G = value.G,
			B = value.B,
			Transparency = ok and transparency or 0,
		}
	end

	return value
end

local function deserializeValue(componentType, saved)
	if componentType == "Keybind" then
		if type(saved) == "table" and saved.EnumType and saved.Name then
			local enumType = Enum[saved.EnumType]
			if enumType then
				local ok, item = pcall(function()
					return enumType[saved.Name]
				end)
				if ok then return item end
			end
		end
		return nil
	end

	if componentType == "Colorpicker" then
		if type(saved) ~= "table" then return nil end
		return Color3.new(saved.R, saved.G, saved.B), saved.Transparency
	end

	return saved
end

local SETTINGS_FILE = CW.Paths.CACHE_FOLDER.."/ui_settings.json"

local function saveSettings()
	local out = {}

	for flag, component in pairs(Elastic.Flags) do
		if not flag:find("^Config_") then
			local ok, componentType = pcall(function()
				return component:GetComponentType()
			end)

			if ok and componentType then
				local ok2, value = pcall(function()
					return component:GetValue()
				end)

				if ok2 and value ~= nil then
					local serialized = serializeValue(componentType, value, component)
					if serialized ~= nil then
						out[flag] = { componentType, serialized }
					end
				end
			end
		end
	end

	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, out)
	if not ok then
		warn("[CW] Failed to encode settings")
		return
	end

	pcall(writefile, SETTINGS_FILE, encoded)
end

local function loadSettings()
	if not isfile(SETTINGS_FILE) then return end

	local ok, raw = pcall(readfile, SETTINGS_FILE)
	if not ok then return end

	local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok2 or type(data) ~= "table" then return end

	for flag, entry in pairs(data) do
		local component = Elastic.Flags[flag]

		if component and type(entry) == "table" and entry[1] then
			local componentType, saved = entry[1], entry[2]

			local ok3, currentType = pcall(function()
				return component:GetComponentType()
			end)

			if ok3 and currentType == componentType then
				pcall(function()
					if componentType == "Colorpicker" then
						local color, transparency = deserializeValue(componentType, saved)
						if color then
							component:SetValue(color)
							if transparency ~= nil and component.SetTransparency then
								component:SetTransparency(transparency)
							end
						end
					else
						local value = deserializeValue(componentType, saved)
						if value ~= nil then
							component:SetValue(value)
						end
					end
				end)
			end
		end
	end
end

SettingsTab:Button({
	Title = "Save Settings",
	Action = "Save",
	Callback = function()
		saveSettings()
	end,
})

loadSettings()
scheduleWeaponShootSoundRefresh()

if CW.Settings.AUTO_RELOAD_ENABLED and ammoScanGeneration == 0 then
	rebuildAmmoLabelWatchers()
end

print("[CW] UI loaded.")
end)

if not uiOk then
	warn("[CW] UI failed to load: " .. tostring(uiError))
end
end
