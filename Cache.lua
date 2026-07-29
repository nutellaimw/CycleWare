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
