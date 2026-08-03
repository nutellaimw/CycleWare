local REPO_BASE = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/"

local function loadModule(path)
	local src = game:HttpGet(REPO_BASE .. path)
	local fn  = loadstring(src)
	if not fn then
		warn("[CW] Failed to compile module: " .. path)
		return
	end
	local ok, err = pcall(fn)
	if not ok then
		warn("[CW] Error running module " .. path .. ": " .. tostring(err))
	end
end

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
	if CW.Debug then print("[CW] " .. msg) end
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
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then return end
		local inset = GuiService:GetGuiInset()
		CW.State.mouseX = input.Position.X + inset.X
		CW.State.mouseY = input.Position.Y + inset.Y

		for clone in pairs(CW.ActiveFollowClones) do
			local ok = pcall(function()
				clone.Position = UDim2.fromOffset(CW.State.mouseX, CW.State.mouseY)
			end)
			if not ok then CW.ActiveFollowClones[clone] = nil end
		end
	end)
end

loadModule("Cache.lua")
loadModule("PNG.lua")
loadModule("Cursor.lua")
loadModule("Hitmarker.lua")
loadModule("Sound.lua")
loadModule("Texture.lua")
loadModule("Tracers.lua")
loadModule("Hook.lua")
loadModule("Cleanup.lua")
