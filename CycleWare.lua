-- CycleWare (phase-5). Standalone entry point; module bodies below are kept in isolated scopes.

--=============================================================================
-- Preflight
--   Executor functions this script depends on. Whatever is missing is replaced by a safe
--   stand-in, so a single missing function disables one feature instead of aborting the
--   whole script. What was found is stored in CW.Caps and reported once at startup.
--=============================================================================
local SCRIPT_VERSION = "phase-8"

local CAPS = {
	files = type(isfile) == "function" and type(isfolder) == "function"
		and type(makefolder) == "function" and type(readfile) == "function"
		and type(writefile) == "function" and type(listfiles) == "function",
	customAsset = type(getcustomasset) == "function" or type(getsynasset) == "function",
	getgenv = type(getgenv) == "function",
	gethui = type(gethui) == "function",
	hook = type(hookmetamethod) == "function" and type(getnamecallmethod) == "function",
	request = (type(request) == "function" and request)
		or (type(http_request) == "function" and http_request)
		or (syn and type(syn.request) == "function" and syn.request)
		or (http and type(http.request) == "function" and http.request)
		or nil,
}
do
	local indexed, value = pcall(function() return game.HttpGet end)
	CAPS.httpGet = indexed and type(value) == "function"
end

local getgenv = getgenv
if not CAPS.getgenv then
	local privateEnv = {}
	getgenv = function() return privateEnv end
end
local isfile         = isfile or function() return false end
local isfolder       = isfolder or function() return false end
local makefolder     = makefolder or function() end
local readfile       = readfile or function() error("readfile is unavailable", 0) end
local writefile      = writefile or function() error("writefile is unavailable", 0) end
local delfile        = delfile or function() error("delfile is unavailable", 0) end
local listfiles      = listfiles or function() return {} end
local getcustomasset = getcustomasset or getsynasset
	or function() error("getcustomasset is unavailable", 0) end

-- Runs one module in isolation: if it throws, the error is reported and the modules after it still load.
local function runModule(name, fn)
	local ok, err = xpcall(fn, function(message)
		return debug.traceback(tostring(message), 2)
	end)
	if not ok then
		warn("[CW] Module '" .. name .. "' failed: " .. tostring(err))
	end
	return ok
end

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
			mouseX           = 0,
			mouseY           = 0,
		},
	}
	getgenv().__CW_CORE_STATE = CW
end

CW.IsFirstRun  = isFirstRun
CW.LocalPlayer = LocalPlayer
CW.Mouse       = Mouse

CW.PreviousVersion = CW.Version
CW.Version         = SCRIPT_VERSION
CW.Caps            = CAPS

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

--// Connection registry -------------------------------------------------------------
-- Registering again under the same key disconnects the previous connection, so a re-run
-- REPLACES the old code instead of leaving it active next to the new one.
CW.State.conns = CW.State.conns or {}

function CW.track(key, connection)
	local conns = CW.State.conns
	local previous = conns[key]
	if previous then
		pcall(function() previous:Disconnect() end)
	end
	conns[key] = connection
	return connection
end

function CW.untrack(key)
	local conns = CW.State.conns
	local previous = conns[key]
	conns[key] = nil
	if previous then
		pcall(function() previous:Disconnect() end)
	end
end

function CW.untrackAll()
	for key in pairs(CW.State.conns) do
		CW.untrack(key)
	end
end

--// Teams ----------------------------------------------------------------------------
-- The original rule: anyone on a different team than you is an enemy, whether or not a shot could
-- actually hurt them (a ForceField, or a Guard against a calm Inmate, still counts). The hit sound,
-- the hitmarker and the red cursor use it; the same team gets the green cursor. The team color is
-- read straight from the player, so no cache or signal is needed.
function CW.isEnemy(player)
	return player ~= nil and player ~= LocalPlayer and player.TeamColor ~= LocalPlayer.TeamColor
end

--// HTTP -----------------------------------------------------------------------------
-- The executor's request function goes first: game:HttpGet blocks the main thread on many
-- executors, so it is only the fallback. Raises an error when nothing works.
function CW.httpGet(url)
	local lastError
	local requestFn = CW.Caps.request
	if requestFn then
		local sent, response = pcall(requestFn, { Url = url, Method = "GET" })
		if sent and type(response) == "table" then
			local status = tonumber(response.StatusCode)
			local success = response.Success == true or (status ~= nil and status >= 200 and status < 300)
			if success and type(response.Body) == "string" then return response.Body end
			lastError = "HTTP " .. tostring(response.StatusCode or "?") .. " " .. tostring(response.StatusMessage or "")
		else
			lastError = response
		end
	end

	local ok, result = pcall(function() return game:HttpGet(url) end)
	if ok and type(result) == "string" then return result end
	error(tostring(lastError or result or "no HTTP function available"), 0)
end

--// Startup report -------------------------------------------------------------------
do
	local missing = {}
	if not CAPS.getgenv then table.insert(missing, "getgenv (re-running without rejoining will not be clean)") end
	if not CAPS.files then table.insert(missing, "file functions (asset library, cursor, textures, sounds and saved settings are disabled)") end
	if not CAPS.customAsset then table.insert(missing, "getcustomasset (custom images and sounds are disabled)") end
	if not CAPS.hook then table.insert(missing, "hookmetamethod/getnamecallmethod (hitmarker and hit sound detection is disabled)") end
	if not CAPS.gethui then table.insert(missing, "gethui (using CoreGui instead)") end
	if not CAPS.httpGet and not CAPS.request then table.insert(missing, "HTTP (asset sync and the UI download are disabled)") end
	if #missing > 0 then
		CW.Warn("Missing executor functions: " .. table.concat(missing, "; "))
	end
end

CW.Log(isFirstRun and "First run — initializing." or "Re-run detected — reloading modules and replacing the previous run's connections.")
if not isFirstRun and CW.PreviousVersion == nil then
	CW.Warn("State from an older script version was found. Connections made by that version stay active until you rejoin, so rejoin once for a fully clean update.")
end

CW.Paths.CURSOR_ROOT = "CycleWare"
CW.Paths.LIBRARY_ROOT = CW.Paths.CURSOR_ROOT .. "/Library"
CW.Paths.CURSORS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Cursors"
CW.Paths.HITMARKERS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Hitmarkers"
CW.Paths.HIT_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/HitSounds"
CW.Paths.WEAPON_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/WeaponSounds"
CW.Paths.RELOAD_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/ReloadSounds"
CW.Paths.TEXTURES_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Textures"
CW.Paths.OFFICIAL_FOLDER = "_Official"
CW.Paths.CACHE_FOLDER = CW.Paths.CURSOR_ROOT .. "/Cache"
CW.Paths.GENERATED_FOLDER = CW.Paths.CACHE_FOLDER .. "/Generated"
CW.Paths.TINTED_FOLDER = CW.Paths.GENERATED_FOLDER .. "/Cursors"
CW.Paths.CURSOR_SIG_FILE = CW.Paths.TINTED_FOLDER .. "/cursor.sig"
CW.Paths.MANIFEST_FILE = CW.Paths.LIBRARY_ROOT .. "/manifest.json"
CW.Paths.LIBRARY_REVISION_FILE = CW.Paths.LIBRARY_ROOT .. "/.revision"
CW.Paths.SETTINGS_FILE = CW.Paths.CACHE_FOLDER .. "/ui_settings.json"
CW.Paths.AUDIO_COPIES_FOLDER = CW.Paths.CACHE_FOLDER .. "/Audio"
CW.Paths.AUDIO_PROBE_FILE = CW.Paths.CACHE_FOLDER .. "/audio_probe.json"

CW.Paths.CURSOR_FILE = nil
CW.Paths.HITMARKER_FILE = nil
CW.Paths.SOUND_FILE = nil

-- Everything is off by default; only what the player changes is saved (see saveSettings).
CW.Settings.HITMARKER_SIZE             = numOr(_cfg.HITMARKER_SIZE, 50, 1)
CW.Settings.SOUND_VOLUME               = numOr(_cfg.SOUND_VOLUME, 1, 0)
CW.Settings.CURSOR_TARGET_SIZE         = numOr(_cfg.CURSOR_TARGET_SIZE, 82, 1)
CW.Settings.HITMARKER_VISIBLE_DURATION = numOr(_cfg.HITMARKER_VISIBLE_DURATION, 0.05, 0)
CW.Settings.HITMARKER_FADEOUT_DURATION = numOr(_cfg.HITMARKER_FADEOUT_DURATION, 0.15, 0)

CW.Settings.HITMARKER_RANDOM_ROTATION = boolOr(_cfg.HITMARKER_RANDOM_ROTATION, false)
CW.Settings.HITMARKER_FOLLOW_MOUSE    = boolOr(_cfg.HITMARKER_FOLLOW_MOUSE, false)
CW.Settings.HITMARKER_FADEOUT         = boolOr(_cfg.HITMARKER_FADEOUT, false)

-- Snapshot of the defaults, taken before any saved value is applied. The save routine
-- writes only the settings whose value differs from these.
CW.Defaults = {}
for _, key in ipairs({
	"HITMARKER_SIZE", "SOUND_VOLUME", "CURSOR_TARGET_SIZE", "HITMARKER_VISIBLE_DURATION",
	"HITMARKER_FADEOUT_DURATION", "HITMARKER_RANDOM_ROTATION", "HITMARKER_FOLLOW_MOUSE", "HITMARKER_FADEOUT",
}) do
	CW.Defaults[key] = CW.Settings[key]
end

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
			local savedVersion = tonumber(data.schemaVersion) or 1
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

			-- Files written before schema 3 stored every setting, including toggles that used to be
			-- ON by default. Those toggles are now OFF by default, so the old values are dropped once.
			if savedVersion < 3 then
				local reset = {}
				for _, key in ipairs({
					"AUTO_RELOAD_ENABLED", "WEAPON_SOUND_OVERRIDE_ENABLED", "HITMARKER_RANDOM_ROTATION",
					"HITMARKER_FOLLOW_MOUSE", "HITMARKER_FADEOUT",
				}) do
					if values[key] ~= nil then
						values[key] = nil
						table.insert(reset, key)
					end
				end
				if #reset > 0 then
					CW.Warn("Settings are now off by default. Reset once from the old save: " .. table.concat(reset, ", ") .. ". Turn on what you want; it will be saved.")
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

do
	local loc = UserInputService:GetMouseLocation()
	CW.State.mouseX, CW.State.mouseY = loc.X, loc.Y
end

-- Created on every run and registered with CW.track: a re-run replaces the previous connections.
do
	CW.track("mouseMove", UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		if next(CW.ActiveFollowClones) == nil then return end -- nothing to move

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
	end))
end

runModule("Cache", function()
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
	CW.Paths.WEAPON_SOUNDS_FOLDER,
	CW.Paths.RELOAD_SOUNDS_FOLDER,
	CW.Paths.TEXTURES_FOLDER,
	CW.Paths.CACHE_FOLDER,
	CW.Paths.GENERATED_FOLDER,
	CW.Paths.TINTED_FOLDER,
	CW.Paths.AUDIO_COPIES_FOLDER,
}

function CW.ensureFolders()
	for _, folder in ipairs(ALL_FOLDERS) do
		if not isfolder(folder) then
			pcall(makefolder, folder)
		end
	end
end
CW.ensureFolders()

-- Cooperative yielding for heavy loops (PNG codec, checksums) so the game never freezes.
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

-- Same result as CW.crc32, but hands the thread back to the game now and then. Only call it
-- from a thread that is allowed to yield (the sync thread, a task.spawn, the executor thread).
function CW.crc32Yielding(s)
	local c = 0xFFFFFFFF
	local length = #s
	for i = 1, length do
		c = bxor(_crcT[band(bxor(c, sbyte(s, i)), 0xFF)], rshift(c, 8))
		if i % 65536 == 0 then CW.yieldBudget() end
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

	local ok, asset, reason
	if cfg.audio and CW.Library and CW.Library.audioAsset then
		-- Audio goes through the library: format detected by content, compatibility copy if needed.
		ok, asset, reason = pcall(CW.Library.audioAsset, cfg.file)
		if ok and not asset then ok, asset = false, reason end
	else
		ok, asset = pcall(getcustomasset, cfg.file)
	end
	if not ok or not asset then
		CW.Warn("Could not load " .. cfg.label .. ": " .. tostring(asset))
		return nil, "error"
	end

	CW.Log(cfg.label .. " loaded from " .. cfg.file)
	return asset, nil
end
end)


runModule("AssetLibrary", function()
-- AssetLibrary.lua
local CW = getgenv().__CW_CORE_STATE
local HttpService = game:GetService("HttpService")

local CATEGORY_INFO = {
	Cursors = { folder = CW.Paths.CURSORS_FOLDER, extensions = { png = true } },
	Hitmarkers = { folder = CW.Paths.HITMARKERS_FOLDER, extensions = { png = true } },
	HitSounds = { folder = CW.Paths.HIT_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
}
local SELECTION_KEYS = {
	Cursors = "Cursor",
	Hitmarkers = "Hitmarker",
	HitSounds = "HitSound",
}
-- Categories stored per weapon: <category>/<Weapon>/<file>. The weapon names are the same
-- ones the Textures folders use.
local WEAPON_CATEGORIES = {
	Textures = { folder = CW.Paths.TEXTURES_FOLDER, extensions = { png = true } },
	WeaponSounds = { folder = CW.Paths.WEAPON_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
	ReloadSounds = { folder = CW.Paths.RELOAD_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
}
local ASSET_EXTENSIONS = { png = true, mp3 = true, ogg = true, wav = true, flac = true }
local AUDIO_FORMATS = { mp3 = true, ogg = true, wav = true, flac = true }

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
	local weaponInfo = WEAPON_CATEGORIES[category]
	if weaponInfo then
		return path:match("^" .. category .. "/[^/]+/[^/]+$") ~= nil
			and weaponInfo.extensions[extension] == true
	end
	return false
end

local function detectAssetFormat(data)
	if type(data) ~= "string" or #data < 4 then return "empty or truncated" end

	if data:sub(1, 8) == "\137\80\78\71\13\10\26\10" then return "png" end
	if data:sub(1, 4) == "MM\0\42" or data:sub(1, 4) == "II\42\0" then return "tiff" end
	if data:sub(1, 3) == "\255\216\255" then return "jpeg" end
	if data:sub(1, 4) == "OggS" then return "ogg" end
	if data:sub(1, 3) == "ID3" then return "mp3" end
	local first, second = string.byte(data, 1, 2)
	if first == 0xFF and second and bit32.band(second, 0xE0) == 0xE0 then return "mp3" end
	if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WAVE" then return "wav" end
	if data:sub(1, 4) == "fLaC" then return "flac" end
	if data:match("^%d%d%d:%s") then return "HTTP error response" end
	return "unknown"
end

-- Images must be PNG with a matching extension. Audio is judged by its content only: any of
-- mp3/ogg/wav/flac is accepted whatever the file is called (a WAV named .mp3 is fine).
local function isAudioCategory(category)
	local info = CATEGORY_INFO[category] or WEAPON_CATEGORIES[category]
	return info ~= nil and info.audio == true
end

local function formatMatches(category, path, actual)
	if isAudioCategory(category) then return AUDIO_FORMATS[actual] == true end
	local extension = path:match("%.([%w]+)$")
	return extension ~= nil and actual == extension:lower()
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

-- Directory scans read and validate every file, so the result is cached per category/weapon.
-- The cache is cleared whenever the library can have changed (CW.Library.sync).
local listCache = {}
local audioAssetCache, audioPending = {}, {}

function CW.Library.invalidate()
	table.clear(listCache)
	table.clear(audioAssetCache)
end

local function scanLibrary(category, weapon)
	local info = CATEGORY_INFO[category]
	local weaponInfo = WEAPON_CATEGORIES[category]
	local directories = {}
	if info then
		table.insert(directories, info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, info.folder)
	elseif weaponInfo and type(weapon) == "string" then
		local weaponFolder = weaponInfo.folder .. "/" .. weapon
		table.insert(directories, weaponFolder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, weaponFolder)
	else
		return nil
	end

	local extensions = (info or weaponInfo).extensions
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
						local actualFormat = okData and detectAssetFormat(data) or "unreadable"
						if formatMatches(category, normalized, actualFormat) then
							table.insert(result, {
								Name = filename:gsub("%.[%w]+$", ""),
								Path = CW.Paths.LIBRARY_ROOT .. "/" .. relative,
								Relative = relative,
							})
						elseif not invalidAssetWarnings[normalized] then
							invalidAssetWarnings[normalized] = true
							CW.Warn("Skipped invalid library asset " .. relative .. " (expected " .. (isAudioCategory(category) and "audio" or extension:lower()) .. ", detected " .. actualFormat .. ")")
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

function CW.Library.list(category, weapon)
	local key = tostring(category) .. "|" .. tostring(weapon)
	local cached = listCache[key]
	if not cached then
		cached = scanLibrary(category, weapon)
		if not cached then return {} end
		listCache[key] = cached
	end
	local copy = table.create and table.create(#cached) or {}
	for index, item in ipairs(cached) do
		copy[index] = { Name = item.Name, Path = item.Path, Relative = item.Relative }
	end
	return copy
end

--// Audio assets ------------------------------------------------------------------------
-- getcustomasset decides how to decode a local file from its NAME, so a WAV called .mp3 (or a
-- format the engine only accepts under another name) can fail. For those files a copy is
-- written to the cache folder with a name that works; the original is never touched.
-- Which name works is found once per audio format by loading the copy and checking that the
-- sound has a length (real extension first, then .mp3, then .ogg); the result is remembered
-- in audio_probe.json, so nothing is guessed on later runs. mp3/ogg files with a matching
-- name are played directly, with no probe and no copy.
local STANDARD_AUDIO = { mp3 = true, ogg = true }
local MAX_AUDIO_BYTES = 20 * 1024 * 1024 -- Roblox's documented limit for audio files
local audioWarned = {}
local audioProbe

local function warnAudioOnce(key, message)
	if audioWarned[key] then return end
	audioWarned[key] = true
	CW.Warn(message)
end

local function loadAudioProbe()
	if audioProbe then return audioProbe end
	audioProbe = {}
	local okExists, exists = pcall(isfile, CW.Paths.AUDIO_PROBE_FILE)
	if okExists and exists then
		local okRead, raw = pcall(readfile, CW.Paths.AUDIO_PROBE_FILE)
		if okRead then
			local decoded, data = pcall(HttpService.JSONDecode, HttpService, raw)
			if decoded and type(data) == "table" then
				for format, extension in pairs(data) do
					if AUDIO_FORMATS[format] and AUDIO_FORMATS[extension] then audioProbe[format] = extension end
				end
			end
		end
	end
	return audioProbe
end

local function saveAudioProbe()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, audioProbe or {})
	if ok then pcall(writefile, CW.Paths.AUDIO_PROBE_FILE, encoded) end
end

-- True when the engine can load the asset as a sound with a length above zero.
local function audioLoads(asset)
	local ok, loaded = pcall(function()
		local sound = Instance.new("Sound")
		sound.Volume = 0
		sound.SoundId = asset
		sound.Parent = game:GetService("SoundService")
		local done = false
		task.spawn(function()
			pcall(function() game:GetService("ContentProvider"):PreloadAsync({ sound }) end)
			done = true
		end)
		local deadline = os.clock() + 4
		while not done and os.clock() < deadline do task.wait(0.05) end
		local settle = os.clock() + 0.5
		while sound.TimeLength <= 0 and os.clock() < settle do task.wait(0.05) end
		local length = sound.TimeLength
		sound:Destroy()
		return length > 0
	end)
	return ok and loaded == true
end

local function audioCopyPath(path, data, extension)
	local name = path:match("([^/\\]+)$") or "audio"
	name = name:gsub("%.[%w]+$", "")
	name = name:gsub("[^%w_%-]", "_")
	return CW.Paths.AUDIO_COPIES_FOLDER .. "/" .. string.format("%08x", CW.crc32Yielding(data)) .. "_" .. name .. "." .. extension
end

local function compatAudioAsset(path, data, format, originalExtension)
	local probe = loadAudioProbe()
	local known = probe[format] ~= nil
	local candidates = {}
	if known then
		candidates[1] = probe[format]
	else
		for _, extension in ipairs({ format, "mp3", "ogg" }) do
			if not table.find(candidates, extension) then table.insert(candidates, extension) end
		end
	end

	CW.Library.ensureFolder(CW.Paths.AUDIO_COPIES_FOLDER)
	for _, extension in ipairs(candidates) do
		local target = path
		if extension ~= originalExtension then
			target = audioCopyPath(path, data, extension)
			local okFile, exists = pcall(isfile, target)
			if not (okFile and exists) then
				if not pcall(writefile, target, data) then target = nil end
			end
		end
		if target then
			local okAsset, asset = pcall(getcustomasset, target)
			if okAsset and type(asset) == "string" and (known or audioLoads(asset)) then
				if not known then
					probe[format] = extension
					saveAudioProbe()
					CW.Log("Audio probe: " .. format .. " files load as ." .. extension .. " on this executor")
				end
				return asset
			end
			-- This name did not work: do not leave its copy behind.
			if target ~= path and not known then pcall(delfile, target) end
		end
	end
	if known then
		probe[format] = nil -- the remembered name stopped working: probe again next time
		saveAudioProbe()
	end
	return nil
end

-- Returns the asset id for an audio file, or nil plus the reason.
function CW.Library.audioAsset(path)
	if type(path) ~= "string" then return nil, "invalid path" end
	local cached = audioAssetCache[path]
	if cached then return cached end
	while audioPending[path] do task.wait(0.05) end
	cached = audioAssetCache[path]
	if cached then return cached end

	audioPending[path] = true
	local ok, asset, reason = pcall(function()
		local okRead, data = pcall(readfile, path)
		if not okRead or type(data) ~= "string" then return nil, "unreadable" end
		local format = detectAssetFormat(data)
		if not AUDIO_FORMATS[format] then return nil, "not an audio file (detected " .. format .. ")" end
		if #data > MAX_AUDIO_BYTES then
			warnAudioOnce(path, (CW.Library.relative(path) or path) .. " is larger than 20 MB; Roblox may refuse to play it")
		end

		local originalExtension = (path:match("%.([%w]+)$") or ""):lower()
		if STANDARD_AUDIO[format] and originalExtension == format then
			local okAsset, direct = pcall(getcustomasset, path)
			if okAsset and direct then return direct end
			return nil, tostring(direct)
		end

		local compat = compatAudioAsset(path, data, format, originalExtension)
		if compat then return compat end

		-- Last resort: the original file, as is.
		local okAsset, direct = pcall(getcustomasset, path)
		if okAsset and direct then
			warnAudioOnce("fallback|" .. path, "Could not verify that " .. (CW.Library.relative(path) or path) .. " plays as " .. format .. "; using the original file")
			return direct
		end
		return nil, tostring(direct)
	end)
	audioPending[path] = nil

	if ok and asset then
		audioAssetCache[path] = asset
		return asset
	end
	return nil, ok and reason or tostring(asset)
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

-- Returns the file to use for a category (and weapon) plus its relative path.
-- A saved selection whose file is not on disk yet is NOT overwritten: it stays saved and is
-- used again as soon as the file exists.
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
	if category == "Textures" then return nil, nil end

	-- Nothing chosen (or the chosen file is missing): the first file is used, but it is NOT
	-- saved as a selection. Only a choice made by the player is persisted.
	local first = files[1]
	if not first then return nil, nil end
	return first.Path, first.Relative
end

local function officialDestination(category, relativePath)
	local weaponInfo = WEAPON_CATEGORIES[category]
	if weaponInfo then
		local weapon, filename = relativePath:match("^" .. category .. "/([^/]+)/([^/]+)$")
		if not validWeaponName(weapon) then return nil end
		return weaponInfo.folder .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER .. "/" .. filename
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
	for _, info in pairs(WEAPON_CATEGORIES) do
		local ok, weaponFolders = pcall(listfiles, info.folder)
		if ok and type(weaponFolders) == "table" then
			for _, weaponFolder in ipairs(weaponFolders) do
				pruneFolder((tostring(weaponFolder):gsub("\\", "/")) .. "/" .. CW.Paths.OFFICIAL_FOLDER)
			end
		end
	end
end

local function syncImpl()
	local manifestURL = _cfg.ASSET_MANIFEST_URL
	if type(manifestURL) ~= "string" or manifestURL == "" then
		CW.Log("Asset manifest URL is unset; using files already in Library")
		return false
	end
	if not CW.Caps.files then
		CW.Warn("File functions unavailable; skipping the asset sync")
		return false
	end
	CW.Log("Fetching asset manifest")
	if not (CW.Caps.httpGet or CW.Caps.request) then
		CW.Warn("HTTP unavailable; using files already in Library")
		return false
	end

	local fetched, raw = pcall(CW.httpGet, manifestURL)
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
	-- False when an entry of the manifest itself is malformed: the list of files to keep is then
	-- not reliable, so nothing is removed from the _Official folders in that run.
	local entriesTrusted = true

	for category, entries in pairs(manifest.assets) do
		local weaponInfo = WEAPON_CATEGORIES[category]
		if weaponInfo and type(entries) == "table" then
			-- assets.<Category>[Weapon] = { { path = "<Category>/<Weapon>/<file>", crc32 = "..." }, ... }
			for weapon, weaponEntries in pairs(entries) do
				if validWeaponName(weapon) and type(weaponEntries) == "table" then
					ensureFolderPath(weaponInfo.folder .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER)
					for _, entry in ipairs(weaponEntries) do
						local manifestWeapon
						if type(entry) == "table" and type(entry.path) == "string" then
							manifestWeapon = entry.path:match("^" .. category .. "/([^/]+)/")
						end
						if type(entry) == "table" and manifestWeapon == weapon and validManifestPath(category, entry.path) then
							table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
						else
							skipped = skipped + 1
							entriesTrusted = false
							CW.Warn("Skipped invalid " .. category .. " entry in manifest")
						end
					end
				else
					skipped = skipped + 1
					entriesTrusted = false
				end
			end
		elseif CATEGORY_INFO[category] and type(entries) == "table" then
			for _, entry in ipairs(entries) do
				if type(entry) == "table" and validManifestPath(category, entry.path) then
					table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
				else
					skipped = skipped + 1
					entriesTrusted = false
					CW.Warn("Skipped invalid " .. category .. " entry in manifest")
				end
			end
		else
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
			entriesTrusted = false
		else
			local destinationRelative = libraryRelative(destination)
			if destinationRelative then expected[destinationRelative] = true end
			ensureFolderPath(destination:match("^(.*)/[^/]+$"))

			-- Validate cached bytes before trusting the extension or manifest revision.
			local needsDownload = true
			if isfile(destination) then
				local ok, existing = pcall(readfile, destination)
				local actualFormat = ok and detectAssetFormat(existing) or "unreadable"
				if formatMatches(entry.category, entry.path, actualFormat) then
					if entry.crc32 then
						local expectedCRC = tostring(entry.crc32):lower():gsub("^0x", "")
						needsDownload = string.format("%08x", CW.crc32Yielding(existing)):lower() ~= expectedCRC
					else
						needsDownload = previousRevision ~= revision
					end
				else
					CW.Warn("Cached asset " .. entry.path .. " is invalid (detected " .. actualFormat .. "); downloading again")
				end
			end

			if needsDownload then
				local remotePath = encodeURLPath(entry.path)
				local downloaded, bytes = pcall(CW.httpGet, baseURL .. "/" .. remotePath)
				if downloaded and type(bytes) == "string" then
					local actualFormat = detectAssetFormat(bytes)
					local expectedFormat = isAudioCategory(entry.category) and "audio" or entry.path:match("%.([%w]+)$"):lower()
					local expectedCRC = entry.crc32 and tostring(entry.crc32):lower():gsub("^0x", "")
					local actualCRC = string.format("%08x", CW.crc32Yielding(bytes)):lower()
					if not formatMatches(entry.category, entry.path, actualFormat) then
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

	-- Persist a valid manifest revision even when a few entries fail. Good files stay cached,
	-- while missing/invalid paths are retried because their files fail validation.
	pcall(writefile, CW.Paths.LIBRARY_REVISION_FILE, revision)
	-- Official files that are no longer in the manifest (for example a cursor removed from the
	-- repository) are deleted from the _Official folders. This no longer depends on every other
	-- download having succeeded; user files outside _Official are never touched.
	if #pending > 0 then
		if entriesTrusted then
			pruneOfficial(expected)
		else
			CW.Warn("The manifest has invalid entries; obsolete official files were not removed this time")
		end
	end
	if complete then
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
	CW.Library.invalidate() -- files may have been added or removed by hand since the last scan
	local ok, result = pcall(syncImpl)
	CW.Library.invalidate() -- ... and the sync itself may have written new ones
	CW.State.syncing = false
	CW.State.lastSyncResult = ok and result == true
	if not ok then error(result, 0) end
	return result
end

CW.Paths.CURSOR_FILE = CW.Library.selectedPath("Cursors")
CW.Paths.HITMARKER_FILE = CW.Library.selectedPath("Hitmarkers")
CW.Paths.SOUND_FILE = CW.Library.selectedPath("HitSounds")
end)

runModule("PNG", function()
-- PNG.lua
local CW = getgenv().__CW_CORE_STATE

local floor   = math.floor
local mmin    = math.min
local mmax    = math.max
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
	return u32be(#data)..p..u32be(CW.crc32Yielding(p))
end

-- Deflate "stored" blocks (no compression). The cursor files are small, local and only read by
-- the engine, so skipping compression makes the encoder dramatically faster than the old
-- bit-by-bit Huffman writer. Each block holds at most 65535 bytes.
local function deflateStored(raw)
	local parts = {}
	local total = #raw
	local pos = 1
	repeat
		local len = mmin(65535, total - pos + 1)
		local final = (pos + len > total) and 1 or 0
		local nlen = bxor(len, 0xFFFF)
		parts[#parts + 1] = schar(final, band(len, 0xFF), rshift(len, 8), band(nlen, 0xFF), rshift(nlen, 8))
		parts[#parts + 1] = raw:sub(pos, pos + len - 1)
		pos = pos + len
	until pos > total
	return tconcat(parts)
end

function CW.encodePNG(px, w, h)
	local rows = {}
	local rowLen = w * 4
	for y = 0, h - 1 do
		local base = y * rowLen
		local parts = { "\0" }
		for s = 1, rowLen, 4096 do
			parts[#parts + 1] = schar(tunpack(px, base + s, base + mmin(s + 4095, rowLen)))
		end
		rows[y + 1] = tconcat(parts)
		if y % 16 == 0 then CW.yieldBudget() end
	end
	local raw = tconcat(rows)
	return "\137\80\78\71\13\10\26\10"
		.. pngChunk("IHDR", u32be(w)..u32be(h).."\8\6\0\0\0")
		.. pngChunk("IDAT", "\120\1"..deflateStored(raw)..u32be(adler32(raw)))
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
			-- Stored block. The bit reader may already have prefetched whole bytes beyond the
			-- block header, so after discarding the partial byte those bytes are handed back
			-- (pos moves back) before the LEN/NLEN fields and the raw data are read.
			local partial = bitcount % 8
			if partial > 0 then readbits(partial) end
			pos = pos - floor(bitcount / 8)
			bitbuf, bitcount = 0, 0
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

-- Smooth resize. Shrinking averages every source pixel under the target pixel (box filter),
-- enlarging interpolates (bilinear). Colors are weighted by alpha, so transparent edges do
-- not bleed dark fringes into the cursor.
function CW.resizePixels(px, w, h, tw, th)
	if tw == w and th == h then return px, w, h end
	local out = {}
	local sx, sy = w / tw, h / th
	local ceil = math.ceil

	local function acc(i, weight, sr, sg, sb, sa)
		local a = (px[i + 3] or 0) * weight
		return sr + (px[i] or 0) * a, sg + (px[i + 1] or 0) * a, sb + (px[i + 2] or 0) * a, sa + a
	end

	for y = 0, th - 1 do
		if y % 4 == 0 then CW.yieldBudget() end
		for x = 0, tw - 1 do
			local dst = (y * tw + x) * 4 + 1
			local sr, sg, sb, sa = 0, 0, 0, 0
			local alpha

			if sx > 1 or sy > 1 then
				local x0 = mmin(floor(x * sx), w - 1)
				local x1 = mmin(mmax(x0, ceil((x + 1) * sx) - 1), w - 1)
				local y0 = mmin(floor(y * sy), h - 1)
				local y1 = mmin(mmax(y0, ceil((y + 1) * sy) - 1), h - 1)
				local count = 0
				for yy = y0, y1 do
					for xx = x0, x1 do
						sr, sg, sb, sa = acc((yy * w + xx) * 4 + 1, 1, sr, sg, sb, sa)
						count = count + 1
					end
				end
				alpha = sa / count
			else
				local fx = mmax(0, (x + 0.5) * sx - 0.5)
				local fy = mmax(0, (y + 0.5) * sy - 0.5)
				local x0, y0 = mmin(floor(fx), w - 1), mmin(floor(fy), h - 1)
				local x1, y1 = mmin(x0 + 1, w - 1), mmin(y0 + 1, h - 1)
				local tx, ty = fx - x0, fy - y0
				sr, sg, sb, sa = acc((y0 * w + x0) * 4 + 1, (1 - tx) * (1 - ty), sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y0 * w + x1) * 4 + 1, tx * (1 - ty), sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y1 * w + x0) * 4 + 1, (1 - tx) * ty, sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y1 * w + x1) * 4 + 1, tx * ty, sr, sg, sb, sa)
				alpha = sa
			end

			if sa > 0 then
				out[dst]     = mmin(255, floor(sr / sa + 0.5))
				out[dst + 1] = mmin(255, floor(sg / sa + 0.5))
				out[dst + 2] = mmin(255, floor(sb / sa + 0.5))
				out[dst + 3] = mmin(255, floor(alpha + 0.5))
			else
				out[dst], out[dst + 1], out[dst + 2], out[dst + 3] = 0, 0, 0, 0
			end
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
end)


runModule("Cursor", function()
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
	-- "|fit" marks the aspect-preserving resize, so caches made by older versions are rebuilt.
	return CW.computeFileSignature(
		CW.Paths.CURSOR_FILE, "cur",
		"|size:"..tostring(CW.Settings.CURSOR_TARGET_SIZE).."|fit"..tintSig
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
	-- Stored by the previous version, which forced MouseIconEnabled back on. That fought the
	-- game's sniper scope (it hides the cursor on purpose), so it is no longer done.
	if CW.State.enableConn then
		pcall(function() CW.State.enableConn:Disconnect() end)
		CW.State.enableConn = nil
	end

	CW.State.enforcerConn = UserInputService:GetPropertyChangedSignal("MouseIcon"):Connect(function()
		if CW.State.settingCursor or CW.State.scoped then return end
		if not CW.State.cursorsReady or not CW.State.currentCursorKey then return end
		local expected = CW.Assets[CW.State.currentCursorKey]
		if expected and UserInputService.MouseIcon ~= expected then
			CW.State.settingCursor = true
			UserInputService.MouseIcon = expected
			CW.State.settingCursor = false
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

	-- The longest side becomes the target size and the other side follows the image's aspect
	-- ratio, so non-square cursors are no longer stretched.
	local targetSize = CW.Settings.CURSOR_TARGET_SIZE
	if targetSize then
		local scale = targetSize / math.max(w, h)
		local tw = math.max(1, math.floor(w * scale + 0.5))
		local th = math.max(1, math.floor(h * scale + 0.5))
		px, w, h = CW.resizePixels(px, w, h, tw, th)
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

-- The codec yields, so runs are serialised: a request made while one is running marks the
-- state dirty and triggers exactly one more pass with the latest settings.
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

-- Sniper scope. While the game's scope frame is open, the game hides the cursor on purpose.
-- The custom cursor stays hidden for exactly that time (nothing is drawn over the scope and the
-- game's own crosshair does not come back), and it is restored as soon as the scope closes.
local function restoreCursorIcon()
	local url = CW.State.cursorsReady and CW.Assets[CW.State.currentCursorKey or "white"]
	if url then
		CW.State.settingCursor = true
		UserInputService.MouseIcon = url
		CW.State.settingCursor = false
	end
end

local function watchScope()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 30)
	local crosshairGui = playerGui and playerGui:WaitForChild("CrosshairGui", 30)
	local scopeFrame = crosshairGui and crosshairGui:WaitForChild("ScopeFrame", 30)
	if not scopeFrame then return end

	local function update()
		if scopeFrame.Visible then
			CW.State.scoped = true
			UserInputService.MouseIconEnabled = false
			-- Per frame, and only while scoped: whatever turns the icon back on is undone.
			CW.track("scopeHide", RunService.PreRender:Connect(function()
				if UserInputService.MouseIconEnabled then UserInputService.MouseIconEnabled = false end
			end))
		else
			CW.State.scoped = false
			CW.untrack("scopeHide")
			UserInputService.MouseIconEnabled = true
			restoreCursorIcon()
		end
	end
	CW.track("scopeWatch", scopeFrame:GetPropertyChangedSignal("Visible"):Connect(update))
	update()
end
task.spawn(watchScope)

-- Registered with CW.track: a re-run replaces the loop with this version's code.
do
	-- Mouse.Target is a raycast, so it is sampled 25 times per second instead of every frame.
	local CURSOR_CHECK_INTERVAL = 0.04
	local nextCursorCheck = 0
	CW.track("cursorLoop", RunService.PreRender:Connect(function()
		if not CW.State.cursorsReady then return end
		local now = os.clock()
		if now < nextCursorCheck then return end
		nextCursorCheck = now + CURSOR_CHECK_INTERVAL
		local Target = Mouse.Target
		if Target == CW.State.lastTarget then return end
		CW.State.lastTarget = Target
		if not Target or not Target.Parent then setOSCursor("white"); return end

		local Player = Players:GetPlayerFromCharacter(Target.Parent)
			or (Target.Parent.Parent and Players:GetPlayerFromCharacter(Target.Parent.Parent))

		if Player and Player ~= LocalPlayer then
			setOSCursor(Player.TeamColor == LocalPlayer.TeamColor and "green" or "red")
		else
			setOSCursor("white")
		end
	end))
end
end)

runModule("Hitmarker", function()
-- Hitmarker.lua
local CW = getgenv().__CW_CORE_STATE

local ContentProvider = game:GetService("ContentProvider")

-- Parents the GUI to the first container that accepts it: gethui() when the executor has it,
-- otherwise CoreGui, otherwise PlayerGui.
local function attachGui(gui)
	local candidates = {}
	if type(gethui) == "function" then
		local ok, container = pcall(gethui)
		if ok and typeof(container) == "Instance" then table.insert(candidates, container) end
	end
	local okCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if okCore and coreGui then table.insert(candidates, coreGui) end
	local playerGui = CW.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then table.insert(candidates, playerGui) end

	for _, container in ipairs(candidates) do
		local attached = pcall(function() gui.Parent = container end)
		if attached and gui.Parent == container then return true end
	end
	return false
end

-- Created on the first run, and again on a later run if the GUI is missing or was destroyed.
if not CW.IAPortable or not CW.IAPortable.Parent then
	if CW.IAPortable then pcall(function() CW.IAPortable:Destroy() end) end

	local gui = Instance.new("ScreenGui")
	gui.Name           = "CW_SA"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder   = 9998
	if not attachGui(gui) then
		CW.Warn("Could not parent the hitmarker GUI; hitmarkers will not be displayed")
	end
	CW.IAPortable = gui
end

if not CW.HMTemplate then
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

	-- Preload in the background so the first hitmarker is not blank.
	if asset then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync({ CW.HMTemplate }) end)
		end)
	end
end

CW.reloadHitmarkerAsset = reloadHitmarker
reloadHitmarker()
end)


runModule("Sound", function()
-- Sound.lua
local CW = getgenv().__CW_CORE_STATE

local SoundService    = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Debris          = game:GetService("Debris")

-- A few Sound objects are created ONCE when the hit sound is (re)loaded and preloaded with
-- ContentProvider. A hit then only rewinds one of them and calls :Play(), which is immediate.
-- They are used round-robin so rapid hits overlap instead of cutting each other off.
-- If the pool is unavailable for any reason, a fresh Sound per hit is used as a fallback.

local POOL_SIZE = 4

local function destroyPool()
	local pool = CW.State.hitSoundPool
	CW.State.hitSoundPool = nil
	CW.State.hitSoundIndex = 0
	if pool then
		for _, sound in ipairs(pool) do
			pcall(function() sound:Destroy() end)
		end
	end
end
CW.State.destroyHitSoundPool = destroyPool

local function buildPool(assetId)
	destroyPool()

	local pool = {}
	for _ = 1, POOL_SIZE do
		local ok, sound = pcall(function()
			local snd = Instance.new("Sound")
			snd.Name     = "CW_HitSound"
			snd.SoundId  = assetId
			snd.Volume   = CW.Settings.SOUND_VOLUME
			snd.Parent   = SoundService
			return snd
		end)
		if ok and sound then pool[#pool + 1] = sound end
	end
	if #pool == 0 then
		CW.Warn("Could not create the hit sound pool; falling back to on-demand sounds")
		return
	end

	CW.State.hitSoundPool = pool

	task.spawn(function()
		local ok, err = pcall(function() ContentProvider:PreloadAsync(pool) end)
		if not ok then CW.Log("Hit sound preload skipped: " .. tostring(err)) end
	end)
end

local function reloadSound()
	local asset, failReason = CW.loadLibraryAsset({
		file = CW.Paths.SOUND_FILE,
		label = "hit sound",
		audio = true,
	})
	if asset then
		CW.Settings.SOUND_ID = asset
		buildPool(asset)
	elseif failReason == "missing" or failReason == "error" then
		CW.Settings.SOUND_ID = nil
		destroyPool()
	end
end

CW.reloadSoundAsset = reloadSound
reloadSound()

local function playOnDemand()
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

function CW.playHitSound()
	if not CW.Settings.SOUND_ID then return end

	local pool = CW.State.hitSoundPool
	if pool and #pool > 0 then
		local index = ((CW.State.hitSoundIndex or 0) % #pool) + 1
		CW.State.hitSoundIndex = index
		local sound = pool[index]
		local ok = pcall(function()
			sound.Volume       = CW.Settings.SOUND_VOLUME
			sound.TimePosition = 0
			sound:Play()
		end)
		if ok then return end
	end

	playOnDemand()
end
end)


runModule("Texture", function()
-- Texture.lua
local CW = getgenv().__CW_CORE_STATE

local ContentProvider   = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = CW.LocalPlayer

CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER)

-- Two kinds of weapons can be textured:
--  * Regular guns have exactly one MeshPart, and that part carries the texture.
--  * FAL and M700 have no MeshPart: they are built from many block pieces. For them a custom
--    MeshPart (the whole gun as one model with proper UVs) is built and welded to the Handle, and
--    the original pieces are hidden while a texture is selected. Deselecting the texture removes
--    the custom mesh and shows the original pieces again.
local CUSTOM_MESH_WEAPONS = {
	["FAL"] = {
		meshId   = "rbxassetid://90772329772088",
		meshName = "FAL/Meshes",
		hide     = { ["Smooth Block Model"] = true, ["Black"] = true },
		offset   = Vector3.new(0.05, 0.2, -0.55),
		rotation = Vector3.new(0, 90, 0),
		size     = Vector3.new(0.4, 0.4, 0.4),
	},
	["M700"] = {
		meshId   = "rbxassetid://109235772617313",
		meshName = "M700/Meshes",
		hide     = { ["Smooth Block Model"] = true },
		offset   = Vector3.new(0, 0.43, -0.8),
		rotation = Vector3.new(0, 90, 0),
		size     = Vector3.new(1, 1, 1),
	},
}

local WEAPON_LIST = {}
local TEXTURABLE = {}
do
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	for _, tool in ipairs(guns and guns:GetChildren() or {}) do
		if tool:IsA("Tool") and tool:FindFirstChildWhichIsA("MeshPart", true) then
			TEXTURABLE[tool.Name] = true
		end
	end
	if next(TEXTURABLE) == nil then
		for _, name in ipairs({ "AK-47", "M4A1", "M9", "MP5", "Remington 870", "Revolver" }) do TEXTURABLE[name] = true end
	end
	for name in pairs(CUSTOM_MESH_WEAPONS) do TEXTURABLE[name] = true end
	for name in pairs(TEXTURABLE) do table.insert(WEAPON_LIST, name) end
	table.sort(WEAPON_LIST)
end

CW.WeaponList = WEAPON_LIST
CW.Assets.weaponTextures = {}
CW.Settings.ASSET_SELECTIONS.Textures = CW.Settings.ASSET_SELECTIONS.Textures or {}

for _, weaponName in ipairs(WEAPON_LIST) do
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName)
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName .. "/" .. CW.Paths.OFFICIAL_FOLDER)
end

-- Guns that have sounds to replace: every gun of the game that has a ToolProperties module. That
-- includes the Taser, which has no MeshPart (so it is not in WEAPON_LIST) but does shoot and reload.
-- Falls back to WEAPON_LIST when the game's folders are not found.
local SOUND_WEAPONS = {}
do
	local shared = ReplicatedStorage:FindFirstChild("SharedModules")
	local properties = shared and shared:FindFirstChild("ToolProperties")
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	if properties and guns then
		for _, tool in ipairs(guns:GetChildren()) do
			if tool:IsA("Tool") and properties:FindFirstChild(tool.Name) then
				table.insert(SOUND_WEAPONS, tool.Name)
			end
		end
	end
	if #SOUND_WEAPONS == 0 then
		for _, name in ipairs(WEAPON_LIST) do table.insert(SOUND_WEAPONS, name) end
	end
	table.sort(SOUND_WEAPONS)
end
CW.SoundWeaponList = SOUND_WEAPONS

for _, weaponName in ipairs(SOUND_WEAPONS) do
	-- Your own mp3, ogg, wav or flac files go in WeaponSounds/<Weapon>/ (shoot) and ReloadSounds/<Weapon>/ (reload).
	for _, folder in ipairs({ CW.Paths.WEAPON_SOUNDS_FOLDER, CW.Paths.RELOAD_SOUNDS_FOLDER }) do
		CW.Library.ensureFolder(folder .. "/" .. weaponName)
		CW.Library.ensureFolder(folder .. "/" .. weaponName .. "/" .. CW.Paths.OFFICIAL_FOLDER)
	end
end

-- What was changed is remembered on the instances themselves, as attributes. They live and die
-- with the instance (a new tool is a fresh clone) and survive a re-run of the script, so no
-- separate bookkeeping is needed to restore anything.
local ORIGINAL_TEXTURE = "CW_OriginalTexture"        -- on a regular gun's MeshPart
local ORIGINAL_TRANSPARENCY = "CW_OriginalTransparency" -- on the pieces hidden for a custom mesh

-- Returns true when the weapon's mesh was found (and the texture applied or restored).
local function applyRegularTexture(tool)
	local mesh = tool:FindFirstChildWhichIsA("MeshPart", true)
	if not mesh then return false end

	local textureId = CW.Assets.weaponTextures[tool.Name]
	local original = mesh:GetAttribute(ORIGINAL_TEXTURE)
	if textureId then
		if original == nil then mesh:SetAttribute(ORIGINAL_TEXTURE, mesh.TextureID) end
		if mesh.TextureID ~= textureId then
			local ok, err = pcall(function() mesh.TextureID = textureId end)
			if not ok then CW.Warn("Could not apply texture to " .. tool.Name .. ": " .. tostring(err)) end
		end
	elseif original ~= nil then
		local ok, err = pcall(function() mesh.TextureID = original end)
		if ok then
			mesh:SetAttribute(ORIGINAL_TEXTURE, nil)
		else
			CW.Warn("Could not restore the original texture of " .. tool.Name .. ": " .. tostring(err))
		end
	end
	return true
end

local function buildCustomMesh(tool, cfg)
	local handle = tool:FindFirstChild("Handle")
	if not handle then return nil end

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
	mesh.CFrame = handle.CFrame
		* CFrame.new(cfg.offset)
		* CFrame.Angles(math.rad(cfg.rotation.X), math.rad(cfg.rotation.Y), math.rad(cfg.rotation.Z))
	mesh.Parent = tool

	local weld = Instance.new("WeldConstraint")
	weld.Part0  = handle
	weld.Part1  = mesh
	weld.Parent = mesh
	CW.Log("Custom mesh built for " .. tool.Name)
	return mesh
end

-- Every BasePart of a piece (the piece itself and, for a Model, everything inside it).
local function forEachPart(piece, callback)
	if piece:IsA("BasePart") then callback(piece) end
	for _, descendant in ipairs(piece:GetDescendants()) do
		if descendant:IsA("BasePart") then callback(descendant) end
	end
end

local function hideOriginalPieces(tool, cfg, custom)
	for _, piece in ipairs(tool:GetChildren()) do
		if piece ~= custom and cfg.hide[piece.Name] then
			forEachPart(piece, function(part)
				if part:GetAttribute(ORIGINAL_TRANSPARENCY) == nil then
					part:SetAttribute(ORIGINAL_TRANSPARENCY, part.Transparency)
				end
				if part.Transparency ~= 1 then part.Transparency = 1 end
			end)
		end
	end
end

local function showOriginalPieces(tool)
	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local original = descendant:GetAttribute(ORIGINAL_TRANSPARENCY)
			if original ~= nil then
				descendant.Transparency = original
				descendant:SetAttribute(ORIGINAL_TRANSPARENCY, nil)
			end
		end
	end
end

local function applyCustomTexture(tool, cfg)
	local textureId = CW.Assets.weaponTextures[tool.Name]
	local custom = tool:FindFirstChild(cfg.meshName)
	if textureId then
		if not custom then custom = buildCustomMesh(tool, cfg) end
		if not custom then return false end -- no Handle yet
		hideOriginalPieces(tool, cfg, custom)
		if custom.TextureID ~= textureId then custom.TextureID = textureId end
	else
		if custom then custom:Destroy() end
		showOriginalPieces(tool)
	end
	return true
end

local function applyTexture(tool)
	local cfg = CUSTOM_MESH_WEAPONS[tool.Name]
	if cfg then return applyCustomTexture(tool, cfg) end
	return applyRegularTexture(tool)
end

local function applyToContainer(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") and TEXTURABLE[child.Name] then applyTexture(child) end
	end
end

-- Looked up through CW at call time, so the latest run's code is the one that runs.
CW.applyWeaponTexture = function(tool)
	if tool:IsA("Tool") and TEXTURABLE[tool.Name] then return applyTexture(tool) end
	return true
end

-- A tool arrives with its parts, so one pass is enough; if the mesh (or the Handle) is not there
-- yet, it is retried once shortly after.
local function monitor(container, key)
	CW.track(key, container.ChildAdded:Connect(function(child)
		local apply = CW.applyWeaponTexture
		if apply and not apply(child) then
			task.wait(0.1)
			apply = CW.applyWeaponTexture
			if apply then apply(child) end
		end
	end))
	applyToContainer(container)
end

local function reloadTexturesAndApply()
	local loadedTextures = {}
	local toPreload = {}
	for _, weaponName in ipairs(WEAPON_LIST) do
		local filePath = CW.Library.selectedPath("Textures", weaponName)
		if filePath then
			local ok, asset = pcall(getcustomasset, filePath)
			if ok and asset then
				loadedTextures[weaponName] = asset
				table.insert(toPreload, asset)
			else
				CW.Warn("Could not load selected texture for " .. weaponName)
			end
		end
	end
	CW.Assets.weaponTextures = loadedTextures

	if #toPreload > 0 then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync(toPreload) end)
		end)
	end

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then applyToContainer(backpack) end
	if LocalPlayer.Character then applyToContainer(LocalPlayer.Character) end
end
CW.reloadTextures = reloadTexturesAndApply
reloadTexturesAndApply()

-- Monitors are (re)created on every run, so a re-run replaces the old ones. The Backpack is
-- recreated on every respawn, so the player is always watched for a new one.
do
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then monitor(backpack, "textureBackpack") end
	CW.track("textureBackpackWait", LocalPlayer.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then monitor(child, "textureBackpack") end
	end))

	CW.track("textureCharacterAdded", LocalPlayer.CharacterAdded:Connect(function(character)
		monitor(character, "textureCharacter")
	end))

	if LocalPlayer.Character then
		monitor(LocalPlayer.Character, "textureCharacter")
	end
end
end)


runModule("Tracers", function()
-- Tracers.lua
local CW = getgenv().__CW_CORE_STATE

local Workspace         = game:GetService("Workspace")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = CW.LocalPlayer

-- (boolOr, numOr and _cfg come from the top of the script.)

-- UPPER_CASE is the standard key; the old camelCase keys still work.
local function cfgValue(upperKey, legacyKey)
	if _cfg[upperKey] ~= nil then return _cfg[upperKey] end
	return _cfg[legacyKey]
end

local function colorOr(v, default)
	if typeof(v) == "Color3" then return v end
	return default
end

local function unitOr(v, default) -- a number from 0 to 1 (transparency)
	return math.clamp(numOr(v, default), 0, 1)
end

CW.Settings.CUSTOM_BULLET_TRACERS  = boolOr(cfgValue("CUSTOM_BULLET_TRACERS", "customBulletTracers"), false)
CW.Settings.TRACER_COLOR           = cfgValue("TRACER_COLOR", "tracerColor") or Color3.fromRGB(170, 0, 255)
CW.Settings.TRACER_GLOW_COLOR      = cfgValue("TRACER_GLOW_COLOR", "glowColor") or Color3.fromRGB(200, 100, 255)
CW.Settings.TRACER_WIDTH           = numOr(cfgValue("TRACER_WIDTH", "tracerWidth"), 0.05, 0.01)
CW.Settings.TRACER_LIFETIME        = numOr(cfgValue("TRACER_LIFETIME", "tracerLifetime"), 0.05, 0.01)
CW.Settings.TRACER_TRANSPARENCY    = unitOr(cfgValue("TRACER_TRANSPARENCY", "tracerTransparency"), 0.1)
CW.Settings.TRACER_APPLY_TO_OTHERS = boolOr(cfgValue("TRACER_APPLY_TO_OTHERS", "applyToOthers"), false)
CW.Settings.TRACER_POINT_LIGHT     = boolOr(cfgValue("TRACER_POINT_LIGHT", "pointLight"), false)

-- The Sniper (M700) and the Taser have a tracer of their own. Every other gun is covered by the
-- settings above. A kind's own settings only apply while its ENABLED setting is on; the starting
-- values are the game's own (colour, width, how long the fade takes, starting transparency).
local KIND_DEFAULTS = {
	Sniper = { color = Color3.fromRGB(163, 162, 165), width = 0.17, lifetime = 2.8, transparency = 0.5 },
	Taser  = { color = Color3.fromRGB(4, 175, 236),   width = 0.2,  lifetime = 0.8, transparency = 0.5 },
}
local KINDS = {
	Sniper = { prefix = "TRACER_SNIPER_", original = "_originalCreateSniper" },
	Taser  = { prefix = "TRACER_TASER_",  original = "_originalCreateTaser", surfaceLight = true },
}
for kind, info in pairs(KINDS) do
	local defaults = KIND_DEFAULTS[kind]
	local prefix = info.prefix
	CW.Settings[prefix .. "ENABLED"]      = boolOr(_cfg[prefix .. "ENABLED"], false)
	CW.Settings[prefix .. "COLOR"]        = colorOr(_cfg[prefix .. "COLOR"], defaults.color)
	CW.Settings[prefix .. "WIDTH"]        = numOr(_cfg[prefix .. "WIDTH"], defaults.width, 0.01)
	CW.Settings[prefix .. "LIFETIME"]     = numOr(_cfg[prefix .. "LIFETIME"], defaults.lifetime, 0.01)
	CW.Settings[prefix .. "TRANSPARENCY"] = unitOr(_cfg[prefix .. "TRANSPARENCY"], defaults.transparency)
end

-- Per-gun tracers (every gun except the Sniper and the Taser, which have their own above). Each setting
-- is a map from the gun's name to a value, so it is saved as it is: ENABLED[gun] = true, COLOR[gun] and
-- GLOW[gun] = "rrggbb", WIDTH[gun], LIFETIME[gun], TRANSPARENCY[gun]. A field that was never set for a
-- gun follows the shared Bullet Tracers settings.
local function copyMap(source)
	local map = {}
	if type(source) == "table" then
		for key, value in pairs(source) do
			if type(key) == "string" then map[key] = value end
		end
	end
	return map
end
for _, field in ipairs({ "ENABLED", "COLOR", "GLOW", "WIDTH", "LIFETIME", "TRANSPARENCY" }) do
	CW.Settings["TRACER_GUN_" .. field] = copyMap(_cfg["TRACER_GUN_" .. field])
end

CW.Defaults = CW.Defaults or {}
for _, key in ipairs({
	"CUSTOM_BULLET_TRACERS", "TRACER_COLOR", "TRACER_GLOW_COLOR",
	"TRACER_WIDTH", "TRACER_LIFETIME", "TRACER_TRANSPARENCY", "TRACER_APPLY_TO_OTHERS", "TRACER_POINT_LIGHT",
	"TRACER_SNIPER_ENABLED", "TRACER_SNIPER_COLOR", "TRACER_SNIPER_WIDTH", "TRACER_SNIPER_LIFETIME", "TRACER_SNIPER_TRANSPARENCY",
	"TRACER_TASER_ENABLED", "TRACER_TASER_COLOR", "TRACER_TASER_WIDTH", "TRACER_TASER_LIFETIME", "TRACER_TASER_TRANSPARENCY",
}) do
	CW.Defaults[key] = CW.Settings[key]
end

-- A tracer is yours when you are shooting AND it starts at your own muzzle. Checking only the
-- attribute would also claim the tracers of other players that arrive while you shoot.
-- Returns the Tool you fired it with (its name is the gun's name), or nil.
local function localShotTool(startPos)
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute("Local_IsShooting") ~= true then return nil end
	local muzzle = tool:FindFirstChild("Muzzle")
	if muzzle ~= nil and (muzzle.Position - startPos).Magnitude < 2 then return tool end
	return nil
end

local function isLocalPlayerShot(startPos)
	return localShotTool(startPos) ~= nil
end

-- Which gun made a tracer that is NOT yours. The game tells the client only where the tracer starts
-- and ends and which kind it is (Taser, Sniper or bullet), never who fired it. So: among the players
-- holding a gun of that kind, the one whose Muzzle or Head is nearest to the start. Nothing within
-- MATCH_RADIUS means no match, and the shared Bullet Tracers settings are used instead.
-- (The start is computed by the server; how close it lies to the shooter's Muzzle on this client
-- depends on lag and movement, hence the generous radius. Set CW_CONFIG.TRACER_DEBUG = true to print
-- every match and see how close they are.)
local MATCH_RADIUS = 14
local KIND_BY_NAME = { M700 = "Sniper", Taser = "Taser" } -- used when a tool has no Behavior attribute yet

local function toolKind(tool)
	local behavior = tool:GetAttribute("Behavior")
	if behavior == "Sniper" or behavior == "Taser" then return behavior end
	return KIND_BY_NAME[tool.Name] or "Bullet"
end

local lastMatch = { pos = nil, time = 0, tool = nil } -- the pellets of one shotgun shot share a start

local function findShooterTool(startPos, kind)
	local now = os.clock()
	if lastMatch.pos == startPos and now - lastMatch.time < 0.1 and lastMatch.tool and lastMatch.tool.Parent then
		return lastMatch.tool
	end

	local bestTool, bestPlayer, bestDistance, secondDistance
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local tool = character and character:FindFirstChildOfClass("Tool")
		local muzzle = tool and tool:FindFirstChild("Muzzle") -- only guns have one
		if muzzle and toolKind(tool) == kind then
			local distance = (muzzle.Position - startPos).Magnitude
			local head = character:FindFirstChild("Head")
			if head then distance = math.min(distance, (head.Position - startPos).Magnitude) end
			if bestDistance == nil or distance < bestDistance then
				secondDistance = bestDistance
				bestTool, bestPlayer, bestDistance = tool, player, distance
			elseif secondDistance == nil or distance < secondDistance then
				secondDistance = distance
			end
		end
	end

	local matched = bestTool ~= nil and bestDistance <= MATCH_RADIUS
	if _cfg.TRACER_DEBUG == true then
		print(string.format("[CW] tracer (%s) from %s: %s, nearest holder %s studs away, next %s",
			kind, tostring(startPos), matched and (bestTool.Name .. " held by " .. bestPlayer.Name) or "no match",
			bestDistance and string.format("%.1f", bestDistance) or "-",
			secondDistance and string.format("%.1f", secondDistance) or "-"))
	end

	if not matched then return nil end
	lastMatch.pos, lastMatch.time, lastMatch.tool = startPos, now, bestTool
	return bestTool
end

local gunColorCache = {}
local function gunColor(hex, fallback)
	if type(hex) ~= "string" then return fallback end
	local cached = gunColorCache[hex]
	if cached == nil then
		local ok, color = pcall(Color3.fromHex, hex)
		cached = ok and typeof(color) == "Color3" and color or false
		gunColorCache[hex] = cached
	end
	return cached or fallback
end

local function gunValue(field, weapon)
	local map = CW.Settings["TRACER_GUN_" .. field]
	if type(map) ~= "table" then return nil end
	return map[weapon]
end

local function hasGunTracers()
	local map = CW.Settings.TRACER_GUN_ENABLED
	if type(map) ~= "table" then return false end
	for _, enabled in pairs(map) do
		if enabled == true then return true end
	end
	return false
end

-- The look of one gun's tracer, or nil when that gun has no tracer of its own turned on.
local function gunStyle(weapon)
	if gunValue("ENABLED", weapon) ~= true then return nil end
	local S = CW.Settings
	return {
		color        = gunColor(gunValue("COLOR", weapon), S.TRACER_COLOR),
		glow         = gunColor(gunValue("GLOW", weapon), S.TRACER_GLOW_COLOR),
		width        = math.max(0.01, tonumber(gunValue("WIDTH", weapon)) or S.TRACER_WIDTH),
		life         = math.max(0.01, tonumber(gunValue("LIFETIME", weapon)) or S.TRACER_LIFETIME),
		transparency = math.clamp(tonumber(gunValue("TRANSPARENCY", weapon)) or S.TRACER_TRANSPARENCY, 0, 1),
	}
end

-- The style for a bullet tracer that starts at startPos: the firing gun's own, or nil.
-- Your own shots read the gun straight from the Tool in your hand (exact). Other players' shots are
-- only matched when "apply to others" is on.
local function bulletShotStyle(startPos)
	local tool = localShotTool(startPos)
	if not tool then
		if not CW.Settings.TRACER_APPLY_TO_OTHERS then return nil end
		tool = findShooterTool(startPos, "Bullet")
	end
	return tool and gunStyle(tool.Name) or nil
end

-- Part pool: tracer parts are reused instead of created and destroyed for every bullet
-- (shotgun pellets and automatic weapons make many per second). The PointLight is optional
-- (TRACER_POINT_LIGHT, off by default): it is created once per pooled part and only switched
-- on or off afterwards, so enabling it never creates a new light per bullet.
local MAX_POOL = 48
local pool = CW.State.tracerPool
if not pool then
	pool = {}
	CW.State.tracerPool = pool
end

local function newTracerPart()
	local part = Instance.new("Part")
	part.Anchored   = true
	part.CanCollide = false
	part.CanQuery   = false
	part.CanTouch   = false
	part.CastShadow = false
	part.Material   = Enum.Material.Neon
	return part
end

local function acquirePart(parent)
	while #pool > 0 do
		local part = table.remove(pool)
		if pcall(function() part.Parent = parent end) then return part end
	end
	local part = newTracerPart()
	part.Parent = parent
	return part
end

-- A pooled part may still carry a light from a previous use: lights are switched off on every
-- acquire and only the tracer that needs one switches it back on.
local function resetLights(part)
	for _, name in ipairs({ "CW_Light", "CW_Surface" }) do
		local light = part:FindFirstChild(name)
		if light then light.Enabled = false end
	end
end

local function releasePart(part)
	pcall(function() part.Parent = nil end)
	if #pool < MAX_POOL then
		pool[#pool + 1] = part
	else
		pcall(function() part:Destroy() end)
	end
end

-- style (optional): { color, glow, width, life, transparency } of one gun; without it the shared
-- Bullet Tracers settings are used.
local function createEnergyTracer(startPos, endPos, style)
	local camera = Workspace.CurrentCamera
	if not camera then error("no current camera", 0) end

	local S = CW.Settings
	local color        = style and style.color or S.TRACER_COLOR
	local glowColor    = style and style.glow or S.TRACER_GLOW_COLOR
	local width        = style and style.width or S.TRACER_WIDTH
	local life         = style and style.life or S.TRACER_LIFETIME
	local transparency = style and style.transparency or S.TRACER_TRANSPARENCY

	local distance = (startPos - endPos).Magnitude
	local midpoint = (startPos + endPos) / 2

	local core = acquirePart(camera)
	resetLights(core)
	core.Color        = color
	core.Size         = Vector3.new(width, width, distance)
	core.CFrame       = CFrame.new(midpoint, endPos)
	core.Transparency = transparency

	local light = core:FindFirstChild("CW_Light")
	if CW.Settings.TRACER_POINT_LIGHT then
		if not light then
			light = Instance.new("PointLight")
			light.Name       = "CW_Light"
			light.Range      = 8
			light.Brightness = 2
			light.Parent     = core
		end
		light.Color   = color
		light.Enabled = true
	elseif light then
		light.Enabled = false
	end

	local glow = acquirePart(camera)
	resetLights(glow)
	glow.Color        = glowColor
	glow.Size         = Vector3.new(width * 2, width * 2, distance)
	glow.CFrame       = core.CFrame
	-- The glow is always fainter than the core: at the default core transparency (0.1) it is 0.6.
	glow.Transparency = 1 - (1 - transparency) * (0.4 / 0.9)

	TweenService:Create(core, TweenInfo.new(life), { Transparency = 1 }):Play()
	TweenService:Create(glow, TweenInfo.new(life), { Transparency = 1 }):Play()

	-- Returned to the pool just after the fade ends.
	task.delay(life + 0.05, function()
		releasePart(core)
		releasePart(glow)
	end)
end

-- Sniper and taser tracers with their own settings. The game's own functions cannot be adjusted
-- after the fact (they start a transparency tween that cannot be stopped or lengthened), so the
-- tracer is drawn here instead, from the same ingredients: a neon part between the muzzle and the
-- hit that fades out with a Quad "In" tween, plus, for the taser, a SurfaceLight that fades with it.
local function createKindTracer(kind, startPos, endPos)
	local camera = Workspace.CurrentCamera
	if not camera then error("no current camera", 0) end

	local info = KINDS[kind]
	local color        = CW.Settings[info.prefix .. "COLOR"]
	local width        = CW.Settings[info.prefix .. "WIDTH"]
	local life         = CW.Settings[info.prefix .. "LIFETIME"]
	local transparency = CW.Settings[info.prefix .. "TRANSPARENCY"]

	local distance = (startPos - endPos).Magnitude
	local part = acquirePart(camera)
	resetLights(part)
	part.Color        = color
	part.Size         = Vector3.new(width, width, distance)
	part.CFrame       = CFrame.new((startPos + endPos) / 2, endPos)
	part.Transparency = transparency

	local fade = TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(part, fade, { Transparency = 1 }):Play()

	if info.surfaceLight then
		local light = part:FindFirstChild("CW_Surface")
		if not light then
			light = Instance.new("SurfaceLight")
			light.Name  = "CW_Surface"
			light.Range = 7
			light.Face  = Enum.NormalId.Bottom
			light.Angle = 180
			light.Parent = part
		end
		light.Color      = color
		light.Brightness = 5
		light.Enabled    = true
		TweenService:Create(light, fade, { Brightness = 0 }):Play()
	end

	-- Returned to the pool just after the fade ends.
	task.delay(life + 0.05, releasePart, part)
end

-- Without the kind's own tracer the taser and sniper keep the game's width, fade and lifetime and
-- only their color changes (to TRACER_COLOR, while custom tracers are on). The game's functions
-- create one part named "RayPart" and parent it to the camera, so the new tracer is the RayPart
-- that was not there before the call.
local function snapshotRayParts()
	local seen = {}
	local camera = Workspace.CurrentCamera
	if camera then
		for _, child in ipairs(camera:GetChildren()) do
			if child.Name == "RayPart" then seen[child] = true end
		end
	end
	return seen
end

local function recolorNewRayParts(before)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	for _, child in ipairs(camera:GetChildren()) do
		if child.Name == "RayPart" and not before[child] then
			child.Color = CW.Settings.TRACER_COLOR
			local light = child:FindFirstChildOfClass("SurfaceLight") -- the taser has one
			if light then light.Color = CW.Settings.TRACER_COLOR end
		end
	end
end

local function shouldUseCustom(startPos)
	if not CW.Settings.CUSTOM_BULLET_TRACERS then return false end
	if CW.Settings.TRACER_APPLY_TO_OTHERS then return true end
	return isLocalPlayerShot(startPos)
end

local function warnTracerFailure(err)
	if CW.State.tracerFailureWarned then return end
	CW.State.tracerFailureWarned = true
	CW.Warn("Custom tracer failed; using the game's tracer instead: " .. tostring(err))
end

-- The wrappers run on the game's own thread, so they must never throw into the game's gun
-- code: a failing custom tracer falls back to the game's own function. The game always calls
-- the three tracer functions with exactly two arguments (start, end).
local function makeTracerWrapper(originalKey)
	return function(startPos, endPos)
		-- 1) the firing gun has a tracer of its own turned on
		if hasGunTracers() then
			local okStyle, style = pcall(bulletShotStyle, startPos)
			if okStyle and style then
				local okDraw, err = pcall(createEnergyTracer, startPos, endPos, style)
				if okDraw then return end
				warnTracerFailure(err)
			end
		end

		-- 2) the shared Bullet Tracers settings
		local okUse, useCustom = pcall(shouldUseCustom, startPos)
		if okUse and useCustom then
			local okDraw, err = pcall(createEnergyTracer, startPos, endPos)
			if okDraw then return end
			warnTracerFailure(err)
		end

		-- 3) the game's own tracer
		local original = CW[originalKey]
		if original then return original(startPos, endPos) end
	end
end

-- Taser and sniper without their own tracer: the game's tracer, recolored afterwards when custom tracers apply.
local function makeRecolorWrapper(originalKey)
	return function(startPos, endPos)
		local okUse, useCustom = pcall(shouldUseCustom, startPos)
		local before
		if okUse and useCustom then
			local okSnapshot, snapshot = pcall(snapshotRayParts)
			if okSnapshot then before = snapshot end
		end
		local original = CW[originalKey]
		if original then original(startPos, endPos) end
		if before then
			local ok, err = pcall(recolorNewRayParts, before)
			if not ok then warnTracerFailure(err) end
		end
	end
end

-- Taser and sniper: the kind's own tracer when its ENABLED setting is on (and the shot is yours, or
-- "apply to others" is on); otherwise the recolor behaviour above. Never throws into the game.
local function makeKindWrapper(kind)
	local info = KINDS[kind]
	local fallback = makeRecolorWrapper(info.original)
	return function(startPos, endPos)
		if CW.Settings[info.prefix .. "ENABLED"] == true then
			local okOwn, own = pcall(function()
				return CW.Settings.TRACER_APPLY_TO_OTHERS or isLocalPlayerShot(startPos)
			end)
			if okOwn and own then
				local okDraw, err = pcall(createKindTracer, kind, startPos, endPos)
				if okDraw then return end
				warnTracerFailure(err)
			end
		end
		return fallback(startPos, endPos)
	end
end

-- Installs the wrappers; returns false (so we can retry) if the game module isn't ready yet.
-- The game's own functions are captured once and kept in CW, so installing again on a re-run
-- replaces our wrappers with the new ones instead of stacking them.
local function installTracers()
	if not CW.TracersModule then
		local shared = ReplicatedStorage:FindFirstChild("SharedModules")
		local moduleScript = shared and shared:FindFirstChild("GunTracers")
		if not moduleScript then return false end

		local ok, TracersModule = pcall(require, moduleScript)
		if not ok or type(TracersModule) ~= "table" then return false end

		CW.TracersModule          = TracersModule
		CW._originalCreateBullet  = TracersModule.createBullet
		CW._originalCreateTaser   = TracersModule.createTaser
		CW._originalCreateSniper  = TracersModule.createSniper
	end

	local TracersModule = CW.TracersModule
	if type(CW._originalCreateBullet) == "function" then
		TracersModule.createBullet = makeTracerWrapper("_originalCreateBullet")
	end
	if type(CW._originalCreateTaser) == "function" then
		TracersModule.createTaser = makeKindWrapper("Taser")
	end
	if type(CW._originalCreateSniper) == "function" then
		TracersModule.createSniper = makeKindWrapper("Sniper")
	end

	CW.Log("Tracer override installed.")
	return true
end

-- The module is shared with the game's own scripts, so it exists from the start; the waits only
-- matter if the script runs very early.
task.spawn(function()
	local shared = ReplicatedStorage:WaitForChild("SharedModules", 30)
	if not (shared and shared:WaitForChild("GunTracers", 30)) then
		CW.Warn("GunTracers module not found — custom tracers disabled.")
		return
	end
	if not installTracers() then
		CW.Warn("Could not load the GunTracers module — custom tracers disabled.")
	end
end)
end)


runModule("Hook", function()
-- Hook.lua
local CW = getgenv().__CW_CORE_STATE

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

-- How it works
--   The __namecall hook runs on the GAME's thread, which lacks the capabilities needed to
--   parent GUI into gethui() ("lacking capability Plugin"). So the hook does nothing but
--   copy the hit parts into a small queue (plain tables only, no Instance method calls).
--   A PreRender connection created from this script's own thread drains the queue and does
--   the real work (hit sound + hitmarker).

local MAX_QUEUE   = 32   -- shots waiting for the next frame (oldest dropped beyond this)
local MAX_BULLETS = 8    -- bullets copied per shot (the shotgun sends 5)
local MAX_AGE     = 1    -- seconds; older queued shots are discarded instead of drawn late

CW.State.shotQueue = CW.State.shotQueue or {}

-- Called from the game's thread: ONLY table work here. No :Method() calls on Instances.
function CW.onShot(bullets)
	if type(bullets) ~= "table" then return end

	local hits, n = {}, 0
	for _, bullet in pairs(bullets) do
		if n >= MAX_BULLETS then break end
		if type(bullet) == "table" then
			local hit = bullet[3]
			if hit ~= nil then
				n = n + 1
				hits[n] = hit
			end
		end
	end
	if n == 0 then return end

	local queue = CW.State.shotQueue
	if #queue >= MAX_QUEUE then table.remove(queue, 1) end
	queue[#queue + 1] = { hits = hits, time = os.clock() }
end

-- Runs on this script's thread (from the PreRender drain): the real shot logic.
function CW.processShot(hits)
	local shotHit = false
	for i = 1, #hits do
		local hit = hits[i]
		if typeof(hit) == "Instance" and hit:IsA("BasePart") and hit.Parent then
			local character = hit:FindFirstAncestorOfClass("Model") -- same lookup the game uses
			local player = character and Players:GetPlayerFromCharacter(character)
			if player and CW.isEnemy(player) then
				shotHit = true
				break
			end
		end
	end
	if not shotHit then return end
	CW.playHitSound()
	if not CW.HMTemplate or not CW.IAPortable then return end

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

local function traceHandler(err)
	return debug.traceback(tostring(err), 2)
end

-- Empties the queue. Errors are caught per shot and printed with a traceback (first 5 only,
-- so a persistent failure cannot flood the console).
function CW.drainShots()
	local queue = CW.State.shotQueue
	if not queue or #queue == 0 then return end
	CW.State.shotQueue = {}

	local now = os.clock()
	for i = 1, #queue do
		local entry = queue[i]
		if now - entry.time <= MAX_AGE then
			local ok, err = xpcall(CW.processShot, traceHandler, entry.hits)
			if not ok then
				CW.State.shotErrors = (CW.State.shotErrors or 0) + 1
				if CW.State.shotErrors <= 5 then
					CW.Warn("Shot handler error: " .. tostring(err))
				end
			end
		end
	end
end

CW.track("shotDrain", RunService.PreRender:Connect(function()
	local drain = CW.drainShots
	if drain then drain() end
end))

-- The hook only forwards the call: it copies the hit parts into the queue and returns the
-- game's own result untouched, so it can never break or delay the game's FireServer.
local function installShootHook(shootEvent)
	if CW.State.shootHooked then return end
	CW.ShootEvent = shootEvent

	local isExecutorCall = type(checkcaller) == "function" and checkcaller or function() return false end
	local wrap = type(newcclosure) == "function" and newcclosure or function(fn) return fn end

	local OldNameCall
	OldNameCall = hookmetamethod(shootEvent, "__namecall", wrap(function(self, ...)
		if getnamecallmethod() == "FireServer" and not isExecutorCall() and self == CW.ShootEvent then
			local enqueue = CW.onShot
			if enqueue then pcall(enqueue, (...)) end
		end
		return OldNameCall(self, ...)
	end))

	CW.State.shootHooked = true
	CW.Log("ShootEvent hook installed")
end

if not CW.Caps.hook then
	if not CW.State.hookCapabilityWarned then
		CW.State.hookCapabilityWarned = true
		CW.Warn("hookmetamethod/getnamecallmethod unavailable; hitmarker and hit sound detection is disabled")
	end
else
	-- GunRemotes.ShootEvent exists from the start of the game; the waits only matter if the
	-- script runs very early.
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("GunRemotes", 30)
		local shootEvent = remotes and remotes:WaitForChild("ShootEvent", 30)
		if not shootEvent then
			CW.Warn("GunRemotes.ShootEvent not found; hitmarker detection unavailable")
			return
		end
		local ok, err = pcall(installShootHook, shootEvent)
		if not ok then CW.Warn("Could not install the ShootEvent hook: " .. tostring(err)) end
	end)
end
end)


runModule("Cleanup", function()
-- Cleanup.lua
local CW = getgenv().__CW_CORE_STATE

local UserInputService = game:GetService("UserInputService")

local LocalPlayer = CW.LocalPlayer

-- Runs when the player leaves the game. It is looked up through CW when it fires, so a
-- re-run's version is the one that runs.
function CW.cleanup()
	pcall(function() UserInputService.MouseIconEnabled=true end)
	pcall(function() UserInputService.MouseIcon="" end)
	pcall(function() CW.IAPortable:Destroy() end)
	pcall(function() if CW.UIWindow then CW.UIWindow:Destroy() end end)
	for _, key in ipairs({
		"enforcerConn", "enableConn", "sprintCharacterConn", "chatToggleConn",
	}) do
		pcall(function()
			local connection = CW.State[key]
			if connection then connection:Disconnect() end
		end)
	end
	pcall(function() CW.Settings.AUTO_RELOAD_ENABLED = false end)
	pcall(function() if CW.State.stopWeaponShootSoundOverrides then CW.State.stopWeaponShootSoundOverrides() end end)
	pcall(function() if CW.State.destroyHitSoundPool then CW.State.destroyHitSoundPool() end end)
	pcall(function()
		local contextActions = game:GetService("ContextActionService")
		contextActions:UnbindAction("CycleWareSprintToggle")
		contextActions:UnbindAction("CycleWareProtectSprint")
	end)
	pcall(CW.untrackAll)
	CW.ActiveFollowClones = {}
end

CW.track("cleanup", LocalPlayer.AncestryChanged:Connect(function()
	if LocalPlayer:IsDescendantOf(game) then return end
	local cleanup = CW.cleanup
	if cleanup then pcall(cleanup) end
end))
end)


runModule("Sync", function()
-- Sync.lua
-- Runs independently of the UI: official assets are downloaded even if the UI fails to load,
-- and everything that consumes assets is reloaded as soon as the download finishes.
local CW = getgenv().__CW_CORE_STATE

function CW.reloadCoreAssets()
	CW.Paths.CURSOR_FILE = CW.Library.selectedPath("Cursors")
	CW.Paths.HITMARKER_FILE = CW.Library.selectedPath("Hitmarkers")
	CW.Paths.SOUND_FILE = CW.Library.selectedPath("HitSounds")

	-- The cursor goes last: generating it yields for a while (PNG codec), and it must not
	-- delay the textures and the hit sound.
	local reloaders = {
		{ "hitmarker", CW.reloadHitmarkerAsset },
		{ "textures", CW.reloadTextures },
		{ "sound", CW.reloadSoundAsset },
		{ "cursor", CW.reloadCursor },
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
end)

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

--// Download the UI library
local UI_URL = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/CWUI.lua"
CW.Log("Downloading CycleWare UI from GitHub")
local UI_CACHE_FILE = CW.Paths.CACHE_FOLDER .. "/CWUI.lua"
local fetchOK, uiSource = false, nil
local localUIFile = type(_cfg.UI_FILE) == "string" and _cfg.UI_FILE ~= "" and _cfg.UI_FILE or nil
if localUIFile then
	-- Teste local: getgenv().CW_CONFIG = { UI_FILE = "CWUI.lua" } (caminho no workspace do executor)
	local readOK, data = pcall(readfile, localUIFile)
	if readOK and type(data) == "string" and data ~= "" then
		fetchOK, uiSource = true, data
		CW.Log("Using the local UI file: " .. localUIFile)
	else
		CW.Warn("UI_FILE could not be read (" .. localUIFile .. "); downloading the UI instead")
	end
end
if not fetchOK then
	fetchOK, uiSource = pcall(CW.httpGet, UI_URL)
	if fetchOK and type(uiSource) == "string" and uiSource:find("CreateWindow", 1, true) then
		pcall(writefile, UI_CACHE_FILE, uiSource) -- guarda a última cópia boa
	else
		local cacheOK, cached = pcall(readfile, UI_CACHE_FILE)
		if cacheOK and type(cached) == "string" and cached:find("CreateWindow", 1, true) then
			CW.Warn("Could not download the UI (" .. tostring(uiSource) .. "); using the last saved copy")
			fetchOK, uiSource = true, cached
		end
	end
end
assert(fetchOK and type(uiSource) == "string" and uiSource ~= "", "Could not download CWUI.lua from GitHub: " .. tostring(uiSource))

local loadUI, compileError = loadstring(uiSource)
assert(type(loadUI) == "function", tostring(compileError or "Could not compile CWUI.lua"))
local CWUI = loadUI()
assert(type(CWUI) == "table" and type(CWUI.CreateWindow) == "function", "Invalid CWUI library")

if CW.UIWindow and type(CW.UIWindow.Destroy) == "function" then
	pcall(function() CW.UIWindow:Destroy() end)
end
-- Ícones opcionais (caminho no workspace ou ID do Roblox). Exemplo, antes de executar o script:
--   getgenv().CW_CONFIG = { UI_ICONS = { Logo = "CW/logo.png", Discord = 456, Info = 789, Settings = 123,
--                                         Effects = 111, Visuals = 222, Sounds = 333, Utilities = 444 },
--                           DISCORD_URL = "https://discord.gg/xxxx" }
-- (Settings vale para o botão do rodapé e para a aba Settings; as outras abas usam o próprio nome.)
local uiIcons = type(_cfg.UI_ICONS) == "table" and _cfg.UI_ICONS or {}
local Window = CWUI:CreateWindow({
	Title = "CW",
	ToggleKey = false,
	Logo = uiIcons.Logo,
	Icons = { Settings = uiIcons.Settings, Discord = uiIcons.Discord, Info = uiIcons.Info },
	Discord = type(_cfg.DISCORD_URL) == "string" and _cfg.DISCORD_URL or nil,
})
CW.UIWindow = Window
Window.ToggleVisibility = Window.Toggle

local function mapControlOptions(options)
	options = options or {}
	return {
		Name = options.Title or options.Name,
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
	-- Color picker (CWUI 2.2+). Returns nil when the loaded CWUI has no picker, so the caller can
	-- fall back to something else (an old copy of CWUI.lua may still be cached on disk).
	function adapter:Colorpicker(control)
		if type(section.AddColorpicker) ~= "function" then return nil end
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddColorpicker(o)
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
	local tab = Window:AddTab({ Name = tabName, Icon = options.Icon or uiIcons[tabName] })
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

local function applySoundFile(value)
	local path = hitSoundPath(value)
	if not path then return end
	CW.Paths.SOUND_FILE = path
	CW.Library.setSelection("HitSounds", nil, CW.Library.relative(path))
	if CW.reloadSoundAsset then CW.reloadSoundAsset() end
end

local hitSoundOptions = refreshHitSoundCatalog()

------------------------------------------------------------------------------
-- Weapon sound changers: one factory, one instance per action (shoot, reload).
--
-- How the game plays a gun sound: the Handle of the Tool holds one Sound per action (named
-- ShootSound, ReloadSound). Every time the action happens the game CLONES that Sound into the
-- same Handle, plays the clone and removes it a few seconds later; for other players the server
-- sends the Sound instance and their client clones and plays it the same way. So replacing the
-- SoundId of the original replaces it for every clone made afterwards, mine and the others'.
-- The weapon is the Tool the Sound lives in: Sound.Parent = Handle, Handle.Parent = Tool, and the
-- Tool's name is the weapon's name.
------------------------------------------------------------------------------
local WEAPON_SOUND_DEFAULT = "Default"

-- A previous run (even of an older version) keeps watching until it is told to stop.
if CW.State.stopWeaponShootSoundOverrides then
	pcall(CW.State.stopWeaponShootSoundOverrides)
end

local function disconnectList(connections)
	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(connections)
end

local function findSoundTool(sound)
	local ancestor = sound.Parent
	while ancestor do
		if ancestor:IsA("Tool") then return ancestor end
		ancestor = ancestor.Parent
	end
	return nil
end

-- Guns that have sounds to replace (set up by the Texture module; includes the Taser).
local function soundWeaponNames()
	return CW.SoundWeaponList or CW.WeaponList or {}
end

-- spec = {
--   Category    = "WeaponSounds" | "ReloadSounds"   library folder: <Category>/<Weapon>/<file>
--   SoundName   = "ShootSound" | "ReloadSound"      the Sound instance the game plays
--   OverridesKey, EnabledKey, OthersKey, VolumeKey  saved settings (names unchanged for the shoot sounds)
--   ConfigKey                                       optional CW_CONFIG table: { ["AK-47"] = "WeaponSounds/AK-47/x.mp3" }
--   BaseVolume(originalId, player)                  optional: volume the game itself plays this sound at
-- }
local function createSoundChanger(spec)
	local settings = CW.Settings
	local configured = settings[spec.OverridesKey] or _cfg[spec.ConfigKey]
	settings[spec.OverridesKey] = type(configured) == "table" and configured or {}
	-- Off by default: nothing changes in the game until the player turns it on.
	if settings[spec.EnabledKey] == nil then settings[spec.EnabledKey] = _cfg[spec.EnabledKey] == true end
	if settings[spec.OthersKey] == nil then settings[spec.OthersKey] = _cfg[spec.OthersKey] == true end
	-- Volume multiplier for the replaced sounds, relative to the game's own volume.
	settings[spec.VolumeKey] = math.clamp(tonumber(settings[spec.VolumeKey]) or 1, 0, 2)
	CW.Defaults[spec.VolumeKey] = 1

	local overrides = settings[spec.OverridesKey]
	local changer = { spec = spec, overrides = overrides, catalog = {}, dropdowns = {}, migrated = false }
	local active = setmetatable({}, { __mode = "k" })     -- Sound -> data about what was changed
	local watched = setmetatable({}, { __mode = "k" })    -- container -> { player, connections }
	local playerConnections, globalConnections = {}, {}
	local refreshScheduled, generation = false, 0
	local assetIds = {} -- relative path -> getcustomasset id; rebuilt with every refresh

	--// library catalog ---------------------------------------------------------------
	-- "<Category>/<weapon>/rest" -> "rest" (nil when the path is not inside that weapon's folder).
	local function tailOf(weapon, relative)
		if type(weapon) ~= "string" or type(relative) ~= "string" then return nil end
		if relative:find("..", 1, true) or relative:find("\\", 1, true) then return nil end
		local prefix = spec.Category .. "/" .. weapon .. "/"
		if relative:sub(1, #prefix) ~= prefix or #relative == #prefix then return nil end
		return relative:sub(#prefix + 1)
	end

	function changer.refreshCatalog()
		table.clear(changer.catalog)
		for _, weapon in ipairs(soundWeaponNames()) do
			local entry = { options = { WEAPON_SOUND_DEFAULT }, byLabel = {}, available = {} }
			for _, item in ipairs(CW.Library.list(spec.Category, weapon)) do
				local tail = tailOf(weapon, item.Relative)
				if tail then
					local label = tail:gsub("^_Official/", "")
					if entry.byLabel[label] then label = tail end -- a user file with the same name as an official one
					entry.byLabel[label] = item.Relative
					entry.available[item.Relative] = true
					table.insert(entry.options, label)
				end
			end
			changer.catalog[weapon] = entry
		end
	end

	-- Text shown in a weapon's dropdown for a saved override (also when the file is not on disk yet).
	function changer.label(weapon, relative)
		local tail = tailOf(weapon, relative)
		if not tail then return WEAPON_SOUND_DEFAULT end
		local entry = changer.catalog[weapon]
		if entry then
			for label, savedRelative in pairs(entry.byLabel) do
				if savedRelative == relative then return label end
			end
		end
		return (tail:gsub("^_Official/", ""))
	end

	-- A saved selection that does not point inside its own weapon's folder (the shoot sounds used
	-- to share the HitSounds library) is dropped once, with a warning.
	do
		local dropped = {}
		for weapon, path in pairs(overrides) do
			if type(path) ~= "string" or not tailOf(weapon, path) then
				overrides[weapon] = nil
				if type(path) == "string" then table.insert(dropped, tostring(weapon)) end
			end
		end
		if #dropped > 0 then
			table.sort(dropped)
			changer.migrated = true
			CW.Warn("A saved " .. spec.Label .. " sound selection did not point at the " .. spec.Category
				.. " library and was removed for: " .. table.concat(dropped, ", ") .. ". Choose a new sound for them in the Sounds tab.")
		end
	end
	changer.refreshCatalog()

	--// volume ---------------------------------------------------------------------------
	-- baseVolume is the game's own volume for that sound; the sound plays at baseVolume * the slider.
	-- If the game itself changes the volume later (distance, per-shot values), that new value becomes
	-- the base, so the slider always scales the game's value.
	local function setScaledVolume(sound, data)
		local target = math.clamp(data.baseVolume * (settings[spec.VolumeKey] or 1), 0, 10)
		data.lastVolume = target
		if sound.Volume ~= target then
			pcall(function() sound.Volume = target end)
		end
	end

	function changer.updateVolumes()
		for sound, data in pairs(active) do
			if sound.Parent then setScaledVolume(sound, data) end
		end
	end

	local function restoreSound(sound)
		local data = active[sound]
		if not data then return end
		active[sound] = nil
		if data.connection then
			pcall(function() data.connection:Disconnect() end)
		end
		if data.volumeConnection then
			pcall(function() data.volumeConnection:Disconnect() end)
		end
		if sound.Parent then
			pcall(function()
				sound.SoundId = data.originalId
				sound.Volume = data.originalVolume
			end)
		end
	end

	function changer.stop()
		generation = generation + 1
		refreshScheduled = false
		table.clear(assetIds)
		disconnectList(globalConnections)
		for _, connections in pairs(playerConnections) do
			disconnectList(connections)
		end
		table.clear(playerConnections)
		for container, data in pairs(watched) do
			disconnectList(data.connections)
			watched[container] = nil
		end
		for sound in pairs(active) do
			restoreSound(sound)
		end
	end

	--// applying ---------------------------------------------------------------------------
	local function applySound(sound, targetId, tool, player, container)
		local data = active[sound]
		if not data then
			local originalId, originalVolume = sound.SoundId, sound.Volume
			local baseVolume = originalVolume

			-- The game plays a CLONE of the Sound. The clone of a sound that was already replaced arrives
			-- with the replacement id and the already scaled volume, so its original values (and the
			-- base the volume slider scales) come from the sound it was cloned from: a sibling in the
			-- same Handle. Without this the slider would be applied twice (0.5x would play at 0.25x).
			local sibling
			if sound.SoundId == targetId then
				for other, otherData in pairs(active) do
					if other ~= sound and other.Parent == sound.Parent and other.Name == sound.Name
						and otherData.targetId == targetId then
						sibling = otherData
						break
					end
				end
			end
			if sibling then
				originalId, originalVolume, baseVolume = sibling.originalId, sibling.originalVolume, sibling.baseVolume
			elseif spec.BaseVolume then
				baseVolume = spec.BaseVolume(sound.SoundId, player) or baseVolume
			end

			data = {
				originalId = originalId,
				originalVolume = originalVolume,
				baseVolume = baseVolume,
				lastVolume = baseVolume,
				tool = tool,
				player = player,
				container = container,
				targetId = targetId,
			}
			active[sound] = data
			local ok, connection = pcall(function()
				return sound:GetPropertyChangedSignal("SoundId"):Connect(function()
					local current = active[sound]
					if current and sound.Parent and sound.SoundId ~= current.targetId then
						pcall(function() sound.SoundId = current.targetId end)
					end
				end)
			end)
			if ok then data.connection = connection end

			local okVolume, volumeConnection = pcall(function()
				return sound:GetPropertyChangedSignal("Volume"):Connect(function()
					local current = active[sound]
					if not current or not sound.Parent then return end
					if math.abs(sound.Volume - current.lastVolume) > 0.0001 then
						current.baseVolume = sound.Volume -- the game changed it: scale the new value
						setScaledVolume(sound, current)
					end
				end)
			end)
			if okVolume then data.volumeConnection = volumeConnection end
		else
			data.tool = tool
			data.player = player
			data.container = container
			data.targetId = targetId
		end

		if sound.SoundId ~= targetId then
			pcall(function() sound.SoundId = targetId end)
		end
		setScaledVolume(sound, data)
	end

	-- Engine asset id of an override file (cached in assetIds), or nil when the file is missing
	-- or cannot be loaded. Shared by the tool hook and the background pre-load below.
	local function resolveAsset(relativePath)
		local cached = assetIds[relativePath]
		if cached then return cached end
		local filePath = CW.Paths.LIBRARY_ROOT .. "/" .. relativePath
		local okFile, exists = pcall(isfile, filePath)
		if not (okFile and exists) then return nil end
		local loaded, assetId = pcall(CW.Library.audioAsset, filePath)
		if not loaded or type(assetId) ~= "string" then return nil end
		assetIds[relativePath] = assetId
		return assetId
	end

	local function applyToTool(tool, player, container)
		if not tool:IsA("Tool") then return end
		if not settings[spec.EnabledKey] then return end
		if player ~= LocalPlayer and not settings[spec.OthersKey] then return end

		local relativePath = overrides[tool.Name]
		if type(relativePath) ~= "string" then return end
		local targetId = resolveAsset(relativePath)
		if not targetId then return end
		for _, descendant in ipairs(tool:GetDescendants()) do
			if descendant:IsA("Sound") and descendant.Name == spec.SoundName then
				applySound(descendant, targetId, tool, player, container)
			end
		end
	end

	local function unwatchContainer(container)
		local data = watched[container]
		if not data then return end
		watched[container] = nil
		disconnectList(data.connections)
		for sound, soundData in pairs(active) do
			if soundData.container == container then
				restoreSound(sound)
			end
		end
	end

	local function watchContainer(container, player)
		if watched[container] then return end
		local data = { player = player, connections = {} }
		watched[container] = data

		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				applyToTool(child, player, container)
			end
		end

		table.insert(data.connections, container.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("Tool") then
				task.defer(applyToTool, descendant, player, container)
			elseif descendant:IsA("Sound") and descendant.Name == spec.SoundName then
				local tool = findSoundTool(descendant)
				if tool then applyToTool(tool, player, container) end
			end
		end))

		table.insert(data.connections, container.DescendantRemoving:Connect(function(descendant)
			if descendant:IsA("Sound") then
				restoreSound(descendant)
			elseif descendant:IsA("Tool") then
				for sound, soundData in pairs(active) do
					if soundData.tool == descendant then restoreSound(sound) end
				end
			end
		end))
	end

	local function removePlayer(player)
		local connections = playerConnections[player]
		if connections then
			disconnectList(connections)
			playerConnections[player] = nil
		end
		for container, data in pairs(watched) do
			if data.player == player then unwatchContainer(container) end
		end
	end

	local function watchPlayer(player)
		if playerConnections[player] then return end
		local connections = {}
		playerConnections[player] = connections

		table.insert(connections, player.CharacterAdded:Connect(function(character)
			watchContainer(character, player)
		end))
		table.insert(connections, player.CharacterRemoving:Connect(unwatchContainer))
		if player.Character then
			watchContainer(player.Character, player)
		end

		if player == LocalPlayer then
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then watchContainer(backpack, player) end
			table.insert(connections, player.ChildAdded:Connect(function(child)
				if child:IsA("Backpack") then watchContainer(child, player) end
			end))
		end
	end

	function changer.refresh()
		changer.stop()
		if not settings[spec.EnabledKey] then return end
		local current = generation -- taken after the stop: a newer refresh cancels this one
		for _, player in ipairs(Players:GetPlayers()) do
			watchPlayer(player)
		end
		table.insert(globalConnections, Players.PlayerAdded:Connect(watchPlayer))
		table.insert(globalConnections, Players.PlayerRemoving:Connect(removePlayer))

		-- Resolve the chosen files in the background, so the first sound of a weapon that is not in
		-- hand yet already plays the replaced file.
		task.defer(function()
			-- Snapshot first: resolving can yield, and the player may change a dropdown meanwhile.
			local pending = {}
			for _, relative in pairs(overrides) do
				if type(relative) == "string" then table.insert(pending, relative) end
			end
			for _, relative in ipairs(pending) do
				if current ~= generation or not settings[spec.EnabledKey] then return end
				pcall(resolveAsset, relative)
			end
		end)
	end

	function changer.schedule()
		if refreshScheduled then return end
		refreshScheduled = true
		local current = generation
		task.defer(function()
			if current ~= generation then return end
			refreshScheduled = false
			changer.refresh()
		end)
	end

	-- value is what the weapon's dropdown shows: "Default" (the game's own sound) or a file label.
	function changer.set(weapon, value)
		if value == WEAPON_SOUND_DEFAULT then
			overrides[weapon] = nil
		else
			local entry = changer.catalog[weapon]
			local relative = entry and (entry.byLabel[value] or (entry.available[value] and value))
			if not relative then
				CW.Warn("Choose a sound file from the " .. spec.Category .. " library for " .. tostring(weapon))
				return
			end
			overrides[weapon] = relative
		end
		changer.schedule()
	end

	return changer
end

local shootSounds = createSoundChanger({
	Label = "shoot",
	Category = "WeaponSounds",
	SoundName = "ShootSound",
	OverridesKey = "WEAPON_SHOOT_SOUND_OVERRIDES",
	ConfigKey = "WEAPON_SHOOT_SOUNDS",
	EnabledKey = "WEAPON_SOUND_OVERRIDE_ENABLED",
	OthersKey = "WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS",
	VolumeKey = "WEAPON_SOUND_VOLUME",
})

local reloadSounds = createSoundChanger({
	Label = "reload",
	Category = "ReloadSounds",
	SoundName = "ReloadSound",
	OverridesKey = "WEAPON_RELOAD_SOUND_OVERRIDES",
	ConfigKey = "WEAPON_RELOAD_SOUNDS",
	EnabledKey = "WEAPON_RELOAD_SOUND_OVERRIDE_ENABLED",
	OthersKey = "WEAPON_RELOAD_SOUND_OVERRIDE_APPLY_TO_OTHERS",
	VolumeKey = "WEAPON_RELOAD_SOUND_VOLUME",
	-- The game plays OTHER players' taser reload at 0.1 by checking for this exact SoundId. Once the id
	-- is replaced that check no longer matches, so the same level is applied here instead.
	BaseVolume = function(originalId, player)
		if originalId == "rbxassetid://82273261" and player ~= LocalPlayer then return 0.1 end
		return nil
	end,
})

local soundChangers = { shootSounds, reloadSounds }
CW.State.stopWeaponShootSoundOverrides = function()
	for _, changer in ipairs(soundChangers) do changer.stop() end
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
		Callback = function(s) CW.Settings.HITMARKER_RANDOM_ROTATION = s end,
	})

	EffectsTab:Toggle({
		Title = "Follow Mouse",
		Default = CW.Settings.HITMARKER_FOLLOW_MOUSE,
		Callback = function(s) CW.Settings.HITMARKER_FOLLOW_MOUSE = s end,
	})

	EffectsTab:Slider({
		Title = "Visible Duration",
		Min = 0,
		Max = 1,
		Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
		Decimal = 2,
		Suffix = "s",
		Callback = function(v) CW.Settings.HITMARKER_VISIBLE_DURATION = v end,
	})

	EffectsTab:Toggle({
		Title = "Fadeout",
		Default = CW.Settings.HITMARKER_FADEOUT,
		Callback = function(s) CW.Settings.HITMARKER_FADEOUT = s end,
	})

	EffectsTab:Slider({
		Title = "Fadeout Duration",
		Min = 0,
		Max = 1,
		Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
		Decimal = 2,
		Suffix = "s",
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

	-- Only used by the palette dropdown, which is the fallback when the loaded CWUI has no color picker.
	local function colorName(color)
		for name, paletteColor in pairs(tracerPalette) do
			if color == paletteColor then return name end
		end
		return "Violet"
	end

	-- Colors are userdata and can't be serialised: they are saved as hex strings (TRACER_COLOR_HEX,
	-- TRACER_GLOW_COLOR_HEX, ...). Files written by the old palette dropdown stored a palette name
	-- (TRACER_COLOR_NAME): it is still understood, and the next save replaces it with hex.
	local function colorFromHex(hex)
		if type(hex) ~= "string" then return nil end
		local ok, color = pcall(Color3.fromHex, hex)
		if ok and typeof(color) == "Color3" then return color end
		return nil
	end
	for _, entry in ipairs({
		{ "TRACER_COLOR", "TRACER_COLOR_HEX", "TRACER_COLOR_NAME" },
		{ "TRACER_GLOW_COLOR", "TRACER_GLOW_COLOR_HEX", "TRACER_GLOW_COLOR_NAME" },
		{ "TRACER_SNIPER_COLOR", "TRACER_SNIPER_COLOR_HEX" },
		{ "TRACER_TASER_COLOR", "TRACER_TASER_COLOR_HEX" },
	}) do
		local settingKey, hexKey, nameKey = entry[1], entry[2], entry[3]
		CW.Settings[settingKey] = colorFromHex(CW.Settings[hexKey])
			or (nameKey and tracerPalette[CW.Settings[nameKey]])
			or CW.Settings[settingKey]
		-- The saved values are consumed here. If they stayed in CW.Settings, the generic save loop would
		-- write them back even after the player picks another color (or goes back to the default).
		CW.Settings[hexKey] = nil
		if nameKey then CW.Settings[nameKey] = nil end
	end

	-- A colour control; returns a function that moves it to another colour without calling onChange.
	local function addColorControl(section, title, initial, onChange)
		local picker = section:Colorpicker({
			Title = title,
			Default = initial,
			Callback = onChange,
		})
		if picker then
			return function(color) picker:Set(color, true) end
		end

		-- No color picker in the loaded CWUI: keep the old palette dropdown.
		local dropdown = section:Dropdown({
			Title = title,
			Options = { "Violet", "Lilac", "Red", "Green", "Cyan", "White" },
			Default = colorName(initial),
			Callback = function(name)
				onChange(tracerPalette[name])
			end,
		})
		return function(color) dropdown:Set(colorName(color), true) end
	end

	local function addTracerColor(section, title, settingKey)
		return addColorControl(section, title, CW.Settings[settingKey], function(color)
			CW.Settings[settingKey] = color
		end)
	end

	-- Width, lifetime and transparency sliders for the tracer whose settings start with `prefix`.
	local function addTracerSliders(section, prefix, maxLifetime)
		section:Slider({
			Title = "Tracer Width",
			Min = 0.01,
			Max = 0.5,
			Default = CW.Settings[prefix .. "WIDTH"],
			Decimal = 2,
			Callback = function(v) CW.Settings[prefix .. "WIDTH"] = v end,
		})
		section:Slider({
			Title = "Tracer Lifetime",
			Min = 0.01,
			Max = maxLifetime,
			Default = CW.Settings[prefix .. "LIFETIME"],
			Decimal = 2,
			Suffix = "s",
			Callback = function(v) CW.Settings[prefix .. "LIFETIME"] = v end,
		})
		section:Slider({
			Title = "Tracer Transparency",
			Min = 0,
			Max = 1,
			Default = CW.Settings[prefix .. "TRANSPARENCY"],
			Decimal = 2,
			Callback = function(v) CW.Settings[prefix .. "TRANSPARENCY"] = v end,
		})
	end

	EffectsTab:Toggle({
		Title = "Tracers: Apply To Others",
		Default = CW.Settings.TRACER_APPLY_TO_OTHERS,
		Callback = function(s) CW.Settings.TRACER_APPLY_TO_OTHERS = s end,
	})

	--// every gun except the Sniper and the Taser
	local BulletSection = EffectsTab:AddSubSection("Bullet Tracers (all other guns)", true)

	BulletSection:Toggle({
		Title = "Custom Bullet Tracers",
		Default = CW.Settings.CUSTOM_BULLET_TRACERS,
		Callback = function(s) CW.Settings.CUSTOM_BULLET_TRACERS = s end,
	})
	addTracerColor(BulletSection, "Tracer Color", "TRACER_COLOR")
	addTracerColor(BulletSection, "Glow Color", "TRACER_GLOW_COLOR")
	addTracerSliders(BulletSection, "TRACER_", 1)
	BulletSection:Toggle({
		Title = "Tracer Light",
		Default = CW.Settings.TRACER_POINT_LIGHT == true,
		Callback = function(s) CW.Settings.TRACER_POINT_LIGHT = s == true end,
	})

	--// Sniper (M700) and Taser: a tracer of their own each
	local SniperSection = EffectsTab:AddSubSection("Sniper Tracer (M700)", false)
	SniperSection:AddLabel("Off: the game's own tracer (recolored by the Tracer Color above while Custom Bullet Tracers is on).")
	SniperSection:Toggle({
		Title = "Custom Sniper Tracer",
		Default = CW.Settings.TRACER_SNIPER_ENABLED == true,
		Callback = function(s) CW.Settings.TRACER_SNIPER_ENABLED = s == true end,
	})
	addTracerColor(SniperSection, "Sniper Tracer Color", "TRACER_SNIPER_COLOR")
	addTracerSliders(SniperSection, "TRACER_SNIPER_", 5)

	local TaserSection = EffectsTab:AddSubSection("Taser Tracer", false)
	TaserSection:AddLabel("Off: the game's own tracer (recolored by the Tracer Color above while Custom Bullet Tracers is on).")
	TaserSection:Toggle({
		Title = "Custom Taser Tracer",
		Default = CW.Settings.TRACER_TASER_ENABLED == true,
		Callback = function(s) CW.Settings.TRACER_TASER_ENABLED = s == true end,
	})
	addTracerColor(TaserSection, "Taser Tracer Color", "TRACER_TASER_COLOR")
	addTracerSliders(TaserSection, "TRACER_TASER_", 3)

	--// every other gun, one at a time
	local gunNames = {}
	for _, name in ipairs(soundWeaponNames()) do
		if name ~= "M700" and name ~= "Taser" then table.insert(gunNames, name) end
	end
	if #gunNames == 0 then
		gunNames = { "AK-47", "FAL", "M4A1", "M9", "MP5", "Remington 870", "Revolver" }
	end

	local GunSection = EffectsTab:AddSubSection("Per-Gun Tracers", false)
	GunSection:AddLabel("Pick a gun and turn its own tracer on. Anything you do not change follows the Bullet Tracers above. Other players' guns also need Tracers: Apply To Others.")

	local selectedGun = gunNames[1]
	local gunControls = {}

	local function gunMap(field) -- the settings map of one field (created again if a saved file replaced it)
		local key = "TRACER_GUN_" .. field
		if type(CW.Settings[key]) ~= "table" then CW.Settings[key] = {} end
		return CW.Settings[key]
	end

	local function gunColorValue(field, fallback)
		return colorFromHex(gunMap(field)[selectedGun]) or fallback
	end

	-- Shows the selected gun's values (its own, or the shared ones it follows) without saving anything.
	local function refreshGunControls()
		gunControls.enabled:Set(gunMap("ENABLED")[selectedGun] == true, true)
		gunControls.color(gunColorValue("COLOR", CW.Settings.TRACER_COLOR))
		gunControls.glow(gunColorValue("GLOW", CW.Settings.TRACER_GLOW_COLOR))
		gunControls.width:Set(tonumber(gunMap("WIDTH")[selectedGun]) or CW.Settings.TRACER_WIDTH, true)
		gunControls.lifetime:Set(tonumber(gunMap("LIFETIME")[selectedGun]) or CW.Settings.TRACER_LIFETIME, true)
		gunControls.transparency:Set(tonumber(gunMap("TRANSPARENCY")[selectedGun]) or CW.Settings.TRACER_TRANSPARENCY, true)
	end

	GunSection:Dropdown({
		Title = "Gun",
		Options = gunNames,
		Default = selectedGun,
		Callback = function(name)
			selectedGun = name
			refreshGunControls()
		end,
	})
	gunControls.enabled = GunSection:Toggle({
		Title = "Custom Tracer For This Gun",
		Default = gunMap("ENABLED")[selectedGun] == true,
		Callback = function(on)
			gunMap("ENABLED")[selectedGun] = on and true or nil
		end,
	})
	gunControls.color = addColorControl(GunSection, "Tracer Color",
		gunColorValue("COLOR", CW.Settings.TRACER_COLOR), function(color)
			gunMap("COLOR")[selectedGun] = color:ToHex()
		end)
	gunControls.glow = addColorControl(GunSection, "Glow Color",
		gunColorValue("GLOW", CW.Settings.TRACER_GLOW_COLOR), function(color)
			gunMap("GLOW")[selectedGun] = color:ToHex()
		end)
	gunControls.width = GunSection:Slider({
		Title = "Tracer Width",
		Min = 0.01,
		Max = 0.5,
		Default = tonumber(gunMap("WIDTH")[selectedGun]) or CW.Settings.TRACER_WIDTH,
		Decimal = 2,
		Callback = function(v) gunMap("WIDTH")[selectedGun] = v end,
	})
	gunControls.lifetime = GunSection:Slider({
		Title = "Tracer Lifetime",
		Min = 0.01,
		Max = 1,
		Default = tonumber(gunMap("LIFETIME")[selectedGun]) or CW.Settings.TRACER_LIFETIME,
		Decimal = 2,
		Suffix = "s",
		Callback = function(v) gunMap("LIFETIME")[selectedGun] = v end,
	})
	gunControls.transparency = GunSection:Slider({
		Title = "Tracer Transparency",
		Min = 0,
		Max = 1,
		Default = tonumber(gunMap("TRANSPARENCY")[selectedGun]) or CW.Settings.TRACER_TRANSPARENCY,
		Decimal = 2,
		Callback = function(v) gunMap("TRANSPARENCY")[selectedGun] = v end,
	})
	GunSection:Button({
		Title = "Reset This Gun",
		Callback = function()
			for _, field in ipairs({ "ENABLED", "COLOR", "GLOW", "WIDTH", "LIFETIME", "TRANSPARENCY" }) do
				gunMap(field)[selectedGun] = nil
			end
			refreshGunControls()
			scheduleSave()
		end,
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
-- Sounds tab: one collapsible section per changer (Shoot Sounds, Reload Sounds) plus Hit Sound.
-- The Shoot Sounds controls and their saved settings are the same as before ("Weapon Sounds"),
-- so nothing already saved is lost.
------------------------------------------------------------------------------
guarded("Sounds", function()
	local SoundsTab = Window:AddTab({ Name = "Sounds", Icon = uiIcons.Sounds })
	local ShootSection = wrapSection(SoundsTab:AddSection({ Name = "Shoot Sounds", Open = true }))
	local ReloadSection = wrapSection(SoundsTab:AddSection({ Name = "Reload Sounds", Open = true }))
	local HitSection = wrapSection(SoundsTab:AddSection({ Name = "Hit Sound", Open = true }))

	-- Same controls for every changer: enable, apply to others, volume, and one dropdown per gun.
	local function buildChangerSection(section, changer, label)
		local spec = changer.spec

		section:Toggle({
			Title = "Enable " .. label .. " Sound Overrides",
			Default = CW.Settings[spec.EnabledKey] == true,
			Callback = function(enabled)
				CW.Settings[spec.EnabledKey] = enabled == true
				changer.schedule()
			end,
		})

		section:Toggle({
			Title = "Apply to Other Players Locally",
			Default = CW.Settings[spec.OthersKey] == true,
			Callback = function(enabled)
				CW.Settings[spec.OthersKey] = enabled == true
				changer.schedule()
			end,
		})

		section:Slider({
			Title = label .. " Sound Volume",
			Min = 0,
			Max = 2,
			Default = CW.Settings[spec.VolumeKey],
			Decimal = 2,
			Suffix = "x",
			Callback = function(v)
				CW.Settings[spec.VolumeKey] = v
				changer.updateVolumes()
			end,
		})

		for _, weaponName in ipairs(soundWeaponNames()) do
			local weapon = weaponName
			local entry = changer.catalog[weapon]
			local dropdown = section:Dropdown({
				Title = weapon .. " " .. label .. " Sound",
				Options = entry and entry.options or { WEAPON_SOUND_DEFAULT },
				Default = changer.label(weapon, changer.overrides[weapon]),
				Callback = function(value)
					changer.set(weapon, value)
				end,
			})
			table.insert(changer.dropdowns, { weapon = weapon, control = dropdown })
		end
	end

	buildChangerSection(ShootSection, shootSounds, "Shoot")
	buildChangerSection(ReloadSection, reloadSounds, "Reload")

	HitSoundDropdown = HitSection:Dropdown({
		Title = "Hit Sound",
		Options = hitSoundOptions,
		Default = hitSoundLabel(CW.Paths.SOUND_FILE),
		Callback = applySoundFile,
	})

	HitSection:Slider({
		Title = "Hit Sound Volume",
		Min = 0,
		Max = 2,
		Default = CW.Settings.SOUND_VOLUME,
		Decimal = 2,
		Suffix = "x",
		Callback = function(v) CW.Settings.SOUND_VOLUME = v end,
	})
end)

------------------------------------------------------------------------------
-- Utilities tab
------------------------------------------------------------------------------
guarded("Utilities", function()
	local UtilityTab = Window:Tab({ Title = "Utilities" })

	local StarterGui = game:GetService("StarterGui")
	local ContextActionService = game:GetService("ContextActionService")
	-- Kept in CW.State so a re-run still knows that the chat was hidden with Z.
	local chatHidden = CW.State.chatHidden == true
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
		-- Always sunk: the game reads RightShift as sprint, and opening the menu must not make
		-- the character run.
		return Enum.ContextActionResult.Sink
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
		Callback = function(enabled)
			CW.Settings.SHIFT_TOGGLE_ENABLED = enabled == true
			if not CW.Settings.SHIFT_TOGGLE_ENABLED then
				allowSprintRelease = sprinting or allowSprintRelease
				sprinting = false
			end
		end,
	})

	-- The chat is no longer forced on at load: it is only touched by the Z toggle below.
	local function setChatVisible(visible)
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, visible)
		end)
		pcall(function()
			StarterGui:SetCore("ChatActive", visible)
		end)
	end

	if CW.State.chatToggleConn then
		CW.State.chatToggleConn:Disconnect()
	end
	CW.State.chatToggleConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not CW.Settings.CHAT_TOGGLE_ENABLED then return end
		if input.KeyCode ~= Enum.KeyCode.Z then return end

		chatHidden = not chatHidden
		CW.State.chatHidden = chatHidden
		setChatVisible(not chatHidden)
	end)

	UtilityTab:Toggle({
		Title = "Toggle Chat with Z",
		Default = CW.Settings.CHAT_TOGGLE_ENABLED == true,
		Callback = function(enabled)
			CW.Settings.CHAT_TOGGLE_ENABLED = enabled == true
			if not CW.Settings.CHAT_TOGGLE_ENABLED then
				chatHidden = false
				CW.State.chatHidden = false
				setChatVisible(true)
			end
		end,
	})

	-- Auto reload (off by default).
	-- It reads the equipped gun's own attributes instead of the ammo text on screen: the game keeps
	-- Local_CurrentAmmo (the client's count) and Local_ReloadSession (0 when idle, a timestamp while
	-- reloading) on the tool, and the sniper's text ("1 | 14") is not a plain "x/y" anyway.
	local VirtualInputManager
	pcall(function()
		VirtualInputManager = game:GetService("VirtualInputManager")
	end)
	local autoReloadWarned = false

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

	if CW.Settings.AUTO_RELOAD_ENABLED == nil then
		CW.Settings.AUTO_RELOAD_ENABLED = _cfg.AUTO_RELOAD_ENABLED == true
	end

	-- True when the gun is empty, not already reloading, and the game would accept a reload
	-- (the sniper cannot reload without stored ammo).
	local function needsReload(tool)
		if not CW.Settings.AUTO_RELOAD_ENABLED then return false end
		if tool:GetAttribute("Local_CurrentAmmo") ~= 0 then return false end
		if tool:GetAttribute("Local_ReloadSession") ~= 0 then return false end
		if tool:GetAttribute("Behavior") == "Sniper" and (tool:GetAttribute("StoredAmmo") or 0) <= 0 then return false end
		return true
	end

	local reloading = setmetatable({}, { __mode = "k" })
	local function autoReload(tool)
		if reloading[tool] then return end
		reloading[tool] = true
		task.spawn(function()
			-- At most two presses; the second only if the first did not start a reload.
			for _ = 1, 2 do
				if not needsReload(tool) or tool.Parent ~= LocalPlayer.Character then break end
				if UserInputService:GetFocusedTextBox() or UserInputService:IsKeyDown(Enum.KeyCode.R) then break end
				pressReloadKey()
				task.wait(0.15)
				if tool:GetAttribute("Local_ReloadSession") ~= 0 then break end
			end
			reloading[tool] = nil
		end)
	end

	local function watchTool(tool)
		if not tool:IsA("Tool") or tool:GetAttribute("ToolType") ~= "Gun" then return end
		CW.track("autoReloadTool", tool:GetAttributeChangedSignal("Local_CurrentAmmo"):Connect(function()
			if needsReload(tool) then autoReload(tool) end
		end))
		if needsReload(tool) then autoReload(tool) end
	end

	local function watchCharacter(character)
		CW.track("autoReloadAdded", character.ChildAdded:Connect(watchTool))
		CW.track("autoReloadRemoved", character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then CW.untrack("autoReloadTool") end
		end))
		for _, child in ipairs(character:GetChildren()) do watchTool(child) end
	end

	local function setAutoReload(enabled)
		if enabled then
			CW.track("autoReloadCharacter", LocalPlayer.CharacterAdded:Connect(watchCharacter))
			if LocalPlayer.Character then watchCharacter(LocalPlayer.Character) end
		else
			for _, key in ipairs({ "autoReloadCharacter", "autoReloadAdded", "autoReloadRemoved", "autoReloadTool" }) do
				CW.untrack(key)
			end
		end
	end

	UtilityTab:Toggle({
		Title = "Auto Reload at 0 Ammo",
		Default = CW.Settings.AUTO_RELOAD_ENABLED == true,
		Callback = function(enabled)
			CW.Settings.AUTO_RELOAD_ENABLED = enabled == true
			setAutoReload(CW.Settings.AUTO_RELOAD_ENABLED)
		end,
	})

	setAutoReload(CW.Settings.AUTO_RELOAD_ENABLED == true)
end)

------------------------------------------------------------------------------
-- Library <-> UI refresh
------------------------------------------------------------------------------
-- Rebuilds every library-backed control from disk. Core assets are reloaded separately
-- by CW.reloadCoreAssets (so this never touches the cursor/texture pipeline).
-- The gallery drops its own asset cache entries on every rebuild, so no extra cache clear is needed.
local function refreshUIFromLibrary()
	hitSoundOptions = refreshHitSoundCatalog()
	for _, changer in ipairs(soundChangers) do changer.refreshCatalog() end

	local function syncGallery(gallery, category, weapon, selectedFile)
		if not gallery then return end
		gallery:SetItems(galleryItems(category, weapon))
		-- SetItems already restores the previous selection. Calling Set on an entry that is
		-- already selected would DESELECT it in galleries that allow deselecting (the weapon
		-- texture galleries), so Set is only used when the selection really has to change.
		local current = gallery:Get()
		if selectedFile then
			if not (current and current.Path == selectedFile) then gallery:Set(selectedFile, true) end
		elseif current then
			gallery:Clear()
		end
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
	for _, changer in ipairs(soundChangers) do
		for _, entry in ipairs(changer.dropdowns) do
			local catalog = changer.catalog[entry.weapon]
			entry.control:Refresh(catalog and catalog.options or { WEAPON_SOUND_DEFAULT })
			entry.control:Set(changer.label(entry.weapon, changer.overrides[entry.weapon]), true)
		end
		changer.refresh()
	end
end

------------------------------------------------------------------------------
-- Settings tab (created last so it is also the last tab)
------------------------------------------------------------------------------
guarded("Settings", function()
	local SettingsTab = createCompatTab({ Title = "Settings" })

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

	-- A setting is saved only when the player changed it: its value differs from the default.
	-- Switching a setting back to its default removes it from the file.
	local function isDefaultValue(key, value)
		if type(value) == "table" then return next(value) == nil end
		local default = CW.Defaults[key]
		if default == nil and type(value) == "boolean" then default = false end
		if type(value) == "number" and type(default) == "number" then return math.abs(value - default) < 1e-6 end
		return value == default
	end

	local function saveSettings()
		local savedSettings = {}
		for key, value in pairs(CW.Settings) do
			if key ~= "ASSET_SELECTIONS" and key ~= "SOUND_ID" and key ~= "AUTO_RELOAD_LABEL_PATH" then
				local serialized = serializableValue(value)
				if serialized ~= nil and not isDefaultValue(key, serialized) then
					savedSettings[key] = serialized
				end
			end
		end

		-- Tracer colors are Color3 (not serialisable): store them as hex, only when different from the default.
		local function saveColor(settingKey, hexKey)
			local color, default = CW.Settings[settingKey], CW.Defaults[settingKey]
			if typeof(color) == "Color3" and (typeof(default) ~= "Color3" or color:ToHex() ~= default:ToHex()) then
				savedSettings[hexKey] = color:ToHex()
			end
		end
		saveColor("TRACER_COLOR", "TRACER_COLOR_HEX")
		saveColor("TRACER_GLOW_COLOR", "TRACER_GLOW_COLOR_HEX")
		saveColor("TRACER_SNIPER_COLOR", "TRACER_SNIPER_COLOR_HEX")
		saveColor("TRACER_TASER_COLOR", "TRACER_TASER_COLOR_HEX")

		local out = {
			schemaVersion = 3,
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
		Callback = function()
			saveSettings()
			CW.Log("Settings saved.")
		end,
	})
end)

local soundsMigrated = false
for _, changer in ipairs(soundChangers) do
	changer.schedule()
	if changer.migrated then soundsMigrated = true end
end
if soundsMigrated then scheduleSave() end -- write the cleaned-up overrides so the warning shows only once
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
end				and (entryType == "string" or entryType == "number" or entryType == "boolean") then
				result[key] = entry
			end
		end
		return result
	end

	-- A setting is saved only when the player changed it: its value differs from the default.
	-- Switching a setting back to its default removes it from the file.
	local function isDefaultValue(key, value)
		if type(value) == "table" then return next(value) == nil end
		local default = CW.Defaults[key]
		if default == nil and type(value) == "boolean" then default = false end
		if type(value) == "number" and type(default) == "number" then return math.abs(value - default) < 1e-6 end
		return value == default
	end

	local function saveSettings()
		local savedSettings = {}
		for key, value in pairs(CW.Settings) do
			if key ~= "ASSET_SELECTIONS" and key ~= "SOUND_ID" and key ~= "AUTO_RELOAD_LABEL_PATH" then
				local serialized = serializableValue(value)
				if serialized ~= nil and not isDefaultValue(key, serialized) then
					savedSettings[key] = serialized
				end
			end
		end

		-- Tracer colors are Color3 (not serialisable): store them as hex, only when different from the default.
		local function saveColor(settingKey, hexKey)
			local color, default = CW.Settings[settingKey], CW.Defaults[settingKey]
			if typeof(color) == "Color3" and (typeof(default) ~= "Color3" or color:ToHex() ~= default:ToHex()) then
				savedSettings[hexKey] = color:ToHex()
			end
		end
		saveColor("TRACER_COLOR", "TRACER_COLOR_HEX")
		saveColor("TRACER_GLOW_COLOR", "TRACER_GLOW_COLOR_HEX")
		saveColor("TRACER_SNIPER_COLOR", "TRACER_SNIPER_COLOR_HEX")
		saveColor("TRACER_TASER_COLOR", "TRACER_TASER_COLOR_HEX")

		local out = {
			schemaVersion = 3,
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
		Callback = function()
			saveSettings()
			CW.Log("Settings saved.")
		end,
	})
end)

local soundsMigrated = false
for _, changer in ipairs(soundChangers) do
	changer.schedule()
	if changer.migrated then soundsMigrated = true end
end
if soundsMigrated then scheduleSave() end -- write the cleaned-up overrides so the warning shows only once
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
endlocal function boolOr(v, default)
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
			mouseX           = 0,
			mouseY           = 0,
		},
	}
	getgenv().__CW_CORE_STATE = CW
end

CW.IsFirstRun  = isFirstRun
CW.LocalPlayer = LocalPlayer
CW.Mouse       = Mouse

CW.PreviousVersion = CW.Version
CW.Version         = SCRIPT_VERSION
CW.Caps            = CAPS

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

--// Connection registry -------------------------------------------------------------
-- Registering again under the same key disconnects the previous connection, so a re-run
-- REPLACES the old code instead of leaving it active next to the new one.
CW.State.conns = CW.State.conns or {}

function CW.track(key, connection)
	local conns = CW.State.conns
	local previous = conns[key]
	if previous then
		pcall(function() previous:Disconnect() end)
	end
	conns[key] = connection
	return connection
end

function CW.untrack(key)
	local conns = CW.State.conns
	local previous = conns[key]
	conns[key] = nil
	if previous then
		pcall(function() previous:Disconnect() end)
	end
end

function CW.untrackAll()
	for key in pairs(CW.State.conns) do
		CW.untrack(key)
	end
end

--// Teams ----------------------------------------------------------------------------
-- The original rule: anyone on a different team than you is an enemy, whether or not a shot could
-- actually hurt them (a ForceField, or a Guard against a calm Inmate, still counts). The hit sound,
-- the hitmarker and the red cursor use it; the same team gets the green cursor. The team color is
-- read straight from the player, so no cache or signal is needed.
function CW.isEnemy(player)
	return player ~= nil and player ~= LocalPlayer and player.TeamColor ~= LocalPlayer.TeamColor
end

--// HTTP -----------------------------------------------------------------------------
-- The executor's request function goes first: game:HttpGet blocks the main thread on many
-- executors, so it is only the fallback. Raises an error when nothing works.
function CW.httpGet(url)
	local lastError
	local requestFn = CW.Caps.request
	if requestFn then
		local sent, response = pcall(requestFn, { Url = url, Method = "GET" })
		if sent and type(response) == "table" then
			local status = tonumber(response.StatusCode)
			local success = response.Success == true or (status ~= nil and status >= 200 and status < 300)
			if success and type(response.Body) == "string" then return response.Body end
			lastError = "HTTP " .. tostring(response.StatusCode or "?") .. " " .. tostring(response.StatusMessage or "")
		else
			lastError = response
		end
	end

	local ok, result = pcall(function() return game:HttpGet(url) end)
	if ok and type(result) == "string" then return result end
	error(tostring(lastError or result or "no HTTP function available"), 0)
end

--// Startup report -------------------------------------------------------------------
do
	local missing = {}
	if not CAPS.getgenv then table.insert(missing, "getgenv (re-running without rejoining will not be clean)") end
	if not CAPS.files then table.insert(missing, "file functions (asset library, cursor, textures, sounds and saved settings are disabled)") end
	if not CAPS.customAsset then table.insert(missing, "getcustomasset (custom images and sounds are disabled)") end
	if not CAPS.hook then table.insert(missing, "hookmetamethod/getnamecallmethod (hitmarker and hit sound detection is disabled)") end
	if not CAPS.gethui then table.insert(missing, "gethui (using CoreGui instead)") end
	if not CAPS.httpGet and not CAPS.request then table.insert(missing, "HTTP (asset sync and the UI download are disabled)") end
	if #missing > 0 then
		CW.Warn("Missing executor functions: " .. table.concat(missing, "; "))
	end
end

CW.Log(isFirstRun and "First run — initializing." or "Re-run detected — reloading modules and replacing the previous run's connections.")
if not isFirstRun and CW.PreviousVersion == nil then
	CW.Warn("State from an older script version was found. Connections made by that version stay active until you rejoin, so rejoin once for a fully clean update.")
end

CW.Paths.CURSOR_ROOT = "CycleWare"
CW.Paths.LIBRARY_ROOT = CW.Paths.CURSOR_ROOT .. "/Library"
CW.Paths.CURSORS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Cursors"
CW.Paths.HITMARKERS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Hitmarkers"
CW.Paths.HIT_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/HitSounds"
CW.Paths.WEAPON_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/WeaponSounds"
CW.Paths.RELOAD_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/ReloadSounds"
CW.Paths.TEXTURES_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Textures"
CW.Paths.OFFICIAL_FOLDER = "_Official"
CW.Paths.CACHE_FOLDER = CW.Paths.CURSOR_ROOT .. "/Cache"
CW.Paths.GENERATED_FOLDER = CW.Paths.CACHE_FOLDER .. "/Generated"
CW.Paths.TINTED_FOLDER = CW.Paths.GENERATED_FOLDER .. "/Cursors"
CW.Paths.CURSOR_SIG_FILE = CW.Paths.TINTED_FOLDER .. "/cursor.sig"
CW.Paths.MANIFEST_FILE = CW.Paths.LIBRARY_ROOT .. "/manifest.json"
CW.Paths.LIBRARY_REVISION_FILE = CW.Paths.LIBRARY_ROOT .. "/.revision"
CW.Paths.SETTINGS_FILE = CW.Paths.CACHE_FOLDER .. "/ui_settings.json"
CW.Paths.AUDIO_COPIES_FOLDER = CW.Paths.CACHE_FOLDER .. "/Audio"
CW.Paths.AUDIO_PROBE_FILE = CW.Paths.CACHE_FOLDER .. "/audio_probe.json"

CW.Paths.CURSOR_FILE = nil
CW.Paths.HITMARKER_FILE = nil
CW.Paths.SOUND_FILE = nil

-- Everything is off by default; only what the player changes is saved (see saveSettings).
CW.Settings.HITMARKER_SIZE             = numOr(_cfg.HITMARKER_SIZE, 50, 1)
CW.Settings.SOUND_VOLUME               = numOr(_cfg.SOUND_VOLUME, 1, 0)
CW.Settings.CURSOR_TARGET_SIZE         = numOr(_cfg.CURSOR_TARGET_SIZE, 82, 1)
CW.Settings.HITMARKER_VISIBLE_DURATION = numOr(_cfg.HITMARKER_VISIBLE_DURATION, 0.05, 0)
CW.Settings.HITMARKER_FADEOUT_DURATION = numOr(_cfg.HITMARKER_FADEOUT_DURATION, 0.15, 0)

CW.Settings.HITMARKER_RANDOM_ROTATION = boolOr(_cfg.HITMARKER_RANDOM_ROTATION, false)
CW.Settings.HITMARKER_FOLLOW_MOUSE    = boolOr(_cfg.HITMARKER_FOLLOW_MOUSE, false)
CW.Settings.HITMARKER_FADEOUT         = boolOr(_cfg.HITMARKER_FADEOUT, false)

-- Snapshot of the defaults, taken before any saved value is applied. The save routine
-- writes only the settings whose value differs from these.
CW.Defaults = {}
for _, key in ipairs({
	"HITMARKER_SIZE", "SOUND_VOLUME", "CURSOR_TARGET_SIZE", "HITMARKER_VISIBLE_DURATION",
	"HITMARKER_FADEOUT_DURATION", "HITMARKER_RANDOM_ROTATION", "HITMARKER_FOLLOW_MOUSE", "HITMARKER_FADEOUT",
}) do
	CW.Defaults[key] = CW.Settings[key]
end

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
			local savedVersion = tonumber(data.schemaVersion) or 1
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

			-- Files written before schema 3 stored every setting, including toggles that used to be
			-- ON by default. Those toggles are now OFF by default, so the old values are dropped once.
			if savedVersion < 3 then
				local reset = {}
				for _, key in ipairs({
					"AUTO_RELOAD_ENABLED", "WEAPON_SOUND_OVERRIDE_ENABLED", "HITMARKER_RANDOM_ROTATION",
					"HITMARKER_FOLLOW_MOUSE", "HITMARKER_FADEOUT",
				}) do
					if values[key] ~= nil then
						values[key] = nil
						table.insert(reset, key)
					end
				end
				if #reset > 0 then
					CW.Warn("Settings are now off by default. Reset once from the old save: " .. table.concat(reset, ", ") .. ". Turn on what you want; it will be saved.")
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

do
	local loc = UserInputService:GetMouseLocation()
	CW.State.mouseX, CW.State.mouseY = loc.X, loc.Y
end

-- Created on every run and registered with CW.track: a re-run replaces the previous connections.
do
	CW.track("mouseMove", UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		if next(CW.ActiveFollowClones) == nil then return end -- nothing to move

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
	end))
end

runModule("Cache", function()
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
	CW.Paths.WEAPON_SOUNDS_FOLDER,
	CW.Paths.RELOAD_SOUNDS_FOLDER,
	CW.Paths.TEXTURES_FOLDER,
	CW.Paths.CACHE_FOLDER,
	CW.Paths.GENERATED_FOLDER,
	CW.Paths.TINTED_FOLDER,
	CW.Paths.AUDIO_COPIES_FOLDER,
}

function CW.ensureFolders()
	for _, folder in ipairs(ALL_FOLDERS) do
		if not isfolder(folder) then
			pcall(makefolder, folder)
		end
	end
end
CW.ensureFolders()

-- Cooperative yielding for heavy loops (PNG codec, checksums) so the game never freezes.
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

-- Same result as CW.crc32, but hands the thread back to the game now and then. Only call it
-- from a thread that is allowed to yield (the sync thread, a task.spawn, the executor thread).
function CW.crc32Yielding(s)
	local c = 0xFFFFFFFF
	local length = #s
	for i = 1, length do
		c = bxor(_crcT[band(bxor(c, sbyte(s, i)), 0xFF)], rshift(c, 8))
		if i % 65536 == 0 then CW.yieldBudget() end
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

	local ok, asset, reason
	if cfg.audio and CW.Library and CW.Library.audioAsset then
		-- Audio goes through the library: format detected by content, compatibility copy if needed.
		ok, asset, reason = pcall(CW.Library.audioAsset, cfg.file)
		if ok and not asset then ok, asset = false, reason end
	else
		ok, asset = pcall(getcustomasset, cfg.file)
	end
	if not ok or not asset then
		CW.Warn("Could not load " .. cfg.label .. ": " .. tostring(asset))
		return nil, "error"
	end

	CW.Log(cfg.label .. " loaded from " .. cfg.file)
	return asset, nil
end
end)


runModule("AssetLibrary", function()
-- AssetLibrary.lua
local CW = getgenv().__CW_CORE_STATE
local HttpService = game:GetService("HttpService")

local CATEGORY_INFO = {
	Cursors = { folder = CW.Paths.CURSORS_FOLDER, extensions = { png = true } },
	Hitmarkers = { folder = CW.Paths.HITMARKERS_FOLDER, extensions = { png = true } },
	HitSounds = { folder = CW.Paths.HIT_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
}
local SELECTION_KEYS = {
	Cursors = "Cursor",
	Hitmarkers = "Hitmarker",
	HitSounds = "HitSound",
}
-- Categories stored per weapon: <category>/<Weapon>/<file>. The weapon names are the same
-- ones the Textures folders use.
local WEAPON_CATEGORIES = {
	Textures = { folder = CW.Paths.TEXTURES_FOLDER, extensions = { png = true } },
	WeaponSounds = { folder = CW.Paths.WEAPON_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
	ReloadSounds = { folder = CW.Paths.RELOAD_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
}
local ASSET_EXTENSIONS = { png = true, mp3 = true, ogg = true, wav = true, flac = true }
local AUDIO_FORMATS = { mp3 = true, ogg = true, wav = true, flac = true }

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
	local weaponInfo = WEAPON_CATEGORIES[category]
	if weaponInfo then
		return path:match("^" .. category .. "/[^/]+/[^/]+$") ~= nil
			and weaponInfo.extensions[extension] == true
	end
	return false
end

local function detectAssetFormat(data)
	if type(data) ~= "string" or #data < 4 then return "empty or truncated" end

	if data:sub(1, 8) == "\137\80\78\71\13\10\26\10" then return "png" end
	if data:sub(1, 4) == "MM\0\42" or data:sub(1, 4) == "II\42\0" then return "tiff" end
	if data:sub(1, 3) == "\255\216\255" then return "jpeg" end
	if data:sub(1, 4) == "OggS" then return "ogg" end
	if data:sub(1, 3) == "ID3" then return "mp3" end
	local first, second = string.byte(data, 1, 2)
	if first == 0xFF and second and bit32.band(second, 0xE0) == 0xE0 then return "mp3" end
	if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WAVE" then return "wav" end
	if data:sub(1, 4) == "fLaC" then return "flac" end
	if data:match("^%d%d%d:%s") then return "HTTP error response" end
	return "unknown"
end

-- Images must be PNG with a matching extension. Audio is judged by its content only: any of
-- mp3/ogg/wav/flac is accepted whatever the file is called (a WAV named .mp3 is fine).
local function isAudioCategory(category)
	local info = CATEGORY_INFO[category] or WEAPON_CATEGORIES[category]
	return info ~= nil and info.audio == true
end

local function formatMatches(category, path, actual)
	if isAudioCategory(category) then return AUDIO_FORMATS[actual] == true end
	local extension = path:match("%.([%w]+)$")
	return extension ~= nil and actual == extension:lower()
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

-- Directory scans read and validate every file, so the result is cached per category/weapon.
-- The cache is cleared whenever the library can have changed (CW.Library.sync).
local listCache = {}
local audioAssetCache, audioPending = {}, {}

function CW.Library.invalidate()
	table.clear(listCache)
	table.clear(audioAssetCache)
end

local function scanLibrary(category, weapon)
	local info = CATEGORY_INFO[category]
	local weaponInfo = WEAPON_CATEGORIES[category]
	local directories = {}
	if info then
		table.insert(directories, info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, info.folder)
	elseif weaponInfo and type(weapon) == "string" then
		local weaponFolder = weaponInfo.folder .. "/" .. weapon
		table.insert(directories, weaponFolder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, weaponFolder)
	else
		return nil
	end

	local extensions = (info or weaponInfo).extensions
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
						local actualFormat = okData and detectAssetFormat(data) or "unreadable"
						if formatMatches(category, normalized, actualFormat) then
							table.insert(result, {
								Name = filename:gsub("%.[%w]+$", ""),
								Path = CW.Paths.LIBRARY_ROOT .. "/" .. relative,
								Relative = relative,
							})
						elseif not invalidAssetWarnings[normalized] then
							invalidAssetWarnings[normalized] = true
							CW.Warn("Skipped invalid library asset " .. relative .. " (expected " .. (isAudioCategory(category) and "audio" or extension:lower()) .. ", detected " .. actualFormat .. ")")
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

function CW.Library.list(category, weapon)
	local key = tostring(category) .. "|" .. tostring(weapon)
	local cached = listCache[key]
	if not cached then
		cached = scanLibrary(category, weapon)
		if not cached then return {} end
		listCache[key] = cached
	end
	local copy = table.create and table.create(#cached) or {}
	for index, item in ipairs(cached) do
		copy[index] = { Name = item.Name, Path = item.Path, Relative = item.Relative }
	end
	return copy
end

--// Audio assets ------------------------------------------------------------------------
-- getcustomasset decides how to decode a local file from its NAME, so a WAV called .mp3 (or a
-- format the engine only accepts under another name) can fail. For those files a copy is
-- written to the cache folder with a name that works; the original is never touched.
-- Which name works is found once per audio format by loading the copy and checking that the
-- sound has a length (real extension first, then .mp3, then .ogg); the result is remembered
-- in audio_probe.json, so nothing is guessed on later runs. mp3/ogg files with a matching
-- name are played directly, with no probe and no copy.
local STANDARD_AUDIO = { mp3 = true, ogg = true }
local MAX_AUDIO_BYTES = 20 * 1024 * 1024 -- Roblox's documented limit for audio files
local audioWarned = {}
local audioProbe

local function warnAudioOnce(key, message)
	if audioWarned[key] then return end
	audioWarned[key] = true
	CW.Warn(message)
end

local function loadAudioProbe()
	if audioProbe then return audioProbe end
	audioProbe = {}
	local okExists, exists = pcall(isfile, CW.Paths.AUDIO_PROBE_FILE)
	if okExists and exists then
		local okRead, raw = pcall(readfile, CW.Paths.AUDIO_PROBE_FILE)
		if okRead then
			local decoded, data = pcall(HttpService.JSONDecode, HttpService, raw)
			if decoded and type(data) == "table" then
				for format, extension in pairs(data) do
					if AUDIO_FORMATS[format] and AUDIO_FORMATS[extension] then audioProbe[format] = extension end
				end
			end
		end
	end
	return audioProbe
end

local function saveAudioProbe()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, audioProbe or {})
	if ok then pcall(writefile, CW.Paths.AUDIO_PROBE_FILE, encoded) end
end

-- True when the engine can load the asset as a sound with a length above zero.
local function audioLoads(asset)
	local ok, loaded = pcall(function()
		local sound = Instance.new("Sound")
		sound.Volume = 0
		sound.SoundId = asset
		sound.Parent = game:GetService("SoundService")
		local done = false
		task.spawn(function()
			pcall(function() game:GetService("ContentProvider"):PreloadAsync({ sound }) end)
			done = true
		end)
		local deadline = os.clock() + 4
		while not done and os.clock() < deadline do task.wait(0.05) end
		local settle = os.clock() + 0.5
		while sound.TimeLength <= 0 and os.clock() < settle do task.wait(0.05) end
		local length = sound.TimeLength
		sound:Destroy()
		return length > 0
	end)
	return ok and loaded == true
end

local function audioCopyPath(path, data, extension)
	local name = path:match("([^/\\]+)$") or "audio"
	name = name:gsub("%.[%w]+$", "")
	name = name:gsub("[^%w_%-]", "_")
	return CW.Paths.AUDIO_COPIES_FOLDER .. "/" .. string.format("%08x", CW.crc32Yielding(data)) .. "_" .. name .. "." .. extension
end

local function compatAudioAsset(path, data, format, originalExtension)
	local probe = loadAudioProbe()
	local known = probe[format] ~= nil
	local candidates = {}
	if known then
		candidates[1] = probe[format]
	else
		for _, extension in ipairs({ format, "mp3", "ogg" }) do
			if not table.find(candidates, extension) then table.insert(candidates, extension) end
		end
	end

	CW.Library.ensureFolder(CW.Paths.AUDIO_COPIES_FOLDER)
	for _, extension in ipairs(candidates) do
		local target = path
		if extension ~= originalExtension then
			target = audioCopyPath(path, data, extension)
			local okFile, exists = pcall(isfile, target)
			if not (okFile and exists) then
				if not pcall(writefile, target, data) then target = nil end
			end
		end
		if target then
			local okAsset, asset = pcall(getcustomasset, target)
			if okAsset and type(asset) == "string" and (known or audioLoads(asset)) then
				if not known then
					probe[format] = extension
					saveAudioProbe()
					CW.Log("Audio probe: " .. format .. " files load as ." .. extension .. " on this executor")
				end
				return asset
			end
			-- This name did not work: do not leave its copy behind.
			if target ~= path and not known then pcall(delfile, target) end
		end
	end
	if known then
		probe[format] = nil -- the remembered name stopped working: probe again next time
		saveAudioProbe()
	end
	return nil
end

-- Returns the asset id for an audio file, or nil plus the reason.
function CW.Library.audioAsset(path)
	if type(path) ~= "string" then return nil, "invalid path" end
	local cached = audioAssetCache[path]
	if cached then return cached end
	while audioPending[path] do task.wait(0.05) end
	cached = audioAssetCache[path]
	if cached then return cached end

	audioPending[path] = true
	local ok, asset, reason = pcall(function()
		local okRead, data = pcall(readfile, path)
		if not okRead or type(data) ~= "string" then return nil, "unreadable" end
		local format = detectAssetFormat(data)
		if not AUDIO_FORMATS[format] then return nil, "not an audio file (detected " .. format .. ")" end
		if #data > MAX_AUDIO_BYTES then
			warnAudioOnce(path, (CW.Library.relative(path) or path) .. " is larger than 20 MB; Roblox may refuse to play it")
		end

		local originalExtension = (path:match("%.([%w]+)$") or ""):lower()
		if STANDARD_AUDIO[format] and originalExtension == format then
			local okAsset, direct = pcall(getcustomasset, path)
			if okAsset and direct then return direct end
			return nil, tostring(direct)
		end

		local compat = compatAudioAsset(path, data, format, originalExtension)
		if compat then return compat end

		-- Last resort: the original file, as is.
		local okAsset, direct = pcall(getcustomasset, path)
		if okAsset and direct then
			warnAudioOnce("fallback|" .. path, "Could not verify that " .. (CW.Library.relative(path) or path) .. " plays as " .. format .. "; using the original file")
			return direct
		end
		return nil, tostring(direct)
	end)
	audioPending[path] = nil

	if ok and asset then
		audioAssetCache[path] = asset
		return asset
	end
	return nil, ok and reason or tostring(asset)
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

-- Returns the file to use for a category (and weapon) plus its relative path.
-- A saved selection whose file is not on disk yet is NOT overwritten: it stays saved and is
-- used again as soon as the file exists.
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
	if category == "Textures" then return nil, nil end

	-- Nothing chosen (or the chosen file is missing): the first file is used, but it is NOT
	-- saved as a selection. Only a choice made by the player is persisted.
	local first = files[1]
	if not first then return nil, nil end
	return first.Path, first.Relative
end

local function officialDestination(category, relativePath)
	local weaponInfo = WEAPON_CATEGORIES[category]
	if weaponInfo then
		local weapon, filename = relativePath:match("^" .. category .. "/([^/]+)/([^/]+)$")
		if not validWeaponName(weapon) then return nil end
		return weaponInfo.folder .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER .. "/" .. filename
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
	for _, info in pairs(WEAPON_CATEGORIES) do
		local ok, weaponFolders = pcall(listfiles, info.folder)
		if ok and type(weaponFolders) == "table" then
			for _, weaponFolder in ipairs(weaponFolders) do
				pruneFolder((tostring(weaponFolder):gsub("\\", "/")) .. "/" .. CW.Paths.OFFICIAL_FOLDER)
			end
		end
	end
end

local function syncImpl()
	local manifestURL = _cfg.ASSET_MANIFEST_URL
	if type(manifestURL) ~= "string" or manifestURL == "" then
		CW.Log("Asset manifest URL is unset; using files already in Library")
		return false
	end
	if not CW.Caps.files then
		CW.Warn("File functions unavailable; skipping the asset sync")
		return false
	end
	CW.Log("Fetching asset manifest")
	if not (CW.Caps.httpGet or CW.Caps.request) then
		CW.Warn("HTTP unavailable; using files already in Library")
		return false
	end

	local fetched, raw = pcall(CW.httpGet, manifestURL)
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
	-- False when an entry of the manifest itself is malformed: the list of files to keep is then
	-- not reliable, so nothing is removed from the _Official folders in that run.
	local entriesTrusted = true

	for category, entries in pairs(manifest.assets) do
		local weaponInfo = WEAPON_CATEGORIES[category]
		if weaponInfo and type(entries) == "table" then
			-- assets.<Category>[Weapon] = { { path = "<Category>/<Weapon>/<file>", crc32 = "..." }, ... }
			for weapon, weaponEntries in pairs(entries) do
				if validWeaponName(weapon) and type(weaponEntries) == "table" then
					ensureFolderPath(weaponInfo.folder .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER)
					for _, entry in ipairs(weaponEntries) do
						local manifestWeapon
						if type(entry) == "table" and type(entry.path) == "string" then
							manifestWeapon = entry.path:match("^" .. category .. "/([^/]+)/")
						end
						if type(entry) == "table" and manifestWeapon == weapon and validManifestPath(category, entry.path) then
							table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
						else
							skipped = skipped + 1
							entriesTrusted = false
							CW.Warn("Skipped invalid " .. category .. " entry in manifest")
						end
					end
				else
					skipped = skipped + 1
					entriesTrusted = false
				end
			end
		elseif CATEGORY_INFO[category] and type(entries) == "table" then
			for _, entry in ipairs(entries) do
				if type(entry) == "table" and validManifestPath(category, entry.path) then
					table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
				else
					skipped = skipped + 1
					entriesTrusted = false
					CW.Warn("Skipped invalid " .. category .. " entry in manifest")
				end
			end
		else
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
			entriesTrusted = false
		else
			local destinationRelative = libraryRelative(destination)
			if destinationRelative then expected[destinationRelative] = true end
			ensureFolderPath(destination:match("^(.*)/[^/]+$"))

			-- Validate cached bytes before trusting the extension or manifest revision.
			local needsDownload = true
			if isfile(destination) then
				local ok, existing = pcall(readfile, destination)
				local actualFormat = ok and detectAssetFormat(existing) or "unreadable"
				if formatMatches(entry.category, entry.path, actualFormat) then
					if entry.crc32 then
						local expectedCRC = tostring(entry.crc32):lower():gsub("^0x", "")
						needsDownload = string.format("%08x", CW.crc32Yielding(existing)):lower() ~= expectedCRC
					else
						needsDownload = previousRevision ~= revision
					end
				else
					CW.Warn("Cached asset " .. entry.path .. " is invalid (detected " .. actualFormat .. "); downloading again")
				end
			end

			if needsDownload then
				local remotePath = encodeURLPath(entry.path)
				local downloaded, bytes = pcall(CW.httpGet, baseURL .. "/" .. remotePath)
				if downloaded and type(bytes) == "string" then
					local actualFormat = detectAssetFormat(bytes)
					local expectedFormat = isAudioCategory(entry.category) and "audio" or entry.path:match("%.([%w]+)$"):lower()
					local expectedCRC = entry.crc32 and tostring(entry.crc32):lower():gsub("^0x", "")
					local actualCRC = string.format("%08x", CW.crc32Yielding(bytes)):lower()
					if not formatMatches(entry.category, entry.path, actualFormat) then
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

	-- Persist a valid manifest revision even when a few entries fail. Good files stay cached,
	-- while missing/invalid paths are retried because their files fail validation.
	pcall(writefile, CW.Paths.LIBRARY_REVISION_FILE, revision)
	-- Official files that are no longer in the manifest (for example a cursor removed from the
	-- repository) are deleted from the _Official folders. This no longer depends on every other
	-- download having succeeded; user files outside _Official are never touched.
	if #pending > 0 then
		if entriesTrusted then
			pruneOfficial(expected)
		else
			CW.Warn("The manifest has invalid entries; obsolete official files were not removed this time")
		end
	end
	if complete then
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
	CW.Library.invalidate() -- files may have been added or removed by hand since the last scan
	local ok, result = pcall(syncImpl)
	CW.Library.invalidate() -- ... and the sync itself may have written new ones
	CW.State.syncing = false
	CW.State.lastSyncResult = ok and result == true
	if not ok then error(result, 0) end
	return result
end

CW.Paths.CURSOR_FILE = CW.Library.selectedPath("Cursors")
CW.Paths.HITMARKER_FILE = CW.Library.selectedPath("Hitmarkers")
CW.Paths.SOUND_FILE = CW.Library.selectedPath("HitSounds")
end)

runModule("PNG", function()
-- PNG.lua
local CW = getgenv().__CW_CORE_STATE

local floor   = math.floor
local mmin    = math.min
local mmax    = math.max
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
	return u32be(#data)..p..u32be(CW.crc32Yielding(p))
end

-- Deflate "stored" blocks (no compression). The cursor files are small, local and only read by
-- the engine, so skipping compression makes the encoder dramatically faster than the old
-- bit-by-bit Huffman writer. Each block holds at most 65535 bytes.
local function deflateStored(raw)
	local parts = {}
	local total = #raw
	local pos = 1
	repeat
		local len = mmin(65535, total - pos + 1)
		local final = (pos + len > total) and 1 or 0
		local nlen = bxor(len, 0xFFFF)
		parts[#parts + 1] = schar(final, band(len, 0xFF), rshift(len, 8), band(nlen, 0xFF), rshift(nlen, 8))
		parts[#parts + 1] = raw:sub(pos, pos + len - 1)
		pos = pos + len
	until pos > total
	return tconcat(parts)
end

function CW.encodePNG(px, w, h)
	local rows = {}
	local rowLen = w * 4
	for y = 0, h - 1 do
		local base = y * rowLen
		local parts = { "\0" }
		for s = 1, rowLen, 4096 do
			parts[#parts + 1] = schar(tunpack(px, base + s, base + mmin(s + 4095, rowLen)))
		end
		rows[y + 1] = tconcat(parts)
		if y % 16 == 0 then CW.yieldBudget() end
	end
	local raw = tconcat(rows)
	return "\137\80\78\71\13\10\26\10"
		.. pngChunk("IHDR", u32be(w)..u32be(h).."\8\6\0\0\0")
		.. pngChunk("IDAT", "\120\1"..deflateStored(raw)..u32be(adler32(raw)))
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
			-- Stored block. The bit reader may already have prefetched whole bytes beyond the
			-- block header, so after discarding the partial byte those bytes are handed back
			-- (pos moves back) before the LEN/NLEN fields and the raw data are read.
			local partial = bitcount % 8
			if partial > 0 then readbits(partial) end
			pos = pos - floor(bitcount / 8)
			bitbuf, bitcount = 0, 0
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

-- Smooth resize. Shrinking averages every source pixel under the target pixel (box filter),
-- enlarging interpolates (bilinear). Colors are weighted by alpha, so transparent edges do
-- not bleed dark fringes into the cursor.
function CW.resizePixels(px, w, h, tw, th)
	if tw == w and th == h then return px, w, h end
	local out = {}
	local sx, sy = w / tw, h / th
	local ceil = math.ceil

	local function acc(i, weight, sr, sg, sb, sa)
		local a = (px[i + 3] or 0) * weight
		return sr + (px[i] or 0) * a, sg + (px[i + 1] or 0) * a, sb + (px[i + 2] or 0) * a, sa + a
	end

	for y = 0, th - 1 do
		if y % 4 == 0 then CW.yieldBudget() end
		for x = 0, tw - 1 do
			local dst = (y * tw + x) * 4 + 1
			local sr, sg, sb, sa = 0, 0, 0, 0
			local alpha

			if sx > 1 or sy > 1 then
				local x0 = mmin(floor(x * sx), w - 1)
				local x1 = mmin(mmax(x0, ceil((x + 1) * sx) - 1), w - 1)
				local y0 = mmin(floor(y * sy), h - 1)
				local y1 = mmin(mmax(y0, ceil((y + 1) * sy) - 1), h - 1)
				local count = 0
				for yy = y0, y1 do
					for xx = x0, x1 do
						sr, sg, sb, sa = acc((yy * w + xx) * 4 + 1, 1, sr, sg, sb, sa)
						count = count + 1
					end
				end
				alpha = sa / count
			else
				local fx = mmax(0, (x + 0.5) * sx - 0.5)
				local fy = mmax(0, (y + 0.5) * sy - 0.5)
				local x0, y0 = mmin(floor(fx), w - 1), mmin(floor(fy), h - 1)
				local x1, y1 = mmin(x0 + 1, w - 1), mmin(y0 + 1, h - 1)
				local tx, ty = fx - x0, fy - y0
				sr, sg, sb, sa = acc((y0 * w + x0) * 4 + 1, (1 - tx) * (1 - ty), sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y0 * w + x1) * 4 + 1, tx * (1 - ty), sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y1 * w + x0) * 4 + 1, (1 - tx) * ty, sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y1 * w + x1) * 4 + 1, tx * ty, sr, sg, sb, sa)
				alpha = sa
			end

			if sa > 0 then
				out[dst]     = mmin(255, floor(sr / sa + 0.5))
				out[dst + 1] = mmin(255, floor(sg / sa + 0.5))
				out[dst + 2] = mmin(255, floor(sb / sa + 0.5))
				out[dst + 3] = mmin(255, floor(alpha + 0.5))
			else
				out[dst], out[dst + 1], out[dst + 2], out[dst + 3] = 0, 0, 0, 0
			end
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
end)


runModule("Cursor", function()
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
	-- "|fit" marks the aspect-preserving resize, so caches made by older versions are rebuilt.
	return CW.computeFileSignature(
		CW.Paths.CURSOR_FILE, "cur",
		"|size:"..tostring(CW.Settings.CURSOR_TARGET_SIZE).."|fit"..tintSig
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
	-- Stored by the previous version, which forced MouseIconEnabled back on. That fought the
	-- game's sniper scope (it hides the cursor on purpose), so it is no longer done.
	if CW.State.enableConn then
		pcall(function() CW.State.enableConn:Disconnect() end)
		CW.State.enableConn = nil
	end

	CW.State.enforcerConn = UserInputService:GetPropertyChangedSignal("MouseIcon"):Connect(function()
		if CW.State.settingCursor or CW.State.scoped then return end
		if not CW.State.cursorsReady or not CW.State.currentCursorKey then return end
		local expected = CW.Assets[CW.State.currentCursorKey]
		if expected and UserInputService.MouseIcon ~= expected then
			CW.State.settingCursor = true
			UserInputService.MouseIcon = expected
			CW.State.settingCursor = false
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

	-- The longest side becomes the target size and the other side follows the image's aspect
	-- ratio, so non-square cursors are no longer stretched.
	local targetSize = CW.Settings.CURSOR_TARGET_SIZE
	if targetSize then
		local scale = targetSize / math.max(w, h)
		local tw = math.max(1, math.floor(w * scale + 0.5))
		local th = math.max(1, math.floor(h * scale + 0.5))
		px, w, h = CW.resizePixels(px, w, h, tw, th)
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

-- The codec yields, so runs are serialised: a request made while one is running marks the
-- state dirty and triggers exactly one more pass with the latest settings.
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

-- Sniper scope. While the game's scope frame is open, the game hides the cursor on purpose.
-- The custom cursor stays hidden for exactly that time (nothing is drawn over the scope and the
-- game's own crosshair does not come back), and it is restored as soon as the scope closes.
local function restoreCursorIcon()
	local url = CW.State.cursorsReady and CW.Assets[CW.State.currentCursorKey or "white"]
	if url then
		CW.State.settingCursor = true
		UserInputService.MouseIcon = url
		CW.State.settingCursor = false
	end
end

local function watchScope()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 30)
	local crosshairGui = playerGui and playerGui:WaitForChild("CrosshairGui", 30)
	local scopeFrame = crosshairGui and crosshairGui:WaitForChild("ScopeFrame", 30)
	if not scopeFrame then return end

	local function update()
		if scopeFrame.Visible then
			CW.State.scoped = true
			UserInputService.MouseIconEnabled = false
			-- Per frame, and only while scoped: whatever turns the icon back on is undone.
			CW.track("scopeHide", RunService.PreRender:Connect(function()
				if UserInputService.MouseIconEnabled then UserInputService.MouseIconEnabled = false end
			end))
		else
			CW.State.scoped = false
			CW.untrack("scopeHide")
			UserInputService.MouseIconEnabled = true
			restoreCursorIcon()
		end
	end
	CW.track("scopeWatch", scopeFrame:GetPropertyChangedSignal("Visible"):Connect(update))
	update()
end
task.spawn(watchScope)

-- Registered with CW.track: a re-run replaces the loop with this version's code.
do
	-- Mouse.Target is a raycast, so it is sampled 25 times per second instead of every frame.
	local CURSOR_CHECK_INTERVAL = 0.04
	local nextCursorCheck = 0
	CW.track("cursorLoop", RunService.PreRender:Connect(function()
		if not CW.State.cursorsReady then return end
		local now = os.clock()
		if now < nextCursorCheck then return end
		nextCursorCheck = now + CURSOR_CHECK_INTERVAL
		local Target = Mouse.Target
		if Target == CW.State.lastTarget then return end
		CW.State.lastTarget = Target
		if not Target or not Target.Parent then setOSCursor("white"); return end

		local Player = Players:GetPlayerFromCharacter(Target.Parent)
			or (Target.Parent.Parent and Players:GetPlayerFromCharacter(Target.Parent.Parent))

		if Player and Player ~= LocalPlayer then
			setOSCursor(Player.TeamColor == LocalPlayer.TeamColor and "green" or "red")
		else
			setOSCursor("white")
		end
	end))
end
end)

runModule("Hitmarker", function()
-- Hitmarker.lua
local CW = getgenv().__CW_CORE_STATE

local ContentProvider = game:GetService("ContentProvider")

-- Parents the GUI to the first container that accepts it: gethui() when the executor has it,
-- otherwise CoreGui, otherwise PlayerGui.
local function attachGui(gui)
	local candidates = {}
	if type(gethui) == "function" then
		local ok, container = pcall(gethui)
		if ok and typeof(container) == "Instance" then table.insert(candidates, container) end
	end
	local okCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if okCore and coreGui then table.insert(candidates, coreGui) end
	local playerGui = CW.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then table.insert(candidates, playerGui) end

	for _, container in ipairs(candidates) do
		local attached = pcall(function() gui.Parent = container end)
		if attached and gui.Parent == container then return true end
	end
	return false
end

-- Created on the first run, and again on a later run if the GUI is missing or was destroyed.
if not CW.IAPortable or not CW.IAPortable.Parent then
	if CW.IAPortable then pcall(function() CW.IAPortable:Destroy() end) end

	local gui = Instance.new("ScreenGui")
	gui.Name           = "CW_SA"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder   = 9998
	if not attachGui(gui) then
		CW.Warn("Could not parent the hitmarker GUI; hitmarkers will not be displayed")
	end
	CW.IAPortable = gui
end

if not CW.HMTemplate then
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

	-- Preload in the background so the first hitmarker is not blank.
	if asset then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync({ CW.HMTemplate }) end)
		end)
	end
end

CW.reloadHitmarkerAsset = reloadHitmarker
reloadHitmarker()
end)


runModule("Sound", function()
-- Sound.lua
local CW = getgenv().__CW_CORE_STATE

local SoundService    = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Debris          = game:GetService("Debris")

-- A few Sound objects are created ONCE when the hit sound is (re)loaded and preloaded with
-- ContentProvider. A hit then only rewinds one of them and calls :Play(), which is immediate.
-- They are used round-robin so rapid hits overlap instead of cutting each other off.
-- If the pool is unavailable for any reason, a fresh Sound per hit is used as a fallback.

local POOL_SIZE = 4

local function destroyPool()
	local pool = CW.State.hitSoundPool
	CW.State.hitSoundPool = nil
	CW.State.hitSoundIndex = 0
	if pool then
		for _, sound in ipairs(pool) do
			pcall(function() sound:Destroy() end)
		end
	end
end
CW.State.destroyHitSoundPool = destroyPool

local function buildPool(assetId)
	destroyPool()

	local pool = {}
	for _ = 1, POOL_SIZE do
		local ok, sound = pcall(function()
			local snd = Instance.new("Sound")
			snd.Name     = "CW_HitSound"
			snd.SoundId  = assetId
			snd.Volume   = CW.Settings.SOUND_VOLUME
			snd.Parent   = SoundService
			return snd
		end)
		if ok and sound then pool[#pool + 1] = sound end
	end
	if #pool == 0 then
		CW.Warn("Could not create the hit sound pool; falling back to on-demand sounds")
		return
	end

	CW.State.hitSoundPool = pool

	task.spawn(function()
		local ok, err = pcall(function() ContentProvider:PreloadAsync(pool) end)
		if not ok then CW.Log("Hit sound preload skipped: " .. tostring(err)) end
	end)
end

local function reloadSound()
	local asset, failReason = CW.loadLibraryAsset({
		file = CW.Paths.SOUND_FILE,
		label = "hit sound",
		audio = true,
	})
	if asset then
		CW.Settings.SOUND_ID = asset
		buildPool(asset)
	elseif failReason == "missing" or failReason == "error" then
		CW.Settings.SOUND_ID = nil
		destroyPool()
	end
end

CW.reloadSoundAsset = reloadSound
reloadSound()

local function playOnDemand()
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

function CW.playHitSound()
	if not CW.Settings.SOUND_ID then return end

	local pool = CW.State.hitSoundPool
	if pool and #pool > 0 then
		local index = ((CW.State.hitSoundIndex or 0) % #pool) + 1
		CW.State.hitSoundIndex = index
		local sound = pool[index]
		local ok = pcall(function()
			sound.Volume       = CW.Settings.SOUND_VOLUME
			sound.TimePosition = 0
			sound:Play()
		end)
		if ok then return end
	end

	playOnDemand()
end
end)


runModule("Texture", function()
-- Texture.lua
local CW = getgenv().__CW_CORE_STATE

local ContentProvider   = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = CW.LocalPlayer

CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER)

-- Two kinds of weapons can be textured:
--  * Regular guns have exactly one MeshPart, and that part carries the texture.
--  * FAL and M700 have no MeshPart: they are built from many block pieces. For them a custom
--    MeshPart (the whole gun as one model with proper UVs) is built and welded to the Handle, and
--    the original pieces are hidden while a texture is selected. Deselecting the texture removes
--    the custom mesh and shows the original pieces again.
local CUSTOM_MESH_WEAPONS = {
	["FAL"] = {
		meshId   = "rbxassetid://90772329772088",
		meshName = "FAL/Meshes",
		hide     = { ["Smooth Block Model"] = true, ["Black"] = true },
		offset   = Vector3.new(0.05, 0.2, -0.55),
		rotation = Vector3.new(0, 90, 0),
		size     = Vector3.new(0.4, 0.4, 0.4),
	},
	["M700"] = {
		meshId   = "rbxassetid://109235772617313",
		meshName = "M700/Meshes",
		hide     = { ["Smooth Block Model"] = true },
		offset   = Vector3.new(0, 0.43, -0.8),
		rotation = Vector3.new(0, 90, 0),
		size     = Vector3.new(1, 1, 1),
	},
}

local WEAPON_LIST = {}
local TEXTURABLE = {}
do
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	for _, tool in ipairs(guns and guns:GetChildren() or {}) do
		if tool:IsA("Tool") and tool:FindFirstChildWhichIsA("MeshPart", true) then
			TEXTURABLE[tool.Name] = true
		end
	end
	if next(TEXTURABLE) == nil then
		for _, name in ipairs({ "AK-47", "M4A1", "M9", "MP5", "Remington 870", "Revolver" }) do TEXTURABLE[name] = true end
	end
	for name in pairs(CUSTOM_MESH_WEAPONS) do TEXTURABLE[name] = true end
	for name in pairs(TEXTURABLE) do table.insert(WEAPON_LIST, name) end
	table.sort(WEAPON_LIST)
end

CW.WeaponList = WEAPON_LIST
CW.Assets.weaponTextures = {}
CW.Settings.ASSET_SELECTIONS.Textures = CW.Settings.ASSET_SELECTIONS.Textures or {}

for _, weaponName in ipairs(WEAPON_LIST) do
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName)
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName .. "/" .. CW.Paths.OFFICIAL_FOLDER)
end

-- Guns that have sounds to replace: every gun of the game that has a ToolProperties module. That
-- includes the Taser, which has no MeshPart (so it is not in WEAPON_LIST) but does shoot and reload.
-- Falls back to WEAPON_LIST when the game's folders are not found.
local SOUND_WEAPONS = {}
do
	local shared = ReplicatedStorage:FindFirstChild("SharedModules")
	local properties = shared and shared:FindFirstChild("ToolProperties")
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	if properties and guns then
		for _, tool in ipairs(guns:GetChildren()) do
			if tool:IsA("Tool") and properties:FindFirstChild(tool.Name) then
				table.insert(SOUND_WEAPONS, tool.Name)
			end
		end
	end
	if #SOUND_WEAPONS == 0 then
		for _, name in ipairs(WEAPON_LIST) do table.insert(SOUND_WEAPONS, name) end
	end
	table.sort(SOUND_WEAPONS)
end
CW.SoundWeaponList = SOUND_WEAPONS

for _, weaponName in ipairs(SOUND_WEAPONS) do
	-- Your own mp3, ogg, wav or flac files go in WeaponSounds/<Weapon>/ (shoot) and ReloadSounds/<Weapon>/ (reload).
	for _, folder in ipairs({ CW.Paths.WEAPON_SOUNDS_FOLDER, CW.Paths.RELOAD_SOUNDS_FOLDER }) do
		CW.Library.ensureFolder(folder .. "/" .. weaponName)
		CW.Library.ensureFolder(folder .. "/" .. weaponName .. "/" .. CW.Paths.OFFICIAL_FOLDER)
	end
end

-- What was changed is remembered on the instances themselves, as attributes. They live and die
-- with the instance (a new tool is a fresh clone) and survive a re-run of the script, so no
-- separate bookkeeping is needed to restore anything.
local ORIGINAL_TEXTURE = "CW_OriginalTexture"        -- on a regular gun's MeshPart
local ORIGINAL_TRANSPARENCY = "CW_OriginalTransparency" -- on the pieces hidden for a custom mesh

-- Returns true when the weapon's mesh was found (and the texture applied or restored).
local function applyRegularTexture(tool)
	local mesh = tool:FindFirstChildWhichIsA("MeshPart", true)
	if not mesh then return false end

	local textureId = CW.Assets.weaponTextures[tool.Name]
	local original = mesh:GetAttribute(ORIGINAL_TEXTURE)
	if textureId then
		if original == nil then mesh:SetAttribute(ORIGINAL_TEXTURE, mesh.TextureID) end
		if mesh.TextureID ~= textureId then
			local ok, err = pcall(function() mesh.TextureID = textureId end)
			if not ok then CW.Warn("Could not apply texture to " .. tool.Name .. ": " .. tostring(err)) end
		end
	elseif original ~= nil then
		local ok, err = pcall(function() mesh.TextureID = original end)
		if ok then
			mesh:SetAttribute(ORIGINAL_TEXTURE, nil)
		else
			CW.Warn("Could not restore the original texture of " .. tool.Name .. ": " .. tostring(err))
		end
	end
	return true
end

local function buildCustomMesh(tool, cfg)
	local handle = tool:FindFirstChild("Handle")
	if not handle then return nil end

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
	mesh.CFrame = handle.CFrame
		* CFrame.new(cfg.offset)
		* CFrame.Angles(math.rad(cfg.rotation.X), math.rad(cfg.rotation.Y), math.rad(cfg.rotation.Z))
	mesh.Parent = tool

	local weld = Instance.new("WeldConstraint")
	weld.Part0  = handle
	weld.Part1  = mesh
	weld.Parent = mesh
	CW.Log("Custom mesh built for " .. tool.Name)
	return mesh
end

-- Every BasePart of a piece (the piece itself and, for a Model, everything inside it).
local function forEachPart(piece, callback)
	if piece:IsA("BasePart") then callback(piece) end
	for _, descendant in ipairs(piece:GetDescendants()) do
		if descendant:IsA("BasePart") then callback(descendant) end
	end
end

local function hideOriginalPieces(tool, cfg, custom)
	for _, piece in ipairs(tool:GetChildren()) do
		if piece ~= custom and cfg.hide[piece.Name] then
			forEachPart(piece, function(part)
				if part:GetAttribute(ORIGINAL_TRANSPARENCY) == nil then
					part:SetAttribute(ORIGINAL_TRANSPARENCY, part.Transparency)
				end
				if part.Transparency ~= 1 then part.Transparency = 1 end
			end)
		end
	end
end

local function showOriginalPieces(tool)
	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local original = descendant:GetAttribute(ORIGINAL_TRANSPARENCY)
			if original ~= nil then
				descendant.Transparency = original
				descendant:SetAttribute(ORIGINAL_TRANSPARENCY, nil)
			end
		end
	end
end

local function applyCustomTexture(tool, cfg)
	local textureId = CW.Assets.weaponTextures[tool.Name]
	local custom = tool:FindFirstChild(cfg.meshName)
	if textureId then
		if not custom then custom = buildCustomMesh(tool, cfg) end
		if not custom then return false end -- no Handle yet
		hideOriginalPieces(tool, cfg, custom)
		if custom.TextureID ~= textureId then custom.TextureID = textureId end
	else
		if custom then custom:Destroy() end
		showOriginalPieces(tool)
	end
	return true
end

local function applyTexture(tool)
	local cfg = CUSTOM_MESH_WEAPONS[tool.Name]
	if cfg then return applyCustomTexture(tool, cfg) end
	return applyRegularTexture(tool)
end

local function applyToContainer(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") and TEXTURABLE[child.Name] then applyTexture(child) end
	end
end

-- Looked up through CW at call time, so the latest run's code is the one that runs.
CW.applyWeaponTexture = function(tool)
	if tool:IsA("Tool") and TEXTURABLE[tool.Name] then return applyTexture(tool) end
	return true
end

-- A tool arrives with its parts, so one pass is enough; if the mesh (or the Handle) is not there
-- yet, it is retried once shortly after.
local function monitor(container, key)
	CW.track(key, container.ChildAdded:Connect(function(child)
		local apply = CW.applyWeaponTexture
		if apply and not apply(child) then
			task.wait(0.1)
			apply = CW.applyWeaponTexture
			if apply then apply(child) end
		end
	end))
	applyToContainer(container)
end

local function reloadTexturesAndApply()
	local loadedTextures = {}
	local toPreload = {}
	for _, weaponName in ipairs(WEAPON_LIST) do
		local filePath = CW.Library.selectedPath("Textures", weaponName)
		if filePath then
			local ok, asset = pcall(getcustomasset, filePath)
			if ok and asset then
				loadedTextures[weaponName] = asset
				table.insert(toPreload, asset)
			else
				CW.Warn("Could not load selected texture for " .. weaponName)
			end
		end
	end
	CW.Assets.weaponTextures = loadedTextures

	if #toPreload > 0 then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync(toPreload) end)
		end)
	end

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then applyToContainer(backpack) end
	if LocalPlayer.Character then applyToContainer(LocalPlayer.Character) end
end
CW.reloadTextures = reloadTexturesAndApply
reloadTexturesAndApply()

-- Monitors are (re)created on every run, so a re-run replaces the old ones. The Backpack is
-- recreated on every respawn, so the player is always watched for a new one.
do
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then monitor(backpack, "textureBackpack") end
	CW.track("textureBackpackWait", LocalPlayer.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then monitor(child, "textureBackpack") end
	end))

	CW.track("textureCharacterAdded", LocalPlayer.CharacterAdded:Connect(function(character)
		monitor(character, "textureCharacter")
	end))

	if LocalPlayer.Character then
		monitor(LocalPlayer.Character, "textureCharacter")
	end
end
end)


runModule("Tracers", function()
-- Tracers.lua
local CW = getgenv().__CW_CORE_STATE

local Workspace         = game:GetService("Workspace")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = CW.LocalPlayer

-- (boolOr, numOr and _cfg come from the top of the script.)

-- UPPER_CASE is the standard key; the old camelCase keys still work.
local function cfgValue(upperKey, legacyKey)
	if _cfg[upperKey] ~= nil then return _cfg[upperKey] end
	return _cfg[legacyKey]
end

local function colorOr(v, default)
	if typeof(v) == "Color3" then return v end
	return default
end

local function unitOr(v, default) -- a number from 0 to 1 (transparency)
	return math.clamp(numOr(v, default), 0, 1)
end

CW.Settings.CUSTOM_BULLET_TRACERS  = boolOr(cfgValue("CUSTOM_BULLET_TRACERS", "customBulletTracers"), false)
CW.Settings.TRACER_COLOR           = cfgValue("TRACER_COLOR", "tracerColor") or Color3.fromRGB(170, 0, 255)
CW.Settings.TRACER_GLOW_COLOR      = cfgValue("TRACER_GLOW_COLOR", "glowColor") or Color3.fromRGB(200, 100, 255)
CW.Settings.TRACER_WIDTH           = numOr(cfgValue("TRACER_WIDTH", "tracerWidth"), 0.05, 0.01)
CW.Settings.TRACER_LIFETIME        = numOr(cfgValue("TRACER_LIFETIME", "tracerLifetime"), 0.05, 0.01)
CW.Settings.TRACER_TRANSPARENCY    = unitOr(cfgValue("TRACER_TRANSPARENCY", "tracerTransparency"), 0.1)
CW.Settings.TRACER_APPLY_TO_OTHERS = boolOr(cfgValue("TRACER_APPLY_TO_OTHERS", "applyToOthers"), false)
CW.Settings.TRACER_POINT_LIGHT     = boolOr(cfgValue("TRACER_POINT_LIGHT", "pointLight"), false)

-- The Sniper (M700) and the Taser have a tracer of their own. Every other gun is covered by the
-- settings above. A kind's own settings only apply while its ENABLED setting is on; the starting
-- values are the game's own (colour, width, how long the fade takes, starting transparency).
local KIND_DEFAULTS = {
	Sniper = { color = Color3.fromRGB(163, 162, 165), width = 0.17, lifetime = 2.8, transparency = 0.5 },
	Taser  = { color = Color3.fromRGB(4, 175, 236),   width = 0.2,  lifetime = 0.8, transparency = 0.5 },
}
local KINDS = {
	Sniper = { prefix = "TRACER_SNIPER_", original = "_originalCreateSniper" },
	Taser  = { prefix = "TRACER_TASER_",  original = "_originalCreateTaser", surfaceLight = true },
}
for kind, info in pairs(KINDS) do
	local defaults = KIND_DEFAULTS[kind]
	local prefix = info.prefix
	CW.Settings[prefix .. "ENABLED"]      = boolOr(_cfg[prefix .. "ENABLED"], false)
	CW.Settings[prefix .. "COLOR"]        = colorOr(_cfg[prefix .. "COLOR"], defaults.color)
	CW.Settings[prefix .. "WIDTH"]        = numOr(_cfg[prefix .. "WIDTH"], defaults.width, 0.01)
	CW.Settings[prefix .. "LIFETIME"]     = numOr(_cfg[prefix .. "LIFETIME"], defaults.lifetime, 0.01)
	CW.Settings[prefix .. "TRANSPARENCY"] = unitOr(_cfg[prefix .. "TRANSPARENCY"], defaults.transparency)
end

CW.Defaults = CW.Defaults or {}
for _, key in ipairs({
	"CUSTOM_BULLET_TRACERS", "TRACER_COLOR", "TRACER_GLOW_COLOR",
	"TRACER_WIDTH", "TRACER_LIFETIME", "TRACER_TRANSPARENCY", "TRACER_APPLY_TO_OTHERS", "TRACER_POINT_LIGHT",
	"TRACER_SNIPER_ENABLED", "TRACER_SNIPER_COLOR", "TRACER_SNIPER_WIDTH", "TRACER_SNIPER_LIFETIME", "TRACER_SNIPER_TRANSPARENCY",
	"TRACER_TASER_ENABLED", "TRACER_TASER_COLOR", "TRACER_TASER_WIDTH", "TRACER_TASER_LIFETIME", "TRACER_TASER_TRANSPARENCY",
}) do
	CW.Defaults[key] = CW.Settings[key]
end

-- A tracer is yours when you are shooting AND it starts at your own muzzle. Checking only the
-- attribute would also claim the tracers of other players that arrive while you shoot.
local function isLocalPlayerShot(startPos)
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute("Local_IsShooting") ~= true then return false end
	local muzzle = tool:FindFirstChild("Muzzle")
	return muzzle ~= nil and (muzzle.Position - startPos).Magnitude < 2
end

-- Part pool: tracer parts are reused instead of created and destroyed for every bullet
-- (shotgun pellets and automatic weapons make many per second). The PointLight is optional
-- (TRACER_POINT_LIGHT, off by default): it is created once per pooled part and only switched
-- on or off afterwards, so enabling it never creates a new light per bullet.
local MAX_POOL = 48
local pool = CW.State.tracerPool
if not pool then
	pool = {}
	CW.State.tracerPool = pool
end

local function newTracerPart()
	local part = Instance.new("Part")
	part.Anchored   = true
	part.CanCollide = false
	part.CanQuery   = false
	part.CanTouch   = false
	part.CastShadow = false
	part.Material   = Enum.Material.Neon
	return part
end

local function acquirePart(parent)
	while #pool > 0 do
		local part = table.remove(pool)
		if pcall(function() part.Parent = parent end) then return part end
	end
	local part = newTracerPart()
	part.Parent = parent
	return part
end

-- A pooled part may still carry a light from a previous use: lights are switched off on every
-- acquire and only the tracer that needs one switches it back on.
local function resetLights(part)
	for _, name in ipairs({ "CW_Light", "CW_Surface" }) do
		local light = part:FindFirstChild(name)
		if light then light.Enabled = false end
	end
end

local function releasePart(part)
	pcall(function() part.Parent = nil end)
	if #pool < MAX_POOL then
		pool[#pool + 1] = part
	else
		pcall(function() part:Destroy() end)
	end
end

local function createEnergyTracer(startPos, endPos)
	local camera = Workspace.CurrentCamera
	if not camera then error("no current camera", 0) end

	local distance = (startPos - endPos).Magnitude
	local midpoint = (startPos + endPos) / 2
	local width = CW.Settings.TRACER_WIDTH
	local life  = CW.Settings.TRACER_LIFETIME

	local transparency = CW.Settings.TRACER_TRANSPARENCY

	local core = acquirePart(camera)
	resetLights(core)
	core.Color        = CW.Settings.TRACER_COLOR
	core.Size         = Vector3.new(width, width, distance)
	core.CFrame       = CFrame.new(midpoint, endPos)
	core.Transparency = transparency

	local light = core:FindFirstChild("CW_Light")
	if CW.Settings.TRACER_POINT_LIGHT then
		if not light then
			light = Instance.new("PointLight")
			light.Name       = "CW_Light"
			light.Range      = 8
			light.Brightness = 2
			light.Parent     = core
		end
		light.Color   = CW.Settings.TRACER_COLOR
		light.Enabled = true
	elseif light then
		light.Enabled = false
	end

	local glow = acquirePart(camera)
	resetLights(glow)
	glow.Color        = CW.Settings.TRACER_GLOW_COLOR
	glow.Size         = Vector3.new(width * 2, width * 2, distance)
	glow.CFrame       = core.CFrame
	-- The glow is always fainter than the core: at the default core transparency (0.1) it is 0.6.
	glow.Transparency = 1 - (1 - transparency) * (0.4 / 0.9)

	TweenService:Create(core, TweenInfo.new(life), { Transparency = 1 }):Play()
	TweenService:Create(glow, TweenInfo.new(life), { Transparency = 1 }):Play()

	-- Returned to the pool just after the fade ends.
	task.delay(life + 0.05, function()
		releasePart(core)
		releasePart(glow)
	end)
end

-- Sniper and taser tracers with their own settings. The game's own functions cannot be adjusted
-- after the fact (they start a transparency tween that cannot be stopped or lengthened), so the
-- tracer is drawn here instead, from the same ingredients: a neon part between the muzzle and the
-- hit that fades out with a Quad "In" tween, plus, for the taser, a SurfaceLight that fades with it.
local function createKindTracer(kind, startPos, endPos)
	local camera = Workspace.CurrentCamera
	if not camera then error("no current camera", 0) end

	local info = KINDS[kind]
	local color        = CW.Settings[info.prefix .. "COLOR"]
	local width        = CW.Settings[info.prefix .. "WIDTH"]
	local life         = CW.Settings[info.prefix .. "LIFETIME"]
	local transparency = CW.Settings[info.prefix .. "TRANSPARENCY"]

	local distance = (startPos - endPos).Magnitude
	local part = acquirePart(camera)
	resetLights(part)
	part.Color        = color
	part.Size         = Vector3.new(width, width, distance)
	part.CFrame       = CFrame.new((startPos + endPos) / 2, endPos)
	part.Transparency = transparency

	local fade = TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(part, fade, { Transparency = 1 }):Play()

	if info.surfaceLight then
		local light = part:FindFirstChild("CW_Surface")
		if not light then
			light = Instance.new("SurfaceLight")
			light.Name  = "CW_Surface"
			light.Range = 7
			light.Face  = Enum.NormalId.Bottom
			light.Angle = 180
			light.Parent = part
		end
		light.Color      = color
		light.Brightness = 5
		light.Enabled    = true
		TweenService:Create(light, fade, { Brightness = 0 }):Play()
	end

	-- Returned to the pool just after the fade ends.
	task.delay(life + 0.05, releasePart, part)
end

-- Without the kind's own tracer the taser and sniper keep the game's width, fade and lifetime and
-- only their color changes (to TRACER_COLOR, while custom tracers are on). The game's functions
-- create one part named "RayPart" and parent it to the camera, so the new tracer is the RayPart
-- that was not there before the call.
local function snapshotRayParts()
	local seen = {}
	local camera = Workspace.CurrentCamera
	if camera then
		for _, child in ipairs(camera:GetChildren()) do
			if child.Name == "RayPart" then seen[child] = true end
		end
	end
	return seen
end

local function recolorNewRayParts(before)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	for _, child in ipairs(camera:GetChildren()) do
		if child.Name == "RayPart" and not before[child] then
			child.Color = CW.Settings.TRACER_COLOR
			local light = child:FindFirstChildOfClass("SurfaceLight") -- the taser has one
			if light then light.Color = CW.Settings.TRACER_COLOR end
		end
	end
end

local function shouldUseCustom(startPos)
	if not CW.Settings.CUSTOM_BULLET_TRACERS then return false end
	if CW.Settings.TRACER_APPLY_TO_OTHERS then return true end
	return isLocalPlayerShot(startPos)
end

local function warnTracerFailure(err)
	if CW.State.tracerFailureWarned then return end
	CW.State.tracerFailureWarned = true
	CW.Warn("Custom tracer failed; using the game's tracer instead: " .. tostring(err))
end

-- The wrappers run on the game's own thread, so they must never throw into the game's gun
-- code: a failing custom tracer falls back to the game's own function. The game always calls
-- the three tracer functions with exactly two arguments (start, end).
local function makeTracerWrapper(originalKey)
	return function(startPos, endPos)
		local okUse, useCustom = pcall(shouldUseCustom, startPos)
		if okUse and useCustom then
			local okDraw, err = pcall(createEnergyTracer, startPos, endPos)
			if okDraw then return end
			warnTracerFailure(err)
		end
		local original = CW[originalKey]
		if original then return original(startPos, endPos) end
	end
end

-- Taser and sniper without their own tracer: the game's tracer, recolored afterwards when custom tracers apply.
local function makeRecolorWrapper(originalKey)
	return function(startPos, endPos)
		local okUse, useCustom = pcall(shouldUseCustom, startPos)
		local before
		if okUse and useCustom then
			local okSnapshot, snapshot = pcall(snapshotRayParts)
			if okSnapshot then before = snapshot end
		end
		local original = CW[originalKey]
		if original then original(startPos, endPos) end
		if before then
			local ok, err = pcall(recolorNewRayParts, before)
			if not ok then warnTracerFailure(err) end
		end
	end
end

-- Taser and sniper: the kind's own tracer when its ENABLED setting is on (and the shot is yours, or
-- "apply to others" is on); otherwise the recolor behaviour above. Never throws into the game.
local function makeKindWrapper(kind)
	local info = KINDS[kind]
	local fallback = makeRecolorWrapper(info.original)
	return function(startPos, endPos)
		if CW.Settings[info.prefix .. "ENABLED"] == true then
			local okOwn, own = pcall(function()
				return CW.Settings.TRACER_APPLY_TO_OTHERS or isLocalPlayerShot(startPos)
			end)
			if okOwn and own then
				local okDraw, err = pcall(createKindTracer, kind, startPos, endPos)
				if okDraw then return end
				warnTracerFailure(err)
			end
		end
		return fallback(startPos, endPos)
	end
end

-- Installs the wrappers; returns false (so we can retry) if the game module isn't ready yet.
-- The game's own functions are captured once and kept in CW, so installing again on a re-run
-- replaces our wrappers with the new ones instead of stacking them.
local function installTracers()
	if not CW.TracersModule then
		local shared = ReplicatedStorage:FindFirstChild("SharedModules")
		local moduleScript = shared and shared:FindFirstChild("GunTracers")
		if not moduleScript then return false end

		local ok, TracersModule = pcall(require, moduleScript)
		if not ok or type(TracersModule) ~= "table" then return false end

		CW.TracersModule          = TracersModule
		CW._originalCreateBullet  = TracersModule.createBullet
		CW._originalCreateTaser   = TracersModule.createTaser
		CW._originalCreateSniper  = TracersModule.createSniper
	end

	local TracersModule = CW.TracersModule
	if type(CW._originalCreateBullet) == "function" then
		TracersModule.createBullet = makeTracerWrapper("_originalCreateBullet")
	end
	if type(CW._originalCreateTaser) == "function" then
		TracersModule.createTaser = makeKindWrapper("Taser")
	end
	if type(CW._originalCreateSniper) == "function" then
		TracersModule.createSniper = makeKindWrapper("Sniper")
	end

	CW.Log("Tracer override installed.")
	return true
end

-- The module is shared with the game's own scripts, so it exists from the start; the waits only
-- matter if the script runs very early.
task.spawn(function()
	local shared = ReplicatedStorage:WaitForChild("SharedModules", 30)
	if not (shared and shared:WaitForChild("GunTracers", 30)) then
		CW.Warn("GunTracers module not found — custom tracers disabled.")
		return
	end
	if not installTracers() then
		CW.Warn("Could not load the GunTracers module — custom tracers disabled.")
	end
end)
end)


runModule("Hook", function()
-- Hook.lua
local CW = getgenv().__CW_CORE_STATE

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

-- How it works
--   The __namecall hook runs on the GAME's thread, which lacks the capabilities needed to
--   parent GUI into gethui() ("lacking capability Plugin"). So the hook does nothing but
--   copy the hit parts into a small queue (plain tables only, no Instance method calls).
--   A PreRender connection created from this script's own thread drains the queue and does
--   the real work (hit sound + hitmarker).

local MAX_QUEUE   = 32   -- shots waiting for the next frame (oldest dropped beyond this)
local MAX_BULLETS = 8    -- bullets copied per shot (the shotgun sends 5)
local MAX_AGE     = 1    -- seconds; older queued shots are discarded instead of drawn late

CW.State.shotQueue = CW.State.shotQueue or {}

-- Called from the game's thread: ONLY table work here. No :Method() calls on Instances.
function CW.onShot(bullets)
	if type(bullets) ~= "table" then return end

	local hits, n = {}, 0
	for _, bullet in pairs(bullets) do
		if n >= MAX_BULLETS then break end
		if type(bullet) == "table" then
			local hit = bullet[3]
			if hit ~= nil then
				n = n + 1
				hits[n] = hit
			end
		end
	end
	if n == 0 then return end

	local queue = CW.State.shotQueue
	if #queue >= MAX_QUEUE then table.remove(queue, 1) end
	queue[#queue + 1] = { hits = hits, time = os.clock() }
end

-- Runs on this script's thread (from the PreRender drain): the real shot logic.
function CW.processShot(hits)
	local shotHit = false
	for i = 1, #hits do
		local hit = hits[i]
		if typeof(hit) == "Instance" and hit:IsA("BasePart") and hit.Parent then
			local character = hit:FindFirstAncestorOfClass("Model") -- same lookup the game uses
			local player = character and Players:GetPlayerFromCharacter(character)
			if player and CW.isEnemy(player) then
				shotHit = true
				break
			end
		end
	end
	if not shotHit then return end
	CW.playHitSound()
	if not CW.HMTemplate or not CW.IAPortable then return end

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

local function traceHandler(err)
	return debug.traceback(tostring(err), 2)
end

-- Empties the queue. Errors are caught per shot and printed with a traceback (first 5 only,
-- so a persistent failure cannot flood the console).
function CW.drainShots()
	local queue = CW.State.shotQueue
	if not queue or #queue == 0 then return end
	CW.State.shotQueue = {}

	local now = os.clock()
	for i = 1, #queue do
		local entry = queue[i]
		if now - entry.time <= MAX_AGE then
			local ok, err = xpcall(CW.processShot, traceHandler, entry.hits)
			if not ok then
				CW.State.shotErrors = (CW.State.shotErrors or 0) + 1
				if CW.State.shotErrors <= 5 then
					CW.Warn("Shot handler error: " .. tostring(err))
				end
			end
		end
	end
end

CW.track("shotDrain", RunService.PreRender:Connect(function()
	local drain = CW.drainShots
	if drain then drain() end
end))

-- The hook only forwards the call: it copies the hit parts into the queue and returns the
-- game's own result untouched, so it can never break or delay the game's FireServer.
local function installShootHook(shootEvent)
	if CW.State.shootHooked then return end
	CW.ShootEvent = shootEvent

	local isExecutorCall = type(checkcaller) == "function" and checkcaller or function() return false end
	local wrap = type(newcclosure) == "function" and newcclosure or function(fn) return fn end

	local OldNameCall
	OldNameCall = hookmetamethod(shootEvent, "__namecall", wrap(function(self, ...)
		if getnamecallmethod() == "FireServer" and not isExecutorCall() and self == CW.ShootEvent then
			local enqueue = CW.onShot
			if enqueue then pcall(enqueue, (...)) end
		end
		return OldNameCall(self, ...)
	end))

	CW.State.shootHooked = true
	CW.Log("ShootEvent hook installed")
end

if not CW.Caps.hook then
	if not CW.State.hookCapabilityWarned then
		CW.State.hookCapabilityWarned = true
		CW.Warn("hookmetamethod/getnamecallmethod unavailable; hitmarker and hit sound detection is disabled")
	end
else
	-- GunRemotes.ShootEvent exists from the start of the game; the waits only matter if the
	-- script runs very early.
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("GunRemotes", 30)
		local shootEvent = remotes and remotes:WaitForChild("ShootEvent", 30)
		if not shootEvent then
			CW.Warn("GunRemotes.ShootEvent not found; hitmarker detection unavailable")
			return
		end
		local ok, err = pcall(installShootHook, shootEvent)
		if not ok then CW.Warn("Could not install the ShootEvent hook: " .. tostring(err)) end
	end)
end
end)


runModule("Cleanup", function()
-- Cleanup.lua
local CW = getgenv().__CW_CORE_STATE

local UserInputService = game:GetService("UserInputService")

local LocalPlayer = CW.LocalPlayer

-- Runs when the player leaves the game. It is looked up through CW when it fires, so a
-- re-run's version is the one that runs.
function CW.cleanup()
	pcall(function() UserInputService.MouseIconEnabled=true end)
	pcall(function() UserInputService.MouseIcon="" end)
	pcall(function() CW.IAPortable:Destroy() end)
	pcall(function() if CW.UIWindow then CW.UIWindow:Destroy() end end)
	for _, key in ipairs({
		"enforcerConn", "enableConn", "sprintCharacterConn", "chatToggleConn",
	}) do
		pcall(function()
			local connection = CW.State[key]
			if connection then connection:Disconnect() end
		end)
	end
	pcall(function() CW.Settings.AUTO_RELOAD_ENABLED = false end)
	pcall(function() if CW.State.stopWeaponShootSoundOverrides then CW.State.stopWeaponShootSoundOverrides() end end)
	pcall(function() if CW.State.destroyHitSoundPool then CW.State.destroyHitSoundPool() end end)
	pcall(function()
		local contextActions = game:GetService("ContextActionService")
		contextActions:UnbindAction("CycleWareSprintToggle")
		contextActions:UnbindAction("CycleWareProtectSprint")
	end)
	pcall(CW.untrackAll)
	CW.ActiveFollowClones = {}
end

CW.track("cleanup", LocalPlayer.AncestryChanged:Connect(function()
	if LocalPlayer:IsDescendantOf(game) then return end
	local cleanup = CW.cleanup
	if cleanup then pcall(cleanup) end
end))
end)


runModule("Sync", function()
-- Sync.lua
-- Runs independently of the UI: official assets are downloaded even if the UI fails to load,
-- and everything that consumes assets is reloaded as soon as the download finishes.
local CW = getgenv().__CW_CORE_STATE

function CW.reloadCoreAssets()
	CW.Paths.CURSOR_FILE = CW.Library.selectedPath("Cursors")
	CW.Paths.HITMARKER_FILE = CW.Library.selectedPath("Hitmarkers")
	CW.Paths.SOUND_FILE = CW.Library.selectedPath("HitSounds")

	-- The cursor goes last: generating it yields for a while (PNG codec), and it must not
	-- delay the textures and the hit sound.
	local reloaders = {
		{ "hitmarker", CW.reloadHitmarkerAsset },
		{ "textures", CW.reloadTextures },
		{ "sound", CW.reloadSoundAsset },
		{ "cursor", CW.reloadCursor },
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
end)

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

--// Download the UI library
local UI_URL = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/CWUI.lua"
CW.Log("Downloading CycleWare UI from GitHub")
local UI_CACHE_FILE = CW.Paths.CACHE_FOLDER .. "/CWUI.lua"
local fetchOK, uiSource = false, nil
local localUIFile = type(_cfg.UI_FILE) == "string" and _cfg.UI_FILE ~= "" and _cfg.UI_FILE or nil
if localUIFile then
	-- Teste local: getgenv().CW_CONFIG = { UI_FILE = "CWUI.lua" } (caminho no workspace do executor)
	local readOK, data = pcall(readfile, localUIFile)
	if readOK and type(data) == "string" and data ~= "" then
		fetchOK, uiSource = true, data
		CW.Log("Using the local UI file: " .. localUIFile)
	else
		CW.Warn("UI_FILE could not be read (" .. localUIFile .. "); downloading the UI instead")
	end
end
if not fetchOK then
	fetchOK, uiSource = pcall(CW.httpGet, UI_URL)
	if fetchOK and type(uiSource) == "string" and uiSource:find("CreateWindow", 1, true) then
		pcall(writefile, UI_CACHE_FILE, uiSource) -- guarda a última cópia boa
	else
		local cacheOK, cached = pcall(readfile, UI_CACHE_FILE)
		if cacheOK and type(cached) == "string" and cached:find("CreateWindow", 1, true) then
			CW.Warn("Could not download the UI (" .. tostring(uiSource) .. "); using the last saved copy")
			fetchOK, uiSource = true, cached
		end
	end
end
assert(fetchOK and type(uiSource) == "string" and uiSource ~= "", "Could not download CWUI.lua from GitHub: " .. tostring(uiSource))

local loadUI, compileError = loadstring(uiSource)
assert(type(loadUI) == "function", tostring(compileError or "Could not compile CWUI.lua"))
local CWUI = loadUI()
assert(type(CWUI) == "table" and type(CWUI.CreateWindow) == "function", "Invalid CWUI library")

if CW.UIWindow and type(CW.UIWindow.Destroy) == "function" then
	pcall(function() CW.UIWindow:Destroy() end)
end
-- Ícones opcionais (caminho no workspace ou ID do Roblox). Exemplo, antes de executar o script:
--   getgenv().CW_CONFIG = { UI_ICONS = { Logo = "CW/logo.png", Discord = 456, Info = 789, Settings = 123,
--                                         Effects = 111, Visuals = 222, Sounds = 333, Utilities = 444 },
--                           DISCORD_URL = "https://discord.gg/xxxx" }
-- (Settings vale para o botão do rodapé e para a aba Settings; as outras abas usam o próprio nome.)
local uiIcons = type(_cfg.UI_ICONS) == "table" and _cfg.UI_ICONS or {}
local Window = CWUI:CreateWindow({
	Title = "CW",
	ToggleKey = false,
	Logo = uiIcons.Logo,
	Icons = { Settings = uiIcons.Settings, Discord = uiIcons.Discord, Info = uiIcons.Info },
	Discord = type(_cfg.DISCORD_URL) == "string" and _cfg.DISCORD_URL or nil,
})
CW.UIWindow = Window
Window.ToggleVisibility = Window.Toggle

local function mapControlOptions(options)
	options = options or {}
	return {
		Name = options.Title or options.Name,
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
	-- Color picker (CWUI 2.2+). Returns nil when the loaded CWUI has no picker, so the caller can
	-- fall back to something else (an old copy of CWUI.lua may still be cached on disk).
	function adapter:Colorpicker(control)
		if type(section.AddColorpicker) ~= "function" then return nil end
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddColorpicker(o)
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
	local tab = Window:AddTab({ Name = tabName, Icon = options.Icon or uiIcons[tabName] })
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

local function applySoundFile(value)
	local path = hitSoundPath(value)
	if not path then return end
	CW.Paths.SOUND_FILE = path
	CW.Library.setSelection("HitSounds", nil, CW.Library.relative(path))
	if CW.reloadSoundAsset then CW.reloadSoundAsset() end
end

local hitSoundOptions = refreshHitSoundCatalog()

------------------------------------------------------------------------------
-- Weapon sound changers: one factory, one instance per action (shoot, reload).
--
-- How the game plays a gun sound: the Handle of the Tool holds one Sound per action (named
-- ShootSound, ReloadSound). Every time the action happens the game CLONES that Sound into the
-- same Handle, plays the clone and removes it a few seconds later; for other players the server
-- sends the Sound instance and their client clones and plays it the same way. So replacing the
-- SoundId of the original replaces it for every clone made afterwards, mine and the others'.
-- The weapon is the Tool the Sound lives in: Sound.Parent = Handle, Handle.Parent = Tool, and the
-- Tool's name is the weapon's name.
------------------------------------------------------------------------------
local WEAPON_SOUND_DEFAULT = "Default"

-- A previous run (even of an older version) keeps watching until it is told to stop.
if CW.State.stopWeaponShootSoundOverrides then
	pcall(CW.State.stopWeaponShootSoundOverrides)
end

local function disconnectList(connections)
	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(connections)
end

local function findSoundTool(sound)
	local ancestor = sound.Parent
	while ancestor do
		if ancestor:IsA("Tool") then return ancestor end
		ancestor = ancestor.Parent
	end
	return nil
end

-- Guns that have sounds to replace (set up by the Texture module; includes the Taser).
local function soundWeaponNames()
	return CW.SoundWeaponList or CW.WeaponList or {}
end

-- spec = {
--   Category    = "WeaponSounds" | "ReloadSounds"   library folder: <Category>/<Weapon>/<file>
--   SoundName   = "ShootSound" | "ReloadSound"      the Sound instance the game plays
--   OverridesKey, EnabledKey, OthersKey, VolumeKey  saved settings (names unchanged for the shoot sounds)
--   ConfigKey                                       optional CW_CONFIG table: { ["AK-47"] = "WeaponSounds/AK-47/x.mp3" }
--   BaseVolume(originalId, player)                  optional: volume the game itself plays this sound at
-- }
local function createSoundChanger(spec)
	local settings = CW.Settings
	local configured = settings[spec.OverridesKey] or _cfg[spec.ConfigKey]
	settings[spec.OverridesKey] = type(configured) == "table" and configured or {}
	-- Off by default: nothing changes in the game until the player turns it on.
	if settings[spec.EnabledKey] == nil then settings[spec.EnabledKey] = _cfg[spec.EnabledKey] == true end
	if settings[spec.OthersKey] == nil then settings[spec.OthersKey] = _cfg[spec.OthersKey] == true end
	-- Volume multiplier for the replaced sounds, relative to the game's own volume.
	settings[spec.VolumeKey] = math.clamp(tonumber(settings[spec.VolumeKey]) or 1, 0, 2)
	CW.Defaults[spec.VolumeKey] = 1

	local overrides = settings[spec.OverridesKey]
	local changer = { spec = spec, overrides = overrides, catalog = {}, dropdowns = {}, migrated = false }
	local active = setmetatable({}, { __mode = "k" })     -- Sound -> data about what was changed
	local watched = setmetatable({}, { __mode = "k" })    -- container -> { player, connections }
	local playerConnections, globalConnections = {}, {}
	local refreshScheduled, generation = false, 0
	local assetIds = {} -- relative path -> getcustomasset id; rebuilt with every refresh

	--// library catalog ---------------------------------------------------------------
	-- "<Category>/<weapon>/rest" -> "rest" (nil when the path is not inside that weapon's folder).
	local function tailOf(weapon, relative)
		if type(weapon) ~= "string" or type(relative) ~= "string" then return nil end
		if relative:find("..", 1, true) or relative:find("\\", 1, true) then return nil end
		local prefix = spec.Category .. "/" .. weapon .. "/"
		if relative:sub(1, #prefix) ~= prefix or #relative == #prefix then return nil end
		return relative:sub(#prefix + 1)
	end

	function changer.refreshCatalog()
		table.clear(changer.catalog)
		for _, weapon in ipairs(soundWeaponNames()) do
			local entry = { options = { WEAPON_SOUND_DEFAULT }, byLabel = {}, available = {} }
			for _, item in ipairs(CW.Library.list(spec.Category, weapon)) do
				local tail = tailOf(weapon, item.Relative)
				if tail then
					local label = tail:gsub("^_Official/", "")
					if entry.byLabel[label] then label = tail end -- a user file with the same name as an official one
					entry.byLabel[label] = item.Relative
					entry.available[item.Relative] = true
					table.insert(entry.options, label)
				end
			end
			changer.catalog[weapon] = entry
		end
	end

	-- Text shown in a weapon's dropdown for a saved override (also when the file is not on disk yet).
	function changer.label(weapon, relative)
		local tail = tailOf(weapon, relative)
		if not tail then return WEAPON_SOUND_DEFAULT end
		local entry = changer.catalog[weapon]
		if entry then
			for label, savedRelative in pairs(entry.byLabel) do
				if savedRelative == relative then return label end
			end
		end
		return (tail:gsub("^_Official/", ""))
	end

	-- A saved selection that does not point inside its own weapon's folder (the shoot sounds used
	-- to share the HitSounds library) is dropped once, with a warning.
	do
		local dropped = {}
		for weapon, path in pairs(overrides) do
			if type(path) ~= "string" or not tailOf(weapon, path) then
				overrides[weapon] = nil
				if type(path) == "string" then table.insert(dropped, tostring(weapon)) end
			end
		end
		if #dropped > 0 then
			table.sort(dropped)
			changer.migrated = true
			CW.Warn("A saved " .. spec.Label .. " sound selection did not point at the " .. spec.Category
				.. " library and was removed for: " .. table.concat(dropped, ", ") .. ". Choose a new sound for them in the Sounds tab.")
		end
	end
	changer.refreshCatalog()

	--// volume ---------------------------------------------------------------------------
	-- baseVolume is the game's own volume for that sound; the sound plays at baseVolume * the slider.
	-- If the game itself changes the volume later (distance, per-shot values), that new value becomes
	-- the base, so the slider always scales the game's value.
	local function setScaledVolume(sound, data)
		local target = math.clamp(data.baseVolume * (settings[spec.VolumeKey] or 1), 0, 10)
		data.lastVolume = target
		if sound.Volume ~= target then
			pcall(function() sound.Volume = target end)
		end
	end

	function changer.updateVolumes()
		for sound, data in pairs(active) do
			if sound.Parent then setScaledVolume(sound, data) end
		end
	end

	local function restoreSound(sound)
		local data = active[sound]
		if not data then return end
		active[sound] = nil
		if data.connection then
			pcall(function() data.connection:Disconnect() end)
		end
		if data.volumeConnection then
			pcall(function() data.volumeConnection:Disconnect() end)
		end
		if sound.Parent then
			pcall(function()
				sound.SoundId = data.originalId
				sound.Volume = data.originalVolume
			end)
		end
	end

	function changer.stop()
		generation = generation + 1
		refreshScheduled = false
		table.clear(assetIds)
		disconnectList(globalConnections)
		for _, connections in pairs(playerConnections) do
			disconnectList(connections)
		end
		table.clear(playerConnections)
		for container, data in pairs(watched) do
			disconnectList(data.connections)
			watched[container] = nil
		end
		for sound in pairs(active) do
			restoreSound(sound)
		end
	end

	--// applying ---------------------------------------------------------------------------
	local function applySound(sound, targetId, tool, player, container)
		local data = active[sound]
		if not data then
			local originalId, originalVolume = sound.SoundId, sound.Volume
			local baseVolume = originalVolume

			-- The game plays a CLONE of the Sound. The clone of a sound that was already replaced arrives
			-- with the replacement id and the already scaled volume, so its original values (and the
			-- base the volume slider scales) come from the sound it was cloned from: a sibling in the
			-- same Handle. Without this the slider would be applied twice (0.5x would play at 0.25x).
			local sibling
			if sound.SoundId == targetId then
				for other, otherData in pairs(active) do
					if other ~= sound and other.Parent == sound.Parent and other.Name == sound.Name
						and otherData.targetId == targetId then
						sibling = otherData
						break
					end
				end
			end
			if sibling then
				originalId, originalVolume, baseVolume = sibling.originalId, sibling.originalVolume, sibling.baseVolume
			elseif spec.BaseVolume then
				baseVolume = spec.BaseVolume(sound.SoundId, player) or baseVolume
			end

			data = {
				originalId = originalId,
				originalVolume = originalVolume,
				baseVolume = baseVolume,
				lastVolume = baseVolume,
				tool = tool,
				player = player,
				container = container,
				targetId = targetId,
			}
			active[sound] = data
			local ok, connection = pcall(function()
				return sound:GetPropertyChangedSignal("SoundId"):Connect(function()
					local current = active[sound]
					if current and sound.Parent and sound.SoundId ~= current.targetId then
						pcall(function() sound.SoundId = current.targetId end)
					end
				end)
			end)
			if ok then data.connection = connection end

			local okVolume, volumeConnection = pcall(function()
				return sound:GetPropertyChangedSignal("Volume"):Connect(function()
					local current = active[sound]
					if not current or not sound.Parent then return end
					if math.abs(sound.Volume - current.lastVolume) > 0.0001 then
						current.baseVolume = sound.Volume -- the game changed it: scale the new value
						setScaledVolume(sound, current)
					end
				end)
			end)
			if okVolume then data.volumeConnection = volumeConnection end
		else
			data.tool = tool
			data.player = player
			data.container = container
			data.targetId = targetId
		end

		if sound.SoundId ~= targetId then
			pcall(function() sound.SoundId = targetId end)
		end
		setScaledVolume(sound, data)
	end

	-- Engine asset id of an override file (cached in assetIds), or nil when the file is missing
	-- or cannot be loaded. Shared by the tool hook and the background pre-load below.
	local function resolveAsset(relativePath)
		local cached = assetIds[relativePath]
		if cached then return cached end
		local filePath = CW.Paths.LIBRARY_ROOT .. "/" .. relativePath
		local okFile, exists = pcall(isfile, filePath)
		if not (okFile and exists) then return nil end
		local loaded, assetId = pcall(CW.Library.audioAsset, filePath)
		if not loaded or type(assetId) ~= "string" then return nil end
		assetIds[relativePath] = assetId
		return assetId
	end

	local function applyToTool(tool, player, container)
		if not tool:IsA("Tool") then return end
		if not settings[spec.EnabledKey] then return end
		if player ~= LocalPlayer and not settings[spec.OthersKey] then return end

		local relativePath = overrides[tool.Name]
		if type(relativePath) ~= "string" then return end
		local targetId = resolveAsset(relativePath)
		if not targetId then return end
		for _, descendant in ipairs(tool:GetDescendants()) do
			if descendant:IsA("Sound") and descendant.Name == spec.SoundName then
				applySound(descendant, targetId, tool, player, container)
			end
		end
	end

	local function unwatchContainer(container)
		local data = watched[container]
		if not data then return end
		watched[container] = nil
		disconnectList(data.connections)
		for sound, soundData in pairs(active) do
			if soundData.container == container then
				restoreSound(sound)
			end
		end
	end

	local function watchContainer(container, player)
		if watched[container] then return end
		local data = { player = player, connections = {} }
		watched[container] = data

		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				applyToTool(child, player, container)
			end
		end

		table.insert(data.connections, container.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("Tool") then
				task.defer(applyToTool, descendant, player, container)
			elseif descendant:IsA("Sound") and descendant.Name == spec.SoundName then
				local tool = findSoundTool(descendant)
				if tool then applyToTool(tool, player, container) end
			end
		end))

		table.insert(data.connections, container.DescendantRemoving:Connect(function(descendant)
			if descendant:IsA("Sound") then
				restoreSound(descendant)
			elseif descendant:IsA("Tool") then
				for sound, soundData in pairs(active) do
					if soundData.tool == descendant then restoreSound(sound) end
				end
			end
		end))
	end

	local function removePlayer(player)
		local connections = playerConnections[player]
		if connections then
			disconnectList(connections)
			playerConnections[player] = nil
		end
		for container, data in pairs(watched) do
			if data.player == player then unwatchContainer(container) end
		end
	end

	local function watchPlayer(player)
		if playerConnections[player] then return end
		local connections = {}
		playerConnections[player] = connections

		table.insert(connections, player.CharacterAdded:Connect(function(character)
			watchContainer(character, player)
		end))
		table.insert(connections, player.CharacterRemoving:Connect(unwatchContainer))
		if player.Character then
			watchContainer(player.Character, player)
		end

		if player == LocalPlayer then
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then watchContainer(backpack, player) end
			table.insert(connections, player.ChildAdded:Connect(function(child)
				if child:IsA("Backpack") then watchContainer(child, player) end
			end))
		end
	end

	function changer.refresh()
		changer.stop()
		if not settings[spec.EnabledKey] then return end
		local current = generation -- taken after the stop: a newer refresh cancels this one
		for _, player in ipairs(Players:GetPlayers()) do
			watchPlayer(player)
		end
		table.insert(globalConnections, Players.PlayerAdded:Connect(watchPlayer))
		table.insert(globalConnections, Players.PlayerRemoving:Connect(removePlayer))

		-- Resolve the chosen files in the background, so the first sound of a weapon that is not in
		-- hand yet already plays the replaced file.
		task.defer(function()
			-- Snapshot first: resolving can yield, and the player may change a dropdown meanwhile.
			local pending = {}
			for _, relative in pairs(overrides) do
				if type(relative) == "string" then table.insert(pending, relative) end
			end
			for _, relative in ipairs(pending) do
				if current ~= generation or not settings[spec.EnabledKey] then return end
				pcall(resolveAsset, relative)
			end
		end)
	end

	function changer.schedule()
		if refreshScheduled then return end
		refreshScheduled = true
		local current = generation
		task.defer(function()
			if current ~= generation then return end
			refreshScheduled = false
			changer.refresh()
		end)
	end

	-- value is what the weapon's dropdown shows: "Default" (the game's own sound) or a file label.
	function changer.set(weapon, value)
		if value == WEAPON_SOUND_DEFAULT then
			overrides[weapon] = nil
		else
			local entry = changer.catalog[weapon]
			local relative = entry and (entry.byLabel[value] or (entry.available[value] and value))
			if not relative then
				CW.Warn("Choose a sound file from the " .. spec.Category .. " library for " .. tostring(weapon))
				return
			end
			overrides[weapon] = relative
		end
		changer.schedule()
	end

	return changer
end

local shootSounds = createSoundChanger({
	Label = "shoot",
	Category = "WeaponSounds",
	SoundName = "ShootSound",
	OverridesKey = "WEAPON_SHOOT_SOUND_OVERRIDES",
	ConfigKey = "WEAPON_SHOOT_SOUNDS",
	EnabledKey = "WEAPON_SOUND_OVERRIDE_ENABLED",
	OthersKey = "WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS",
	VolumeKey = "WEAPON_SOUND_VOLUME",
})

local reloadSounds = createSoundChanger({
	Label = "reload",
	Category = "ReloadSounds",
	SoundName = "ReloadSound",
	OverridesKey = "WEAPON_RELOAD_SOUND_OVERRIDES",
	ConfigKey = "WEAPON_RELOAD_SOUNDS",
	EnabledKey = "WEAPON_RELOAD_SOUND_OVERRIDE_ENABLED",
	OthersKey = "WEAPON_RELOAD_SOUND_OVERRIDE_APPLY_TO_OTHERS",
	VolumeKey = "WEAPON_RELOAD_SOUND_VOLUME",
	-- The game plays OTHER players' taser reload at 0.1 by checking for this exact SoundId. Once the id
	-- is replaced that check no longer matches, so the same level is applied here instead.
	BaseVolume = function(originalId, player)
		if originalId == "rbxassetid://82273261" and player ~= LocalPlayer then return 0.1 end
		return nil
	end,
})

local soundChangers = { shootSounds, reloadSounds }
CW.State.stopWeaponShootSoundOverrides = function()
	for _, changer in ipairs(soundChangers) do changer.stop() end
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
		Callback = function(s) CW.Settings.HITMARKER_RANDOM_ROTATION = s end,
	})

	EffectsTab:Toggle({
		Title = "Follow Mouse",
		Default = CW.Settings.HITMARKER_FOLLOW_MOUSE,
		Callback = function(s) CW.Settings.HITMARKER_FOLLOW_MOUSE = s end,
	})

	EffectsTab:Slider({
		Title = "Visible Duration",
		Min = 0,
		Max = 1,
		Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
		Decimal = 2,
		Suffix = "s",
		Callback = function(v) CW.Settings.HITMARKER_VISIBLE_DURATION = v end,
	})

	EffectsTab:Toggle({
		Title = "Fadeout",
		Default = CW.Settings.HITMARKER_FADEOUT,
		Callback = function(s) CW.Settings.HITMARKER_FADEOUT = s end,
	})

	EffectsTab:Slider({
		Title = "Fadeout Duration",
		Min = 0,
		Max = 1,
		Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
		Decimal = 2,
		Suffix = "s",
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

	-- Only used by the palette dropdown, which is the fallback when the loaded CWUI has no color picker.
	local function colorName(color)
		for name, paletteColor in pairs(tracerPalette) do
			if color == paletteColor then return name end
		end
		return "Violet"
	end

	-- Colors are userdata and can't be serialised: they are saved as hex strings (TRACER_COLOR_HEX,
	-- TRACER_GLOW_COLOR_HEX, ...). Files written by the old palette dropdown stored a palette name
	-- (TRACER_COLOR_NAME): it is still understood, and the next save replaces it with hex.
	local function colorFromHex(hex)
		if type(hex) ~= "string" then return nil end
		local ok, color = pcall(Color3.fromHex, hex)
		if ok and typeof(color) == "Color3" then return color end
		return nil
	end
	for _, entry in ipairs({
		{ "TRACER_COLOR", "TRACER_COLOR_HEX", "TRACER_COLOR_NAME" },
		{ "TRACER_GLOW_COLOR", "TRACER_GLOW_COLOR_HEX", "TRACER_GLOW_COLOR_NAME" },
		{ "TRACER_SNIPER_COLOR", "TRACER_SNIPER_COLOR_HEX" },
		{ "TRACER_TASER_COLOR", "TRACER_TASER_COLOR_HEX" },
	}) do
		local settingKey, hexKey, nameKey = entry[1], entry[2], entry[3]
		CW.Settings[settingKey] = colorFromHex(CW.Settings[hexKey])
			or (nameKey and tracerPalette[CW.Settings[nameKey]])
			or CW.Settings[settingKey]
		-- The saved values are consumed here. If they stayed in CW.Settings, the generic save loop would
		-- write them back even after the player picks another color (or goes back to the default).
		CW.Settings[hexKey] = nil
		if nameKey then CW.Settings[nameKey] = nil end
	end

	local function addTracerColor(section, title, settingKey)
		local picker = section:Colorpicker({
			Title = title,
			Default = CW.Settings[settingKey],
			Callback = function(color)
				CW.Settings[settingKey] = color
			end,
		})
		if picker then return end

		-- No color picker in the loaded CWUI: keep the old palette dropdown.
		section:Dropdown({
			Title = title,
			Options = { "Violet", "Lilac", "Red", "Green", "Cyan", "White" },
			Default = colorName(CW.Settings[settingKey]),
			Callback = function(name)
				CW.Settings[settingKey] = tracerPalette[name]
			end,
		})
	end

	-- Width, lifetime and transparency sliders for the tracer whose settings start with `prefix`.
	local function addTracerSliders(section, prefix, maxLifetime)
		section:Slider({
			Title = "Tracer Width",
			Min = 0.01,
			Max = 0.5,
			Default = CW.Settings[prefix .. "WIDTH"],
			Decimal = 2,
			Callback = function(v) CW.Settings[prefix .. "WIDTH"] = v end,
		})
		section:Slider({
			Title = "Tracer Lifetime",
			Min = 0.01,
			Max = maxLifetime,
			Default = CW.Settings[prefix .. "LIFETIME"],
			Decimal = 2,
			Suffix = "s",
			Callback = function(v) CW.Settings[prefix .. "LIFETIME"] = v end,
		})
		section:Slider({
			Title = "Tracer Transparency",
			Min = 0,
			Max = 1,
			Default = CW.Settings[prefix .. "TRANSPARENCY"],
			Decimal = 2,
			Callback = function(v) CW.Settings[prefix .. "TRANSPARENCY"] = v end,
		})
	end

	EffectsTab:Toggle({
		Title = "Tracers: Apply To Others",
		Default = CW.Settings.TRACER_APPLY_TO_OTHERS,
		Callback = function(s) CW.Settings.TRACER_APPLY_TO_OTHERS = s end,
	})

	--// every gun except the Sniper and the Taser
	local BulletSection = EffectsTab:AddSubSection("Bullet Tracers (all other guns)", true)

	BulletSection:Toggle({
		Title = "Custom Bullet Tracers",
		Default = CW.Settings.CUSTOM_BULLET_TRACERS,
		Callback = function(s) CW.Settings.CUSTOM_BULLET_TRACERS = s end,
	})
	addTracerColor(BulletSection, "Tracer Color", "TRACER_COLOR")
	addTracerColor(BulletSection, "Glow Color", "TRACER_GLOW_COLOR")
	addTracerSliders(BulletSection, "TRACER_", 1)
	BulletSection:Toggle({
		Title = "Tracer Light",
		Default = CW.Settings.TRACER_POINT_LIGHT == true,
		Callback = function(s) CW.Settings.TRACER_POINT_LIGHT = s == true end,
	})

	--// Sniper (M700) and Taser: a tracer of their own each
	local SniperSection = EffectsTab:AddSubSection("Sniper Tracer (M700)", false)
	SniperSection:AddLabel("Off: the game's own tracer (recolored by the Tracer Color above while Custom Bullet Tracers is on).")
	SniperSection:Toggle({
		Title = "Custom Sniper Tracer",
		Default = CW.Settings.TRACER_SNIPER_ENABLED == true,
		Callback = function(s) CW.Settings.TRACER_SNIPER_ENABLED = s == true end,
	})
	addTracerColor(SniperSection, "Sniper Tracer Color", "TRACER_SNIPER_COLOR")
	addTracerSliders(SniperSection, "TRACER_SNIPER_", 5)

	local TaserSection = EffectsTab:AddSubSection("Taser Tracer", false)
	TaserSection:AddLabel("Off: the game's own tracer (recolored by the Tracer Color above while Custom Bullet Tracers is on).")
	TaserSection:Toggle({
		Title = "Custom Taser Tracer",
		Default = CW.Settings.TRACER_TASER_ENABLED == true,
		Callback = function(s) CW.Settings.TRACER_TASER_ENABLED = s == true end,
	})
	addTracerColor(TaserSection, "Taser Tracer Color", "TRACER_TASER_COLOR")
	addTracerSliders(TaserSection, "TRACER_TASER_", 3)
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
-- Sounds tab: one collapsible section per changer (Shoot Sounds, Reload Sounds) plus Hit Sound.
-- The Shoot Sounds controls and their saved settings are the same as before ("Weapon Sounds"),
-- so nothing already saved is lost.
------------------------------------------------------------------------------
guarded("Sounds", function()
	local SoundsTab = Window:AddTab({ Name = "Sounds", Icon = uiIcons.Sounds })
	local ShootSection = wrapSection(SoundsTab:AddSection({ Name = "Shoot Sounds", Open = true }))
	local ReloadSection = wrapSection(SoundsTab:AddSection({ Name = "Reload Sounds", Open = true }))
	local HitSection = wrapSection(SoundsTab:AddSection({ Name = "Hit Sound", Open = true }))

	-- Same controls for every changer: enable, apply to others, volume, and one dropdown per gun.
	local function buildChangerSection(section, changer, label)
		local spec = changer.spec

		section:Toggle({
			Title = "Enable " .. label .. " Sound Overrides",
			Default = CW.Settings[spec.EnabledKey] == true,
			Callback = function(enabled)
				CW.Settings[spec.EnabledKey] = enabled == true
				changer.schedule()
			end,
		})

		section:Toggle({
			Title = "Apply to Other Players Locally",
			Default = CW.Settings[spec.OthersKey] == true,
			Callback = function(enabled)
				CW.Settings[spec.OthersKey] = enabled == true
				changer.schedule()
			end,
		})

		section:Slider({
			Title = label .. " Sound Volume",
			Min = 0,
			Max = 2,
			Default = CW.Settings[spec.VolumeKey],
			Decimal = 2,
			Suffix = "x",
			Callback = function(v)
				CW.Settings[spec.VolumeKey] = v
				changer.updateVolumes()
			end,
		})

		for _, weaponName in ipairs(soundWeaponNames()) do
			local weapon = weaponName
			local entry = changer.catalog[weapon]
			local dropdown = section:Dropdown({
				Title = weapon .. " " .. label .. " Sound",
				Options = entry and entry.options or { WEAPON_SOUND_DEFAULT },
				Default = changer.label(weapon, changer.overrides[weapon]),
				Callback = function(value)
					changer.set(weapon, value)
				end,
			})
			table.insert(changer.dropdowns, { weapon = weapon, control = dropdown })
		end
	end

	buildChangerSection(ShootSection, shootSounds, "Shoot")
	buildChangerSection(ReloadSection, reloadSounds, "Reload")

	HitSoundDropdown = HitSection:Dropdown({
		Title = "Hit Sound",
		Options = hitSoundOptions,
		Default = hitSoundLabel(CW.Paths.SOUND_FILE),
		Callback = applySoundFile,
	})

	HitSection:Slider({
		Title = "Hit Sound Volume",
		Min = 0,
		Max = 2,
		Default = CW.Settings.SOUND_VOLUME,
		Decimal = 2,
		Suffix = "x",
		Callback = function(v) CW.Settings.SOUND_VOLUME = v end,
	})
end)

------------------------------------------------------------------------------
-- Utilities tab
------------------------------------------------------------------------------
guarded("Utilities", function()
	local UtilityTab = Window:Tab({ Title = "Utilities" })

	local StarterGui = game:GetService("StarterGui")
	local ContextActionService = game:GetService("ContextActionService")
	-- Kept in CW.State so a re-run still knows that the chat was hidden with Z.
	local chatHidden = CW.State.chatHidden == true
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
		-- Always sunk: the game reads RightShift as sprint, and opening the menu must not make
		-- the character run.
		return Enum.ContextActionResult.Sink
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
		Callback = function(enabled)
			CW.Settings.SHIFT_TOGGLE_ENABLED = enabled == true
			if not CW.Settings.SHIFT_TOGGLE_ENABLED then
				allowSprintRelease = sprinting or allowSprintRelease
				sprinting = false
			end
		end,
	})

	-- The chat is no longer forced on at load: it is only touched by the Z toggle below.
	local function setChatVisible(visible)
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, visible)
		end)
		pcall(function()
			StarterGui:SetCore("ChatActive", visible)
		end)
	end

	if CW.State.chatToggleConn then
		CW.State.chatToggleConn:Disconnect()
	end
	CW.State.chatToggleConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not CW.Settings.CHAT_TOGGLE_ENABLED then return end
		if input.KeyCode ~= Enum.KeyCode.Z then return end

		chatHidden = not chatHidden
		CW.State.chatHidden = chatHidden
		setChatVisible(not chatHidden)
	end)

	UtilityTab:Toggle({
		Title = "Toggle Chat with Z",
		Default = CW.Settings.CHAT_TOGGLE_ENABLED == true,
		Callback = function(enabled)
			CW.Settings.CHAT_TOGGLE_ENABLED = enabled == true
			if not CW.Settings.CHAT_TOGGLE_ENABLED then
				chatHidden = false
				CW.State.chatHidden = false
				setChatVisible(true)
			end
		end,
	})

	-- Auto reload (off by default).
	-- It reads the equipped gun's own attributes instead of the ammo text on screen: the game keeps
	-- Local_CurrentAmmo (the client's count) and Local_ReloadSession (0 when idle, a timestamp while
	-- reloading) on the tool, and the sniper's text ("1 | 14") is not a plain "x/y" anyway.
	local VirtualInputManager
	pcall(function()
		VirtualInputManager = game:GetService("VirtualInputManager")
	end)
	local autoReloadWarned = false

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

	if CW.Settings.AUTO_RELOAD_ENABLED == nil then
		CW.Settings.AUTO_RELOAD_ENABLED = _cfg.AUTO_RELOAD_ENABLED == true
	end

	-- True when the gun is empty, not already reloading, and the game would accept a reload
	-- (the sniper cannot reload without stored ammo).
	local function needsReload(tool)
		if not CW.Settings.AUTO_RELOAD_ENABLED then return false end
		if tool:GetAttribute("Local_CurrentAmmo") ~= 0 then return false end
		if tool:GetAttribute("Local_ReloadSession") ~= 0 then return false end
		if tool:GetAttribute("Behavior") == "Sniper" and (tool:GetAttribute("StoredAmmo") or 0) <= 0 then return false end
		return true
	end

	local reloading = setmetatable({}, { __mode = "k" })
	local function autoReload(tool)
		if reloading[tool] then return end
		reloading[tool] = true
		task.spawn(function()
			-- At most two presses; the second only if the first did not start a reload.
			for _ = 1, 2 do
				if not needsReload(tool) or tool.Parent ~= LocalPlayer.Character then break end
				if UserInputService:GetFocusedTextBox() or UserInputService:IsKeyDown(Enum.KeyCode.R) then break end
				pressReloadKey()
				task.wait(0.15)
				if tool:GetAttribute("Local_ReloadSession") ~= 0 then break end
			end
			reloading[tool] = nil
		end)
	end

	local function watchTool(tool)
		if not tool:IsA("Tool") or tool:GetAttribute("ToolType") ~= "Gun" then return end
		CW.track("autoReloadTool", tool:GetAttributeChangedSignal("Local_CurrentAmmo"):Connect(function()
			if needsReload(tool) then autoReload(tool) end
		end))
		if needsReload(tool) then autoReload(tool) end
	end

	local function watchCharacter(character)
		CW.track("autoReloadAdded", character.ChildAdded:Connect(watchTool))
		CW.track("autoReloadRemoved", character.ChildRemoved:Connect(function(child)
			if child:IsA("Tool") then CW.untrack("autoReloadTool") end
		end))
		for _, child in ipairs(character:GetChildren()) do watchTool(child) end
	end

	local function setAutoReload(enabled)
		if enabled then
			CW.track("autoReloadCharacter", LocalPlayer.CharacterAdded:Connect(watchCharacter))
			if LocalPlayer.Character then watchCharacter(LocalPlayer.Character) end
		else
			for _, key in ipairs({ "autoReloadCharacter", "autoReloadAdded", "autoReloadRemoved", "autoReloadTool" }) do
				CW.untrack(key)
			end
		end
	end

	UtilityTab:Toggle({
		Title = "Auto Reload at 0 Ammo",
		Default = CW.Settings.AUTO_RELOAD_ENABLED == true,
		Callback = function(enabled)
			CW.Settings.AUTO_RELOAD_ENABLED = enabled == true
			setAutoReload(CW.Settings.AUTO_RELOAD_ENABLED)
		end,
	})

	setAutoReload(CW.Settings.AUTO_RELOAD_ENABLED == true)
end)

------------------------------------------------------------------------------
-- Library <-> UI refresh
------------------------------------------------------------------------------
-- Rebuilds every library-backed control from disk. Core assets are reloaded separately
-- by CW.reloadCoreAssets (so this never touches the cursor/texture pipeline).
-- The gallery drops its own asset cache entries on every rebuild, so no extra cache clear is needed.
local function refreshUIFromLibrary()
	hitSoundOptions = refreshHitSoundCatalog()
	for _, changer in ipairs(soundChangers) do changer.refreshCatalog() end

	local function syncGallery(gallery, category, weapon, selectedFile)
		if not gallery then return end
		gallery:SetItems(galleryItems(category, weapon))
		-- SetItems already restores the previous selection. Calling Set on an entry that is
		-- already selected would DESELECT it in galleries that allow deselecting (the weapon
		-- texture galleries), so Set is only used when the selection really has to change.
		local current = gallery:Get()
		if selectedFile then
			if not (current and current.Path == selectedFile) then gallery:Set(selectedFile, true) end
		elseif current then
			gallery:Clear()
		end
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
	for _, changer in ipairs(soundChangers) do
		for _, entry in ipairs(changer.dropdowns) do
			local catalog = changer.catalog[entry.weapon]
			entry.control:Refresh(catalog and catalog.options or { WEAPON_SOUND_DEFAULT })
			entry.control:Set(changer.label(entry.weapon, changer.overrides[entry.weapon]), true)
		end
		changer.refresh()
	end
end

------------------------------------------------------------------------------
-- Settings tab (created last so it is also the last tab)
------------------------------------------------------------------------------
guarded("Settings", function()
	local SettingsTab = createCompatTab({ Title = "Settings" })

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

	-- A setting is saved only when the player changed it: its value differs from the default.
	-- Switching a setting back to its default removes it from the file.
	local function isDefaultValue(key, value)
		if type(value) == "table" then return next(value) == nil end
		local default = CW.Defaults[key]
		if default == nil and type(value) == "boolean" then default = false end
		if type(value) == "number" and type(default) == "number" then return math.abs(value - default) < 1e-6 end
		return value == default
	end

	local function saveSettings()
		local savedSettings = {}
		for key, value in pairs(CW.Settings) do
			if key ~= "ASSET_SELECTIONS" and key ~= "SOUND_ID" and key ~= "AUTO_RELOAD_LABEL_PATH" then
				local serialized = serializableValue(value)
				if serialized ~= nil and not isDefaultValue(key, serialized) then
					savedSettings[key] = serialized
				end
			end
		end

		-- Tracer colors are Color3 (not serialisable): store them as hex, only when different from the default.
		local function saveColor(settingKey, hexKey)
			local color, default = CW.Settings[settingKey], CW.Defaults[settingKey]
			if typeof(color) == "Color3" and (typeof(default) ~= "Color3" or color:ToHex() ~= default:ToHex()) then
				savedSettings[hexKey] = color:ToHex()
			end
		end
		saveColor("TRACER_COLOR", "TRACER_COLOR_HEX")
		saveColor("TRACER_GLOW_COLOR", "TRACER_GLOW_COLOR_HEX")
		saveColor("TRACER_SNIPER_COLOR", "TRACER_SNIPER_COLOR_HEX")
		saveColor("TRACER_TASER_COLOR", "TRACER_TASER_COLOR_HEX")

		local out = {
			schemaVersion = 3,
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
		Callback = function()
			saveSettings()
			CW.Log("Settings saved.")
		end,
	})
end)

local soundsMigrated = false
for _, changer in ipairs(soundChangers) do
	changer.schedule()
	if changer.migrated then soundsMigrated = true end
end
if soundsMigrated then scheduleSave() end -- write the cleaned-up overrides so the warning shows only once
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
