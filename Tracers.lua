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
