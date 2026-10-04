-- Standalone entry point; module bodies below are kept in isolated scopes.
local _env = getgenv()
local _cfg = _env.CW_CONFIG
if type(_cfg) ~= "table" then
	_cfg = {}
	_env.CW_CONFIG = _cfg
end
if type(_cfg.ASSET_MANIFEST_URL) ~= "string" or _cfg.ASSET_MANIFEST_URL == "" then
	_cfg.ASSET_MANIFEST_URL = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/manifest.json"
end

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

CW.Paths.CURSOR_ROOT = "CycleWare"
CW.Paths.LIBRARY_ROOT = CW.Paths.CURSOR_ROOT .. "/Library"
CW.Paths.CURSORS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Cursors"
CW.Paths.HITMARKERS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Hitmarkers"
CW.Paths.HIT_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/HitSounds"
CW.Paths.TEXTURES_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Textures"
CW.Paths.OFFICIAL_FOLDER = "_Official"
CW.Paths.CACHE_FOLDER = CW.Paths.CURSOR_ROOT .. "/Cache"
CW.Paths.GENERATED_FOLDER = CW.Paths.CACHE_FOLDER .. "/Generated"
CW.Paths.TINTED_FOLDER = CW.Paths.GENERATED_FOLDER .. "/Cursors"
CW.Paths.CURSOR_SIG_FILE = CW.Paths.TINTED_FOLDER .. "/cursor.sig"
CW.Paths.MANIFEST_FILE = CW.Paths.LIBRARY_ROOT .. "/manifest.json"
CW.Paths.LIBRARY_REVISION_FILE = CW.Paths.LIBRARY_ROOT .. "/.revision"
CW.Paths.SETTINGS_FILE = CW.Paths.CACHE_FOLDER .. "/ui_settings.json"

CW.Paths.CURSOR_FILE = nil
CW.Paths.HITMARKER_FILE = nil
CW.Paths.SOUND_FILE = nil
CW.Paths.TEXTURE_FILE = nil

CW.Settings.HITMARKER_SIZE             = numOr(_cfg.HITMARKER_SIZE, 50, 1)
CW.Settings.SOUND_VOLUME               = numOr(_cfg.SOUND_VOLUME, 1, 0)
CW.Settings.CURSOR_TARGET_SIZE         = numOr(_cfg.CURSOR_TARGET_SIZE, 82, 1)
CW.Settings.HITMARKER_VISIBLE_DURATION = numOr(_cfg.HITMARKER_VISIBLE_DURATION, 0.05, 0)
CW.Settings.HITMARKER_FADEOUT_DURATION = numOr(_cfg.HITMARKER_FADEOUT_DURATION, 0.15, 0)

CW.Settings.HITMARKER_RANDOM_ROTATION = boolOr(_cfg.HITMARKER_RANDOM_ROTATION, true)
CW.Settings.HITMARKER_FOLLOW_MOUSE    = boolOr(_cfg.HITMARKER_FOLLOW_MOUSE, true)
CW.Settings.HITMARKER_FADEOUT         = boolOr(_cfg.HITMARKER_FADEOUT, true)

CW.Settings.ASSET_SELECTIONS = CW.Settings.ASSET_SELECTIONS or {
	Cursor = nil,
	Hitmarker = nil,
	HitSound = nil,
	Textures = {},
}
CW._SavedSettings = {}

local settingsFileExists = false
pcall(function()
	settingsFileExists = isfile(CW.Paths.SETTINGS_FILE)
end)

if settingsFileExists then
	local ok, raw = pcall(readfile, CW.Paths.SETTINGS_FILE)

	if ok then
		local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)

		if ok2 and type(data) == "table" then
			local values = data.Settings
			if type(values) ~= "table" then
				values = {}
				local legacyFlags = {
					Hitmarker_Size = "HITMARKER_SIZE",
					Hitmarker_RandomRotation = "HITMARKER_RANDOM_ROTATION",
					Hitmarker_FollowMouse = "HITMARKER_FOLLOW_MOUSE",
					Hitmarker_VisibleDuration = "HITMARKER_VISIBLE_DURATION",
					Hitmarker_Fadeout = "HITMARKER_FADEOUT",
					Hitmarker_FadeoutDuration = "HITMARKER_FADEOUT_DURATION",
					Cursor_Size = "CURSOR_TARGET_SIZE",
					Sound_Volume = "SOUND_VOLUME",
					Tracer_Enabled = "CUSTOM_BULLET_TRACERS",
					Tracer_Width = "TRACER_WIDTH",
					Tracer_Lifetime = "TRACER_LIFETIME",
					Tracer_ApplyToOthers = "TRACER_APPLY_TO_OTHERS",
					Sprint_ToggleEnabled = "SHIFT_TOGGLE_ENABLED",
					Chat_ToggleEnabled = "CHAT_TOGGLE_ENABLED",
					AutoReload_Enabled = "AUTO_RELOAD_ENABLED",
					WeaponSoundOverrides_Enabled = "WEAPON_SOUND_OVERRIDE_ENABLED",
					WeaponSoundOverrides_Others = "WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS",
				}
				for flag, key in pairs(legacyFlags) do
					local entry = data[flag]
					if type(entry) == "table" then values[key] = entry[2] end
				end
				if type(data.Tracer_Color) == "table" then
					local color = data.Tracer_Color[2]
					if type(color) == "table" and color.R and color.G and color.B then
						values.TRACER_COLOR = Color3.new(color.R, color.G, color.B)
					end
				end
				if type(data.Tracer_GlowColor) == "table" then
					local color = data.Tracer_GlowColor[2]
					if type(color) == "table" and color.R and color.G and color.B then
						values.TRACER_GLOW_COLOR = Color3.new(color.R, color.G, color.B)
					end
				end
			end
			CW._SavedSettings = values
			for key, value in pairs(values) do
				local current = CW.Settings[key]
				if type(current) == type(value) and type(value) ~= "table" then
					CW.Settings[key] = value
				elseif type(current) == "table" and type(value) == "table" then
					CW.Settings[key] = value
				end
			end

			local selections = data.AssetSelections
			if type(selections) == "table" then
				for _, key in ipairs({ "Cursor", "Hitmarker", "HitSound" }) do
					if type(selections[key]) == "string" then
						CW.Settings.ASSET_SELECTIONS[key] = selections[key]
					end
				end
				if type(selections.Textures) == "table" then
					CW.Settings.ASSET_SELECTIONS.Textures = selections.Textures
				end
			end

			CW.Log("Loaded saved UI settings and asset selections")
		end
	end
end

-- ShootEvent is resolved (and waited for) by the Hook module.
if not CW.ShootEvent then
	local gunRemotes = ReplicatedStorage:FindFirstChild("GunRemotes")
	CW.ShootEvent = gunRemotes and gunRemotes:FindFirstChild("ShootEvent")
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
	CW.Paths.CURSOR_ROOT,
	CW.Paths.LIBRARY_ROOT,
	CW.Paths.CURSORS_FOLDER,
	CW.Paths.CURSORS_FOLDER.."/"..CW.Paths.OFFICIAL_FOLDER,
	CW.Paths.HITMARKERS_FOLDER,
	CW.Paths.HITMARKERS_FOLDER.."/"..CW.Paths.OFFICIAL_FOLDER,
	CW.Paths.HIT_SOUNDS_FOLDER,
	CW.Paths.HIT_SOUNDS_FOLDER.."/"..CW.Paths.OFFICIAL_FOLDER,
	CW.Paths.TEXTURES_FOLDER,
	CW.Paths.CACHE_FOLDER,
	CW.Paths.GENERATED_FOLDER,
	CW.Paths.TINTED_FOLDER,
}

function CW.ensureFolders()
	for _, folder in ipairs(ALL_FOLDERS) do
		if not isfolder(folder) then
			pcall(makefolder, folder)
		end
	end
end
CW.ensureFolders()

-- Cooperative yielding for heavy loops (PNG codec) so the game never freezes.
local lastYield = os.clock()
function CW.yieldBudget()
	if os.clock() - lastYield > 0.008 then
		task.wait()
		lastYield = os.clock()
	end
end

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
	if not path or not isfile(path) then
		return prefix..":none"..extra, nil
	end
	local ok, data = pcall(readfile, path)
	if not ok or not data then
		return prefix..":readfail"..extra, nil
	end
	return prefix..":"..CW.crc32(data)..extra, data
end

function CW.loadLibraryAsset(cfg)
	if not cfg.file or not isfile(cfg.file) then
		CW.Log(cfg.label .. " file not found in the asset library")
		return nil, "missing"
	end

	local ok, asset = pcall(getcustomasset, cfg.file)
	if not ok or not asset then
		CW.Warn("getcustomasset failed for " .. cfg.label .. ": " .. tostring(asset))
		return nil, "error"
	end

	CW.Log(cfg.label .. " loaded from " .. cfg.file)
	return asset, nil
end
end


do
-- AssetLibrary.lua
local CW = getgenv().__CW_CORE_STATE
local HttpService = game:GetService("HttpService")

local CATEGORY_INFO = {
	Cursors = { folder = CW.Paths.CURSORS_FOLDER, extensions = { png = true } },
	Hitmarkers = { folder = CW.Paths.HITMARKERS_FOLDER, extensions = { png = true } },
	-- Roblox only decodes mp3/ogg for audio; wav is not supported.
	HitSounds = { folder = CW.Paths.HIT_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true } },
}
local SELECTION_KEYS = {
	Cursors = "Cursor",
	Hitmarkers = "Hitmarker",
	HitSounds = "HitSound",
}
local ASSET_EXTENSIONS = { png = true, mp3 = true, ogg = true }

local function ensureFolderPath(path)
	local current = ""
	for segment in path:gmatch("[^/]+") do
		current = current == "" and segment or current .. "/" .. segment
		local exists = false
		pcall(function() exists = isfolder(current) end)
		if not exists then pcall(makefolder, current) end
	end
end

local function validWeaponName(weapon)
	return type(weapon) == "string"
		and weapon ~= "." and weapon ~= ".."
		and weapon:match("^[%w_%-%. ]+$") ~= nil
end

local function validManifestPath(category, path)
	if type(path) ~= "string" or path:find("\\", 1, true) or path:match("^/") then return false end
	for segment in path:gmatch("[^/]+") do
		if segment == "." or segment == ".." or segment:find("[%c]") then return false end
	end
	local extension = path:match("%.([%w]+)$")
	if not extension then return false end
	extension = extension:lower()
	local info = CATEGORY_INFO[category]
	if info then
		return path:match("^" .. category .. "/[^/]+$") ~= nil
			and info.extensions[extension] == true
	end
	if category == "Textures" then
		return path:match("^Textures/[^/]+/[^/]+$") ~= nil
			and extension == "png"
	end
	return false
end

local function detectAssetFormat(path, data)
	if type(data) ~= "string" or #data < 4 then return "empty or truncated" end
	local extension = path:match("%.([%w]+)$")
	if not extension then return "unknown" end
	extension = extension:lower()

	if data:sub(1, 8) == "\137\80\78\71\13\10\26\10" then return "png" end
	if data:sub(1, 4) == "MM\0\42" or data:sub(1, 4) == "II\42\0" then return "tiff" end
	if data:sub(1, 3) == "\255\216\255" then return "jpeg" end
	if data:sub(1, 4) == "OggS" then return "ogg" end
	if data:sub(1, 3) == "ID3" then return "mp3" end
	local first, second = string.byte(data, 1, 2)
	if first == 0xFF and second and bit32.band(second, 0xE0) == 0xE0 then return "mp3" end
	if data:match("^%d%d%d:%s") then return "HTTP error response" end
	return "unknown"
end

local invalidAssetWarnings = {}

local function libraryRelative(path)
	if type(path) ~= "string" then return nil end
	local normalized = path:gsub("\\", "/")
	local prefix = CW.Paths.LIBRARY_ROOT .. "/"
	if normalized:sub(1, #prefix) == prefix then
		return normalized:sub(#prefix + 1)
	end
	local marker = "/" .. prefix
	local markerIndex = normalized:find(marker, 1, true)
	if markerIndex then return normalized:sub(markerIndex + #marker) end
	return nil
end

CW.Library = {}
CW.Library.ensureFolder = ensureFolderPath

function CW.Library.list(category, weapon)
	local info = CATEGORY_INFO[category]
	local directories = {}
	if info then
		table.insert(directories, info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, info.folder)
	elseif category == "Textures" and type(weapon) == "string" then
		local weaponFolder = CW.Paths.TEXTURES_FOLDER .. "/" .. weapon
		table.insert(directories, weaponFolder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, weaponFolder)
	else
		return {}
	end

	local extensions = info and info.extensions or { png = true }
	local result = {}
	for _, directory in ipairs(directories) do
		local ok, files = pcall(listfiles, directory)
		if ok and type(files) == "table" then
			for _, filePath in ipairs(files) do
				local normalized = tostring(filePath):gsub("\\", "/")
				local filename = normalized:match("([^/]+)$") or normalized
				local extension = filename:match("%.([%w]+)$")
				if extension and extensions[extension:lower()] then
					local relative = libraryRelative(normalized)
					if relative then
						local okData, data = pcall(readfile, normalized)
						local actualFormat = okData and detectAssetFormat(normalized, data) or "unreadable"
						if actualFormat == extension:lower() then
							table.insert(result, {
								Name = filename:gsub("%.[%w]+$", ""),
								Path = CW.Paths.LIBRARY_ROOT .. "/" .. relative,
								Relative = relative,
							})
						elseif not invalidAssetWarnings[normalized] then
							invalidAssetWarnings[normalized] = true
							CW.Warn("Skipped invalid library asset " .. relative .. " (expected " .. extension:lower() .. ", detected " .. actualFormat .. ")")
						end
					end
				end
			end
		end
	end
	table.sort(result, function(left, right)
		return left.Relative:lower() < right.Relative:lower()
	end)
	return result
end

function CW.Library.relative(path)
	return libraryRelative(path)
end

function CW.Library.setSelection(category, weapon, relative)
	local selections = CW.Settings.ASSET_SELECTIONS
	if category == "Textures" then
		selections.Textures = selections.Textures or {}
		selections.Textures[weapon] = relative
	else
		local key = SELECTION_KEYS[category]
		if key then selections[key] = relative end
	end
end

function CW.Library.selectedPath(category, weapon)
	local selections = CW.Settings.ASSET_SELECTIONS
	local selected
	if category == "Textures" then
		selected = selections.Textures and selections.Textures[weapon]
	else
		local key = SELECTION_KEYS[category]
		selected = key and selections[key]
	end
	local files = CW.Library.list(category, weapon)
	for _, item in ipairs(files) do
		if item.Relative == selected then return item.Path, item.Relative end
	end
	local first = files[1]
	if category == "Textures" then
		CW.Library.setSelection(category, weapon, nil)
		return nil, nil
	end
	if first then
		CW.Library.setSelection(category, weapon, first.Relative)
		return first.Path, first.Relative
	end
	CW.Library.setSelection(category, weapon, nil)
	return nil, nil
end

local function officialDestination(category, relativePath)
	if category == "Textures" then
		local weapon, filename = relativePath:match("^Textures/([^/]+)/([^/]+)$")
		if not validWeaponName(weapon) then return nil end
		return CW.Paths.TEXTURES_FOLDER .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER .. "/" .. filename
	end
	local info = CATEGORY_INFO[category]
	if not info then return nil end
	local filename = relativePath:match("^" .. category .. "/([^/]+)$")
	if not filename then return nil end
	return info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER .. "/" .. filename
end

local function encodeURLPath(path)
	return (path:gsub("([^%w_%.%-~/])", function(character)
		return string.format("%%%02X", string.byte(character))
	end))
end

-- Removes official files that no longer exist in the manifest (never touches user files).
local function pruneOfficial(expected)
	local function pruneFolder(folder)
		local okFolder, exists = pcall(isfolder, folder)
		if not okFolder or not exists then return end
		local ok, files = pcall(listfiles, folder)
		if not ok or type(files) ~= "table" then return end
		for _, filePath in ipairs(files) do
			local normalized = tostring(filePath):gsub("\\", "/")
			local relative = libraryRelative(normalized)
			local extension = normalized:match("%.([%w]+)$")
			if relative and extension and ASSET_EXTENSIONS[extension:lower()] and not expected[relative] then
				if pcall(delfile, filePath) then
					CW.Log("Removed obsolete official asset " .. relative)
				end
			end
		end
	end

	for _, info in pairs(CATEGORY_INFO) do
		pruneFolder(info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
	end
	local ok, weaponFolders = pcall(listfiles, CW.Paths.TEXTURES_FOLDER)
	if ok and type(weaponFolders) == "table" then
		for _, weaponFolder in ipairs(weaponFolders) do
			pruneFolder((tostring(weaponFolder):gsub("\\", "/")) .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		end
	end
end

local function syncImpl()
	local manifestURL = _cfg.ASSET_MANIFEST_URL
	if type(manifestURL) ~= "string" or manifestURL == "" then
		CW.Log("Asset manifest URL is unset; using files already in Library")
		return false
	end
	CW.Log("Fetching asset manifest")
	if type(game.HttpGet) ~= "function" then
		CW.Warn("HttpGet unavailable; using files already in Library")
		return false
	end

	local fetched, raw = pcall(function() return game:HttpGet(manifestURL) end)
	if not fetched or type(raw) ~= "string" then
		CW.Warn("Could not download the asset manifest: " .. tostring(raw))
		return false
	end
	local decoded, manifest = pcall(HttpService.JSONDecode, HttpService, raw)
	if not decoded or type(manifest) ~= "table" or manifest.schemaVersion ~= 1 or type(manifest.assets) ~= "table" then
		CW.Warn("Asset manifest is invalid or uses an unsupported schema")
		return false
	end

	local baseURL = manifestURL:match("^(.*)/[^/]+$")
	if not baseURL then
		CW.Warn("Asset manifest URL must point to a file under a raw repository URL")
		return false
	end
	local revision = type(manifest.revision) == "string" and manifest.revision ~= ""
		and manifest.revision or string.format("%08x", CW.crc32(raw))
	local previousRevision = CW.readSigFile(CW.Paths.LIBRARY_REVISION_FILE)
	local complete = true
	local skipped = 0
	local pending = {}

	for category, entries in pairs(manifest.assets) do
		if category == "Textures" and type(entries) == "table" then
			for weapon, weaponEntries in pairs(entries) do
				if validWeaponName(weapon) and type(weaponEntries) == "table" then
					ensureFolderPath(CW.Paths.TEXTURES_FOLDER .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER)
					for _, entry in ipairs(weaponEntries) do
						local manifestWeapon
						if type(entry) == "table" and type(entry.path) == "string" then
							manifestWeapon = entry.path:match("^Textures/([^/]+)/")
						end
						if type(entry) == "table" and manifestWeapon == weapon and validManifestPath(category, entry.path) then
							table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
						else
							skipped = skipped + 1
							CW.Warn("Skipped invalid texture entry in manifest")
						end
					end
				else
					skipped = skipped + 1
				end
			end
		elseif CATEGORY_INFO[category] and type(entries) == "table" then
			for _, entry in ipairs(entries) do
				if type(entry) == "table" and validManifestPath(category, entry.path) then
					table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
				else
					skipped = skipped + 1
					CW.Warn("Skipped invalid " .. category .. " entry in manifest")
				end
			end
		elseif category ~= "Textures" then
			complete = false
			skipped = skipped + 1
			CW.Warn("Skipped unsupported manifest category: " .. tostring(category))
		end
	end

	CW.Log(string.format("Manifest contains %d supported assets; skipped %d unsupported entries", #pending, skipped))
	pcall(writefile, CW.Paths.MANIFEST_FILE, raw)

	local expected = {}
	for index, entry in ipairs(pending) do
		if index == 1 or index % 5 == 0 or index == #pending then
			CW.Log(string.format("Syncing asset %d/%d: %s", index, #pending, entry.path))
		end
		local destination = officialDestination(entry.category, entry.path)
		if not destination then
			complete = false
		else
			local destinationRelative = libraryRelative(destination)
			if destinationRelative then expected[destinationRelative] = true end
			ensureFolderPath(destination:match("^(.*)/[^/]+$"))

			-- Validate cached bytes before trusting the extension or manifest revision.
			local needsDownload = true
			if isfile(destination) then
				local ok, existing = pcall(readfile, destination)
				local actualFormat = ok and detectAssetFormat(entry.path, existing) or "unreadable"
				if actualFormat == entry.path:match("%.([%w]+)$"):lower() then
					if entry.crc32 then
						local expectedCRC = tostring(entry.crc32):lower():gsub("^0x", "")
						needsDownload = string.format("%08x", CW.crc32(existing)):lower() ~= expectedCRC
					else
						needsDownload = previousRevision ~= revision
					end
				else
					CW.Warn("Cached asset " .. entry.path .. " is invalid (detected " .. actualFormat .. "); downloading again")
				end
			end

			if needsDownload then
				local remotePath = encodeURLPath(entry.path)
				local downloaded, bytes = pcall(function() return game:HttpGet(baseURL .. "/" .. remotePath) end)
				if downloaded and type(bytes) == "string" then
					local actualFormat = detectAssetFormat(entry.path, bytes)
					local expectedFormat = entry.path:match("%.([%w]+)$"):lower()
					local expectedCRC = entry.crc32 and tostring(entry.crc32):lower():gsub("^0x", "")
					local actualCRC = string.format("%08x", CW.crc32(bytes)):lower()
					if actualFormat ~= expectedFormat then
						complete = false
						CW.Warn("Rejected " .. entry.path .. ": expected " .. expectedFormat .. " content, detected " .. actualFormat .. ". Check the GitHub path and file format.")
					elseif expectedCRC and actualCRC ~= expectedCRC then
						complete = false
						CW.Warn("Checksum mismatch for " .. entry.path)
					else
						local temporary = destination .. ".download"
						local wrote = pcall(writefile, temporary, bytes)
						local readOK, verified = pcall(readfile, temporary)
						local saved = wrote and readOK and verified == bytes
						if saved then saved = pcall(writefile, destination, verified) end
						pcall(delfile, temporary)
						if not saved then
							complete = false
							CW.Warn("Could not save official asset " .. entry.path)
						end
					end
				else
					complete = false
					CW.Warn("Could not download official asset " .. entry.path)
				end
			end
		end
		if index % 5 == 0 then task.wait() end
	end

	-- Persist a valid manifest revision even when a few entries fail. Good files then
	-- stay cached, while missing/invalid paths are retried because their files fail validation.
	pcall(writefile, CW.Paths.LIBRARY_REVISION_FILE, revision)
	if complete then
		if skipped == 0 and #pending > 0 then pruneOfficial(expected) end
		CW.Log("Asset library synchronized at revision " .. revision)
	else
		CW.Warn("Asset sync finished with invalid or unavailable files; valid assets were kept")
	end
	return complete
end

-- Only one sync at a time; concurrent callers wait for the running one.
function CW.Library.sync()
	if CW.State.syncing then
		while CW.State.syncing do task.wait(0.1) end
		return CW.State.lastSyncResult == true
	end
	CW.State.syncing = true
	local ok, result = pcall(syncImpl)
	CW.State.syncing = false
	CW.State.lastSyncResult = ok and result == true
	if not ok then error(result, 0) end
	return result
end

CW.Paths.CURSOR_FILE = CW.Library.selectedPath("Cursors")
CW.Paths.HITMARKER_FILE = CW.Library.selectedPath("Hitmarkers")
CW.Paths.SOUND_FILE = CW.Library.selectedPath("HitSounds")
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
		if i % 65536 == 0 then CW.yieldBudget() end
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
		if i % 8192 == 0 then CW.yieldBudget() end
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
		if y % 8 == 0 then CW.yieldBudget() end
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
	local ticks = 0

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
			ticks = ticks + 1
			if ticks % 16384 == 0 then CW.yieldBudget() end
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
	local interlace = 0
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
			interlace = sbyte(chunk,13)
			assert(bitDepth == 8, "parsePNG: unsupported bit depth "..tostring(bitDepth))
			assert(interlace == 0, "parsePNG: interlaced PNGs are not supported")
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
		if y % 8 == 0 then CW.yieldBudget() end
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
		if y % 8 == 0 then CW.yieldBudget() end
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
		if (i - 1) % 65536 == 0 then CW.yieldBudget() end
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
	CW.State.lastTarget = nil -- force the PreRender loop to re-evaluate the hovered target
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
		CW.Warn("No valid cursor image found at " .. tostring(CW.Paths.CURSOR_FILE) .. " — place a PNG in the cursor library and refresh.")
		return false
	end
	local ok2, px, w, h = pcall(CW.parsePNG, data)
	if not ok2 then
		-- Unsupported PNG variant (interlaced, 16-bit, ...): use the original image as-is.
		CW.Warn("parsePNG failed (" .. tostring(px) .. "); using the original image without resize/tint")
		local okAsset, asset = pcall(getcustomasset, CW.Paths.CURSOR_FILE)
		if okAsset and asset then
			CW.Assets.white, CW.Assets.red, CW.Assets.green = asset, asset, asset
			return true
		end
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

local function generateCursorsOnce()
	if not CW.Paths.CURSOR_FILE then
		CW.Assets.white, CW.Assets.red, CW.Assets.green = nil, nil, nil
		CW.State.cursorsReady = false
		CW.State.currentCursorKey = nil
		for _, key in ipairs({ "enforcerConn", "enableConn" }) do
			local connection = CW.State[key]
			if connection then
				pcall(function() connection:Disconnect() end)
				CW.State[key] = nil
			end
		end
		pcall(function()
			UserInputService.MouseIconEnabled = true
			UserInputService.MouseIcon = ""
		end)
		CW.Warn("No cursor found; add a PNG to " .. CW.Paths.CURSORS_FOLDER .. " and refresh the asset library.")
		return
	end

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

-- The codec now yields, so serialise runs: a request made while one is running
-- marks the state dirty and triggers exactly one more pass with the latest settings.
local function generateCursors()
	if CW.State.cursorBusy then
		CW.State.cursorDirty = true
		return
	end
	CW.State.cursorBusy = true
	repeat
		CW.State.cursorDirty = false
		local ok, err = pcall(generateCursorsOnce)
		if not ok then CW.Warn("Cursor generation failed: " .. tostring(err)) end
	until not CW.State.cursorDirty
	CW.State.cursorBusy = false
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
	local asset = CW.loadLibraryAsset({
		file = CW.Paths.HITMARKER_FILE,
		label = "hitmarker",
	})
	-- Clear the old image when the selection is gone, instead of keeping a stale one.
	CW.HMTemplate.Image = asset or ""
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
	local asset, failReason = CW.loadLibraryAsset({
		file = CW.Paths.SOUND_FILE,
		label = "hit sound",
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

CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER)

local WEAPON_MESHES = _cfg.WEAPON_MESHES or {
	["M9"]            = "Meshes/M9_3",
	["M4A1"]          = "Meshes/m4_7",
	["Remington 870"] = "Meshes/r870_2",
	["Revolver"]      = "Meshes/revolver (3)",
	["MP5"]           = "GunMesh",
	["AK-47"]         = "Meshes/AK47_7",
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
table.sort(WEAPON_LIST)

CW.WeaponList          = WEAPON_LIST
CW.normalizeTextureKey = normalizeKey
CW.Assets.weaponTextures = {}
CW.Settings.ASSET_SELECTIONS.Textures = CW.Settings.ASSET_SELECTIONS.Textures or {}

local originals = CW.State.weaponTextureOriginals
if not originals then
	originals = {}
	CW.State.weaponTextureOriginals = originals
	local old = CW.State.originalWeaponTextureIds
	if old then
		for mesh, entry in pairs(old) do
			originals[mesh] = type(entry) == "table" and entry or { value = entry }
		end
		CW.State.originalWeaponTextureIds = nil
	end
end

local appliedIds = CW.State.appliedTextureIds
if not appliedIds then
	appliedIds = {}
	CW.State.appliedTextureIds = appliedIds
end

for _, weaponName in ipairs(WEAPON_LIST) do
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName)
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName .. "/" .. CW.Paths.OFFICIAL_FOLDER)
end


local function isTextureTarget(instance)
	return instance:IsA("MeshPart") or instance:IsA("SpecialMesh")
end

local function findWeaponMesh(tool, meshPath)
	-- Some game assets keep the slash in the Instance.Name; try that exact name first.
	local exact = tool:FindFirstChild(meshPath, true)
	if exact and isTextureTarget(exact) then return exact end

	local current = tool
	for segment in meshPath:gmatch("[^/]+") do
		current = current and current:FindFirstChild(segment)
		if not current then break end
	end
	if current and isTextureTarget(current) then return current end

	local meshName = meshPath:match("([^/]+)$")
	local fallback = meshName and tool:FindFirstChild(meshName, true)
	if fallback and isTextureTarget(fallback) then return fallback end
	return nil
end

local function getTextureId(target)
	if target:IsA("MeshPart") then return target.TextureID end
	return target.TextureId
end

local function setTextureId(target, textureId)
	if target:IsA("MeshPart") then
		target.TextureID = textureId
	else
		target.TextureId = textureId
	end
end

local function forgetOriginal(mesh)
	local entry = originals[mesh]
	originals[mesh] = nil
	if entry and entry.conn then
		pcall(function() entry.conn:Disconnect() end)
	end
end

local function applyTexture(tool)
	if not tool:IsA("Tool") then return end
	local meshName = WEAPON_MESHES[tool.Name]
	if not meshName then return end

	local mesh = findWeaponMesh(tool, meshName)
	if not mesh then
		CW.State.textureLookupWarnings = CW.State.textureLookupWarnings or {}
		if not CW.State.textureLookupWarnings[tool.Name] then
			CW.State.textureLookupWarnings[tool.Name] = true
			CW.Warn("Texture target not found for " .. tool.Name .. " (mapped path: " .. meshName .. ")")
		end
		return
	end

	local textureId = CW.Assets.weaponTextures[tool.Name]
	local entry = originals[mesh]
	local current = getTextureId(mesh) or ""
	if textureId then
		if not entry then
			entry = { value = not appliedIds[current] and current or nil }
			entry.conn = mesh.Destroying:Connect(function() forgetOriginal(mesh) end)
			originals[mesh] = entry
		end
		appliedIds[textureId] = true
		local ok, err = pcall(setTextureId, mesh, textureId)
		if not ok then CW.Warn("Could not apply texture to " .. tool.Name .. ": " .. tostring(err)) end
		return
	end

	if not entry then
		if appliedIds[current] then
			CW.State.textureRestoreWarnings = CW.State.textureRestoreWarnings or {}
			if not CW.State.textureRestoreWarnings[tool.Name] then
				CW.State.textureRestoreWarnings[tool.Name] = true
				CW.Warn("Original texture of " .. tool.Name .. " is unknown (it was customized before this run); respawn to restore it")
			end
		end
		return
	end

	if entry.value == nil or appliedIds[entry.value] then
		CW.Warn("Original texture of " .. tool.Name .. " is unknown; respawn to restore it")
		forgetOriginal(mesh)
		return
	end

	local restored, err = pcall(setTextureId, mesh, entry.value)
	if restored then
		forgetOriginal(mesh)
	else
		CW.Warn("Could not restore original texture for " .. tool.Name .. ": " .. tostring(err))
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
	local loadedTextures = {}
	for _, weaponName in ipairs(WEAPON_LIST) do
		local filePath = CW.Library.selectedPath("Textures", weaponName)
		if filePath then
			local ok, asset = pcall(getcustomasset, filePath)
			if ok and asset then
				loadedTextures[weaponName] = asset
			else
				CW.Warn("Could not load selected texture for " .. weaponName)
			end
		end
	end
	CW.Assets.weaponTextures = loadedTextures

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then applyToContainer(backpack) end
	if LocalPlayer.Character then applyToContainer(LocalPlayer.Character) end
end
CW.reloadTextures = reloadTexturesAndApply
reloadTexturesAndApply()

if CW.IsFirstRun then
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		monitor(backpack)
	else
		CW.State.backpackMonitorConn = LocalPlayer.ChildAdded:Connect(function(child)
			if not child:IsA("Backpack") then return end
			CW.State.backpackMonitorConn:Disconnect()
			CW.State.backpackMonitorConn = nil
			monitor(child)
		end)
	end

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

local function shouldUseCustom()
	if not CW.Settings.CUSTOM_BULLET_TRACERS then return false end
	if CW.Settings.TRACER_APPLY_TO_OTHERS then return true end
	return isLocalPlayerShot()
end

-- Installs the override once; returns false (so we can retry) if the game module isn't ready yet.
local function installTracers()
	if CW.State.tracersHooked then return true end

	local shared = ReplicatedStorage:FindFirstChild("SharedModules")
	local moduleScript = shared and shared:FindFirstChild("GunTracers")
	if not moduleScript then return false end

	local ok, TracersModule = pcall(require, moduleScript)
	if not ok or type(TracersModule) ~= "table" then return false end

	CW.TracersModule          = TracersModule
	CW._originalCreateBullet  = TracersModule.createBullet
	CW._originalCreateTaser   = TracersModule.createTaser
	CW._originalCreateSniper  = TracersModule.createSniper

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

	CW.State.tracersHooked = true
	CW.Log("Tracer override installed.")
	return true
end

if not installTracers() and not CW.State.tracersRetrying then
	CW.State.tracersRetrying = true
	task.spawn(function()
		local deadline = os.clock() + 60
		while os.clock() < deadline do
			task.wait(1)
			if installTracers() then
				CW.State.tracersRetrying = false
				return
			end
		end
		CW.State.tracersRetrying = false
		CW.Warn("GunTracers module not found — custom tracers disabled.")
	end)
end
end


do
-- Hook.lua
local CW = getgenv().__CW_CORE_STATE

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")

local LocalPlayer = CW.LocalPlayer

-- Shot handler. Stored on CW so a re-run updates the logic without re-hooking.
function CW.onShot(bullets)
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

	-- Read the real mouse position now; mouseX/Y only update on MouseMovement.
	local loc = UserInputService:GetMouseLocation()
	CW.State.mouseX, CW.State.mouseY = loc.X, loc.Y

	local Clone = CW.HMTemplate:Clone()
	Clone.Size              = UDim2.new(0, CW.Settings.HITMARKER_SIZE, 0, CW.Settings.HITMARKER_SIZE)
	Clone.Position          = UDim2.fromOffset(CW.State.mouseX, CW.State.mouseY)
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
end

-- The hook only forwards the call: our logic runs deferred and protected,
-- so it can never break or delay the game's own FireServer.
local function installShootHook()
	if CW.State.shootHooked then return true end

	local remotes = ReplicatedStorage:FindFirstChild("GunRemotes")
	local shootEvent = remotes and remotes:FindFirstChild("ShootEvent")
	if not shootEvent then return false end
	CW.ShootEvent = shootEvent

	local OldNameCall
	OldNameCall = hookmetamethod(shootEvent, "__namecall", newcclosure(function(self, ...)
		if checkcaller() then return OldNameCall(self, ...) end
		if getnamecallmethod() == "FireServer" and self == CW.ShootEvent then
			local bullets = ...
			task.defer(function()
				local ok, err = pcall(CW.onShot, bullets)
				if not ok then CW.Warn("Shot handler error: " .. tostring(err)) end
			end)
		end
		return OldNameCall(self, ...)
	end))

	CW.State.shootHooked = true
	CW.Log("ShootEvent hook installed")
	return true
end

if not installShootHook() and not CW.State.shootHookRetrying then
	CW.State.shootHookRetrying = true
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("GunRemotes", 60)
		if remotes then remotes:WaitForChild("ShootEvent", 60) end
		CW.State.shootHookRetrying = false
		if not installShootHook() then
			CW.Warn("GunRemotes.ShootEvent not found; hitmarker detection unavailable")
		end
	end)
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
		pcall(function() if CW.UIWindow then CW.UIWindow:Destroy() end end)
		pcall(function() if CW.State.enforcerConn then CW.State.enforcerConn:Disconnect() end end)
		pcall(function() if CW.State.enableConn   then CW.State.enableConn:Disconnect()   end end)
		pcall(function() if CW.State.sprintCharacterConn then CW.State.sprintCharacterConn:Disconnect() end end)
		pcall(function() if CW.State.chatToggleConn then CW.State.chatToggleConn:Disconnect() end end)
		pcall(function() if CW.State.ammoGuiConn then CW.State.ammoGuiConn:Disconnect() end end)
		pcall(function() if CW.State.ammoCharacterConn then CW.State.ammoCharacterConn:Disconnect() end end)
		pcall(function() if CW.State.backpackMonitorConn then CW.State.backpackMonitorConn:Disconnect() end end)
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
-- Sync.lua
-- Runs independently of the UI: official assets are downloaded even if the UI fails to load,
-- and everything that consumes assets is reloaded as soon as the download finishes.
local CW = getgenv().__CW_CORE_STATE

function CW.reloadCoreAssets()
	CW.Paths.CURSOR_FILE = CW.Library.selectedPath("Cursors")
	CW.Paths.HITMARKER_FILE = CW.Library.selectedPath("Hitmarkers")
	CW.Paths.SOUND_FILE = CW.Library.selectedPath("HitSounds")

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
end

CW.State.syncFinished = false
CW.State.syncCallbacks = {}

task.spawn(function()
	local ok, result = pcall(CW.Library.sync)
	if not ok then
		CW.Warn("Asset sync failed: " .. tostring(result))
	elseif not result then
		CW.Warn("Asset sync incomplete; continuing with available local files")
	end

	local reloadOK, reloadError = pcall(CW.reloadCoreAssets)
	if not reloadOK then CW.Warn("Core asset reload failed: " .. tostring(reloadError)) end

	CW.State.syncFinished = true
	local callbacks = CW.State.syncCallbacks
	CW.State.syncCallbacks = {}
	for _, callback in ipairs(callbacks) do
		pcall(callback)
	end
end)
end


do
-- UI.lua
local uiOk, uiError = pcall(function()
local CW = getgenv().__CW_CORE_STATE
assert(CW, "CycleWare must be loaded before UI.lua")

for key, value in pairs(CW._SavedSettings or {}) do
	if key ~= "ASSET_SELECTIONS" and key ~= "SOUND_ID" and key ~= "AUTO_RELOAD_LABEL_PATH" then
		local current = CW.Settings[key]
		if current == nil or type(current) == type(value) then
			CW.Settings[key] = value
		end
	end
end

local HttpService = game:GetService("HttpService")

-- Runs one UI section in isolation so a failure in one tab doesn't take the others down.
local function guarded(name, fn)
	local ok, err = pcall(fn)
	if not ok then CW.Warn("UI section '" .. name .. "' failed: " .. tostring(err)) end
	return ok
end

-- Autosave (debounced). Assigned for real in the Settings section.
local scheduleSave = function() end

local UI_URL = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/CWUI.lua"
CW.Log("Downloading CycleWare UI from GitHub")
local fetchOK, uiSource = pcall(function()
	return game:HttpGet(UI_URL)
end)
assert(fetchOK and type(uiSource) == "string" and uiSource ~= "", "Could not download CycleWareUI.lua from GitHub: " .. tostring(uiSource))
CW.Log("CycleWare UI source downloaded")

local loadUI, compileError = loadstring(uiSource)
assert(type(loadUI) == "function", tostring(compileError or "Could not compile CycleWareUI.lua"))
local CWUI = loadUI()
assert(type(CWUI) == "table" and type(CWUI.CreateWindow) == "function", "Invalid CycleWareUI library")

if CW.UIWindow and type(CW.UIWindow.Destroy) == "function" then
	pcall(function() CW.UIWindow:Destroy() end)
end
local Window = CWUI:CreateWindow({ Title = "CW", ToggleKey = false })
CW.UIWindow = Window
Window.ToggleVisibility = Window.Toggle

local function mapControlOptions(options)
	options = options or {}
	return {
		Name = options.Title or options.Name or options.Action,
		Default = options.Default,
		Min = options.Min,
		Max = options.Max,
		Increment = options.Increment or (options.Decimal and 10 ^ -options.Decimal),
		Suffix = options.Suffix,
		Placeholder = options.Placeholder,
		Options = options.Options,
		MaxHeight = options.MaxHeight,
		Callback = options.Callback,
	}
end

local function withSave(callback)
	return function(...)
		if callback then callback(...) end
		scheduleSave()
	end
end

local function wrapSection(section)
	local adapter = {}
	function adapter:Toggle(control)
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddToggle(o)
	end
	function adapter:Slider(control)
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddSlider(o)
	end
	function adapter:Dropdown(control)
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddDropdown(o)
	end
	function adapter:Gallery(control)
		local o = {}
		for key, value in pairs(control) do o[key] = value end
		o.Callback = withSave(control.Callback)
		return section:AddGallery(o)
	end
	function adapter:Button(control) return section:AddButton(mapControlOptions(control)) end
	function adapter:AddLabel(text) return section:AddLabel(text) end
	function adapter:AddSubSection(name, open)
		return wrapSection(section:AddSubSection({ Name = name, Open = open == nil and true or open }))
	end
	return adapter
end

local function createCompatTab(options)
	options = options or {}
	local tabName = options.Title or options.Name or "Settings"
	local tab = Window:AddTab({ Name = tabName })
	return wrapSection(tab:AddSection({ Name = tabName, Open = true }))
end

Window.Tab = function(_, options) return createCompatTab(options) end

-- Gallery items come from CW.Library.list so paths are normalised the same way everywhere.
local function galleryItems(category, weapon)
	local items = {}
	for _, item in ipairs(CW.Library.list(category, weapon)) do
		table.insert(items, { Name = item.Name, Image = item.Path })
	end
	return items
end

local HitmarkerGallery, CursorGallery, HitSoundDropdown
local textureGalleries = {}
local weaponSoundDropdowns = {}

------------------------------------------------------------------------------
-- Hit sound catalog / weapon sound override logic (no UI here)
------------------------------------------------------------------------------
local hitSoundEntries = {}
local availableHitSounds = {}

local function refreshHitSoundCatalog()
	table.clear(hitSoundEntries)
	table.clear(availableHitSounds)
	local options = {}
	for _, item in ipairs(CW.Library.list("HitSounds")) do
		local label = item.Relative:gsub("^HitSounds/", "")
		item.Label = label
		table.insert(hitSoundEntries, item)
		availableHitSounds[item.Relative] = true
		table.insert(options, label)
	end
	return options
end

local function hitSoundPath(value)
	if type(value) ~= "string" then return nil end
	for _, item in ipairs(hitSoundEntries) do
		if value == item.Label or value == item.Path or value == item.Relative then
			return item.Path
		end
	end
	local relative = CW.Library.relative(value) or value
	if availableHitSounds[relative] then
		return CW.Paths.LIBRARY_ROOT .. "/" .. relative
	end
	return nil
end

local function hitSoundLabel(value)
	local path = hitSoundPath(value)
	local relative = path and CW.Library.relative(path)
	for _, item in ipairs(hitSoundEntries) do
		if item.Relative == relative then return item.Label end
	end
	return nil
end

-- Label for a saved relative path, even if the file isn't on disk yet (e.g. before the first sync).
local function relativeLabel(relative)
	if type(relative) ~= "string" then return nil end
	return (relative:gsub("^HitSounds/", ""))
end

local function applySoundFile(value)
	local path = hitSoundPath(value)
	if not path then return end
	CW.Paths.SOUND_FILE = path
	CW.Library.setSelection("HitSounds", nil, CW.Library.relative(path))
	if CW.reloadSoundAsset then CW.reloadSoundAsset() end
end

local hitSoundOptions = refreshHitSoundCatalog()

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

-- Keep saved overrides even if the file isn't downloaded yet; only drop malformed values.
for weapon, selectedPath in pairs(weaponSoundOverrides) do
	if type(selectedPath) ~= "string" then weaponSoundOverrides[weapon] = nil end
end

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

	local relativePath = weaponSoundOverrides[tool.Name]
	if type(relativePath) ~= "string" then return end
	local filePath = CW.Paths.LIBRARY_ROOT .. "/" .. relativePath
	if not isfile(filePath) then return end
	local loaded, targetId = pcall(getcustomasset, filePath)
	if not loaded or type(targetId) ~= "string" then return end
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

local function normalizeWeaponSoundPath(value)
	local path = hitSoundPath(value)
	local relative = path and CW.Library.relative(path)
	if type(relative) == "string" and availableHitSounds[relative] then return relative end
	return nil
end

local function setWeaponShootSound(weapon, value)
	local relative = normalizeWeaponSoundPath(value)
	if not relative then
		CW.Warn("Choose a sound file from the local HitSounds library for " .. weapon)
		return
	end
	weaponSoundOverrides[weapon] = relative
	scheduleWeaponShootSoundRefresh()
end

------------------------------------------------------------------------------
-- Effects tab (hitmarker + tracers)
------------------------------------------------------------------------------
guarded("Effects", function()
	local EffectsTab = Window:Tab({ Title = "Effects" })

	local function applyHitmarkerFile(value)
		if type(value) ~= "table" or type(value.Path) ~= "string" then return end
		CW.Paths.HITMARKER_FILE = value.Path
		CW.Library.setSelection("Hitmarkers", nil, CW.Library.relative(value.Path))
		if CW.reloadHitmarkerAsset then CW.reloadHitmarkerAsset() end
	end

	HitmarkerGallery = EffectsTab:Gallery({
		Name = "Hitmarker Library",
		Items = galleryItems("Hitmarkers"),
		Default = CW.Paths.HITMARKER_FILE,
		LazyLoad = true,
		Columns = 4,
		MaxHeight = 260,
		Callback = applyHitmarkerFile,
	})

	EffectsTab:Slider({
		Title = "Hitmarker Size",
		Min = 8,
		Max = 200,
		Default = CW.Settings.HITMARKER_SIZE,
		Suffix = "px",
		Flag = "Hitmarker_Size",
		Callback = function(v)
			CW.Settings.HITMARKER_SIZE = v
			if CW.HMTemplate then
				CW.HMTemplate.Size = UDim2.new(0, v, 0, v)
			end
		end,
	})

	EffectsTab:Toggle({
		Title = "Random Rotation",
		Default = CW.Settings.HITMARKER_RANDOM_ROTATION,
		Flag = "Hitmarker_RandomRotation",
		Callback = function(s) CW.Settings.HITMARKER_RANDOM_ROTATION = s end,
	})

	EffectsTab:Toggle({
		Title = "Follow Mouse",
		Default = CW.Settings.HITMARKER_FOLLOW_MOUSE,
		Flag = "Hitmarker_FollowMouse",
		Callback = function(s) CW.Settings.HITMARKER_FOLLOW_MOUSE = s end,
	})

	EffectsTab:Slider({
		Title = "Visible Duration",
		Min = 0,
		Max = 1,
		Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
		Decimal = 2,
		Suffix = "s",
		Flag = "Hitmarker_VisibleDuration",
		Callback = function(v) CW.Settings.HITMARKER_VISIBLE_DURATION = v end,
	})

	EffectsTab:Toggle({
		Title = "Fadeout",
		Default = CW.Settings.HITMARKER_FADEOUT,
		Flag = "Hitmarker_Fadeout",
		Callback = function(s) CW.Settings.HITMARKER_FADEOUT = s end,
	})

	EffectsTab:Slider({
		Title = "Fadeout Duration",
		Min = 0,
		Max = 1,
		Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
		Decimal = 2,
		Suffix = "s",
		Flag = "Hitmarker_FadeoutDuration",
		Callback = function(v) CW.Settings.HITMARKER_FADEOUT_DURATION = v end,
	})

	-- Tracers
	local tracerPalette = {
		Violet = Color3.fromRGB(170, 0, 255),
		Lilac = Color3.fromRGB(200, 100, 255),
		Red = Color3.fromRGB(255, 64, 64),
		Green = Color3.fromRGB(64, 220, 96),
		Cyan = Color3.fromRGB(64, 210, 255),
		White = Color3.fromRGB(255, 255, 255),
	}

	local function colorName(color)
		for name, paletteColor in pairs(tracerPalette) do
			if color == paletteColor then return name end
		end
		return "Violet"
	end
	CW.State.tracerColorName = colorName

	-- Colors are userdata and can't be serialised: they are saved by palette name.
	local savedColor = tracerPalette[CW.Settings.TRACER_COLOR_NAME]
	if savedColor then CW.Settings.TRACER_COLOR = savedColor end
	local savedGlow = tracerPalette[CW.Settings.TRACER_GLOW_COLOR_NAME]
	if savedGlow then CW.Settings.TRACER_GLOW_COLOR = savedGlow end

	EffectsTab:Toggle({
		Title = "Custom Bullet Tracers",
		Default = CW.Settings.CUSTOM_BULLET_TRACERS,
		Flag = "Tracer_Enabled",
		Callback = function(s) CW.Settings.CUSTOM_BULLET_TRACERS = s end,
	})

	EffectsTab:Dropdown({
		Title = "Tracer Color",
		Options = { "Violet", "Lilac", "Red", "Green", "Cyan", "White" },
		Default = colorName(CW.Settings.TRACER_COLOR),
		Callback = function(name)
			CW.Settings.TRACER_COLOR = tracerPalette[name]
		end,
	})

	EffectsTab:Dropdown({
		Title = "Glow Color",
		Options = { "Violet", "Lilac", "Red", "Green", "Cyan", "White" },
		Default = colorName(CW.Settings.TRACER_GLOW_COLOR),
		Callback = function(name)
			CW.Settings.TRACER_GLOW_COLOR = tracerPalette[name]
		end,
	})

	EffectsTab:Slider({
		Title = "Tracer Width",
		Min = 0.01,
		Max = 0.5,
		Default = CW.Settings.TRACER_WIDTH,
		Decimal = 2,
		Flag = "Tracer_Width",
		Callback = function(v) CW.Settings.TRACER_WIDTH = v end,
	})

	EffectsTab:Slider({
		Title = "Tracer Lifetime",
		Min = 0.01,
		Max = 1,
		Default = CW.Settings.TRACER_LIFETIME,
		Decimal = 2,
		Suffix = "s",
		Flag = "Tracer_Lifetime",
		Callback = function(v) CW.Settings.TRACER_LIFETIME = v end,
	})

	EffectsTab:Toggle({
		Title = "Apply To Others",
		Default = CW.Settings.TRACER_APPLY_TO_OTHERS,
		Flag = "Tracer_ApplyToOthers",
		Callback = function(s) CW.Settings.TRACER_APPLY_TO_OTHERS = s end,
	})
end)

------------------------------------------------------------------------------
-- Visuals tab (cursor + weapon textures)
------------------------------------------------------------------------------
guarded("Visuals", function()
	local VisualsTab = Window:Tab({ Title = "Visuals" })

	local function applyCursorFile(value)
		if type(value) ~= "table" or type(value.Path) ~= "string" then return end
		CW.Paths.CURSOR_FILE = value.Path
		CW.Library.setSelection("Cursors", nil, CW.Library.relative(value.Path))
		if CW.reloadCursor then CW.reloadCursor() end
	end

	local cursorSizeDebounceThread = nil

	local function applyCursorSize(v)
		CW.Settings.CURSOR_TARGET_SIZE = v

		if cursorSizeDebounceThread then
			task.cancel(cursorSizeDebounceThread)
			cursorSizeDebounceThread = nil
		end

		cursorSizeDebounceThread = task.delay(2, function()
			cursorSizeDebounceThread = nil
			if CW.reloadCursor then CW.reloadCursor() end
		end)
	end

	CursorGallery = VisualsTab:Gallery({
		Name = "Cursor Library",
		Items = galleryItems("Cursors"),
		Default = CW.Paths.CURSOR_FILE,
		LazyLoad = true,
		Columns = 4,
		MaxHeight = 260,
		Callback = applyCursorFile,
	})

	VisualsTab:Slider({
		Title = "Cursor Size",
		Min = 16,
		Max = 256,
		Default = CW.Settings.CURSOR_TARGET_SIZE,
		Suffix = "px",
		Flag = "Cursor_Size",
		Callback = applyCursorSize,
	})

	for _, weaponName in ipairs(CW.WeaponList or {}) do
		local weapon = weaponName
		local weaponSection = VisualsTab:AddSubSection(weapon, false)
		local selectedPath = CW.Library.selectedPath("Textures", weapon)
		local gallery = weaponSection:Gallery({
			Name = weapon .. " Textures",
			Items = galleryItems("Textures", weapon),
			Default = selectedPath,
			AllowDeselect = true,
			LazyLoad = true,
			Columns = 4,
			MaxHeight = 260,
			Callback = function(item)
				CW.Library.setSelection("Textures", weapon,
					type(item) == "table" and CW.Library.relative(item.Path) or nil)
				if CW.reloadTextures then CW.reloadTextures() end
			end,
		})
		table.insert(textureGalleries, { weapon = weapon, gallery = gallery })
	end
end)

------------------------------------------------------------------------------
-- Hit Sound tab
------------------------------------------------------------------------------
guarded("Hit Sound", function()
	local HitSoundsTab = Window:Tab({ Title = "Hit Sound" })

	HitSoundDropdown = HitSoundsTab:Dropdown({
		Title = "Hit Sound",
		Options = hitSoundOptions,
		Default = hitSoundLabel(CW.Paths.SOUND_FILE),
		Callback = applySoundFile,
	})

	HitSoundsTab:Slider({
		Title = "Hit Sound Volume",
		Min = 0,
		Max = 2,
		Default = CW.Settings.SOUND_VOLUME,
		Decimal = 2,
		Suffix = "x",
		Flag = "Sound_Volume",
		Callback = function(v) CW.Settings.SOUND_VOLUME = v end,
	})
end)

------------------------------------------------------------------------------
-- Weapon Sounds tab
------------------------------------------------------------------------------
guarded("Weapon Sounds", function()
	local WeaponSoundsTab = Window:Tab({ Title = "Weapon Sounds" })

	WeaponSoundsTab:Toggle({
		Title = "Enable Weapon Sound Overrides",
		Default = CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED,
		Flag = "WeaponSoundOverrides_Enabled",
		Callback = function(enabled)
			CW.Settings.WEAPON_SOUND_OVERRIDE_ENABLED = enabled == true
			scheduleWeaponShootSoundRefresh()
		end,
	})

	WeaponSoundsTab:Toggle({
		Title = "Apply to Other Players Locally",
		Default = CW.Settings.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS,
		Flag = "WeaponSoundOverrides_Others",
		Callback = function(enabled)
			CW.Settings.WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS = enabled == true
			scheduleWeaponShootSoundRefresh()
		end,
	})

	for _, weaponName in ipairs(CW.WeaponList or {}) do
		local weapon = weaponName
		local dropdown = WeaponSoundsTab:Dropdown({
			Title = weapon .. " Shoot Sound",
			Options = hitSoundOptions,
			Default = relativeLabel(weaponSoundOverrides[weapon]),
			Callback = function(value)
				setWeaponShootSound(weapon, value)
			end,
		})
		table.insert(weaponSoundDropdowns, { weapon = weapon, control = dropdown })
	end
end)

------------------------------------------------------------------------------
-- Utilities tab
------------------------------------------------------------------------------
guarded("Utilities", function()
	local UtilityTab = Window:Tab({ Title = "Utilities" })

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

	UtilityTab:Toggle({
		Title = "Toggle Sprint with Shift",
		Default = CW.Settings.SHIFT_TOGGLE_ENABLED == true,
		Flag = "Sprint_ToggleEnabled",
		Callback = function(enabled)
			CW.Settings.SHIFT_TOGGLE_ENABLED = enabled == true
			if not CW.Settings.SHIFT_TOGGLE_ENABLED then
				allowSprintRelease = sprinting or allowSprintRelease
				sprinting = false
			end
		end,
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
		Callback = function(enabled)
			CW.Settings.CHAT_TOGGLE_ENABLED = enabled == true
			if not CW.Settings.CHAT_TOGGLE_ENABLED then
				chatHidden = false
				setChatVisible(true)
			end
		end,
	})

	-- Auto reload
	local PlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		or LocalPlayer:WaitForChild("PlayerGui", 5)
	assert(PlayerGui, "PlayerGui did not become available within 5 seconds")
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

	if CW.State.ammoGuiConn then
		CW.State.ammoGuiConn:Disconnect()
	end
	CW.State.ammoGuiConn = PlayerGui.DescendantAdded:Connect(function(instance)
		if not CW.Settings.AUTO_RELOAD_ENABLED or not isTextGui(instance) then return end
		if not (isNamedAmmoLabel(instance) or parseAmmoText(instance.Text)) then return end
		-- Already watching a live label: nothing to rebuild (avoids a full GUI scan per new text).
		for label in pairs(ammoLabelConnections) do
			if label.Parent then return end
		end
		task.defer(rebuildAmmoLabelWatchers)
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
		Callback = function(enabled)
			CW.Settings.AUTO_RELOAD_ENABLED = enabled == true
			rebuildAmmoLabelWatchers()
		end,
	})

	if CW.Settings.AUTO_RELOAD_ENABLED and ammoScanGeneration == 0 then
		rebuildAmmoLabelWatchers()
	end
end)

------------------------------------------------------------------------------
-- Library <-> UI refresh
------------------------------------------------------------------------------
-- Rebuilds every library-backed control from disk. Core assets are reloaded separately
-- by CW.reloadCoreAssets (so this never touches the cursor/texture pipeline).
local function refreshUIFromLibrary()
	if type(CWUI.ClearAssetCache) == "function" then CWUI.ClearAssetCache() end
	hitSoundOptions = refreshHitSoundCatalog()

	local function syncGallery(gallery, category, weapon, selectedFile)
		if not gallery then return end
		gallery:SetItems(galleryItems(category, weapon))
		if selectedFile then gallery:Set(selectedFile, true) else gallery:Clear() end
	end

	syncGallery(HitmarkerGallery, "Hitmarkers", nil, CW.Paths.HITMARKER_FILE)
	syncGallery(CursorGallery, "Cursors", nil, CW.Paths.CURSOR_FILE)
	for _, entry in ipairs(textureGalleries) do
		syncGallery(entry.gallery, "Textures", entry.weapon, CW.Library.selectedPath("Textures", entry.weapon))
	end

	if HitSoundDropdown then
		HitSoundDropdown:Refresh(hitSoundOptions)
		HitSoundDropdown:Set(hitSoundLabel(CW.Paths.SOUND_FILE) or "—", true)
	end
	for _, entry in ipairs(weaponSoundDropdowns) do
		entry.control:Refresh(hitSoundOptions)
		entry.control:Set(relativeLabel(weaponSoundOverrides[entry.weapon]) or "—", true)
	end

	refreshWeaponShootSoundOverrides()
end

------------------------------------------------------------------------------
-- Settings tab (created last so it is also the last tab)
------------------------------------------------------------------------------
guarded("Settings", function()
	local SettingsTab = createCompatTab({ Title = "Settings" })
	Window.ConfigTab = SettingsTab

	SettingsTab:Button({
		Title = "Refresh Asset Library",
		Callback = function()
			local syncOK, syncError = pcall(CW.Library.sync)
			if not syncOK then CW.Warn("Library sync failed: " .. tostring(syncError)) end
			CW.reloadCoreAssets()
			guarded("Library refresh", refreshUIFromLibrary)
			CW.Log("Asset library refreshed.")
		end,
	})

	local function serializableValue(value)
		local valueType = type(value)
		if valueType == "string" or valueType == "number" or valueType == "boolean" then
			return value
		end
		if valueType ~= "table" then return nil end

		local result = {}
		for key, entry in pairs(value) do
			local keyType = type(key)
			local entryType = type(entry)
			if (keyType == "string" or keyType == "number")
				and (entryType == "string" or entryType == "number" or entryType == "boolean") then
				result[key] = entry
			end
		end
		return result
	end

	local function saveSettings()
		local savedSettings = {}
		for key, value in pairs(CW.Settings) do
			if key ~= "ASSET_SELECTIONS" and key ~= "SOUND_ID" and key ~= "AUTO_RELOAD_LABEL_PATH" then
				local serialized = serializableValue(value)
				if serialized ~= nil then savedSettings[key] = serialized end
			end
		end

		-- Tracer colors are Color3 (not serialisable): store the palette name instead.
		local nameOf = CW.State.tracerColorName
		if nameOf then
			savedSettings.TRACER_COLOR_NAME = nameOf(CW.Settings.TRACER_COLOR)
			savedSettings.TRACER_GLOW_COLOR_NAME = nameOf(CW.Settings.TRACER_GLOW_COLOR)
		end

		local out = {
			schemaVersion = 2,
			Settings = savedSettings,
			AssetSelections = CW.Settings.ASSET_SELECTIONS,
		}

		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, out)
		if not ok then
			CW.Warn("Failed to encode settings")
			return
		end

		local saved, err = pcall(writefile, CW.Paths.SETTINGS_FILE, encoded)
		if not saved then CW.Warn("Could not save settings: " .. tostring(err)) end
	end

	-- Debounced autosave: every control callback schedules a save 1s after the last change.
	local saveThread
	scheduleSave = function()
		if saveThread then task.cancel(saveThread) end
		saveThread = task.delay(1, function()
			saveThread = nil
			saveSettings()
		end)
	end

	SettingsTab:Button({
		Title = "Save Settings",
		Action = "Save",
		Callback = function()
			saveSettings()
			CW.Log("Settings saved.")
		end,
	})
end)

scheduleWeaponShootSoundRefresh()
print("[CW] UI loaded.")

-- The asset sync runs independently (Sync module). When it finishes, rebuild the UI lists.
if CW.State.syncFinished then
	guarded("Library refresh", refreshUIFromLibrary)
else
	table.insert(CW.State.syncCallbacks, function()
		guarded("Library refresh", refreshUIFromLibrary)
	end)
end
end)

if not uiOk then
	warn("[CW] UI failed to load: " .. tostring(uiError))
end
end
