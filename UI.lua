local CW = getgenv().__CW_CORE_STATE
assert(CW, "CycleWare must be loaded before UI.lua")

local Elastic = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/53845052/roblox-uis/refs/heads/main/ElasticLib.lua"
))()

Elastic:SetWindowKeybind(Enum.KeyCode.RightShift)
local Window = Elastic:Window()
local Watermark = Window:Watermark("CycleWare")

local CursorTab = Window:Tab({ Title = "Cursor", Icon = "rbxassetid://11295279987" })

CursorTab:Slider({
	Title = "Cursor Size", Min = 16, Max = 256, Default = CW.Settings.CURSOR_TARGET_SIZE,
	Suffix = "px", Flag = "CursorSize",
	Callback = function(v)
		CW.Settings.CURSOR_TARGET_SIZE = v
		if CW.reloadCursor then CW.reloadCursor() end
	end,
})

CursorTab:Button({
	Title = "Reload cursor.png", Action = "Reload",
	Callback = function()
		if CW.reloadCursor then CW.reloadCursor() end
		Elastic:Notify({ Title = "CycleWare", Content = "Cursor reloaded.", Duration = 3 })
	end,
})

local HitmarkerTab = Window:Tab({ Title = "Hitmarker", Icon = "rbxassetid://11295279987" })

HitmarkerTab:Slider({
	Title = "Size", Min = 8, Max = 200, Default = CW.Settings.HITMARKER_SIZE,
	Suffix = "px", Flag = "HitmarkerSize",
	Callback = function(v)
		CW.Settings.HITMARKER_SIZE = v
		if CW.HMTemplate then CW.HMTemplate.Size = UDim2.new(0, v, 0, v) end
	end,
})

HitmarkerTab:Toggle({
	Title = "Random Rotation", Default = CW.Settings.HITMARKER_RANDOM_ROTATION, Flag = "HMRotation",
	Callback = function(s) CW.Settings.HITMARKER_RANDOM_ROTATION = s end,
})

HitmarkerTab:Toggle({
	Title = "Follow Mouse", Default = CW.Settings.HITMARKER_FOLLOW_MOUSE, Flag = "HMFollow",
	Callback = function(s) CW.Settings.HITMARKER_FOLLOW_MOUSE = s end,
})

HitmarkerTab:Slider({
	Title = "Visible Duration", Min = 0, Max = 1, Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
	Decimal = 2, Suffix = "s", Flag = "HMVisibleDur",
	Callback = function(v) CW.Settings.HITMARKER_VISIBLE_DURATION = v end,
})

HitmarkerTab:Toggle({
	Title = "Fadeout", Default = CW.Settings.HITMARKER_FADEOUT, Flag = "HMFadeout",
	Callback = function(s) CW.Settings.HITMARKER_FADEOUT = s end,
})

HitmarkerTab:Slider({
	Title = "Fadeout Duration", Min = 0, Max = 1, Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
	Decimal = 2, Suffix = "s", Flag = "HMFadeDur",
	Callback = function(v) CW.Settings.HITMARKER_FADEOUT_DURATION = v end,
})

HitmarkerTab:Button({
	Title = "Reload hitmarker.png", Action = "Reload",
	Callback = function()
		if CW.reloadHitmarkerAsset then CW.reloadHitmarkerAsset() end
		Elastic:Notify({ Title = "CycleWare", Content = "Hitmarker reloaded.", Duration = 3 })
	end,
})

local SoundTab = Window:Tab({ Title = "Sound", Icon = "rbxassetid://11295279987" })

SoundTab:Slider({
	Title = "Hit Sound Volume", Min = 0, Max = 2, Default = CW.Settings.SOUND_VOLUME,
	Decimal = 2, Suffix = "x", Flag = "SoundVolume",
	Callback = function(v) CW.Settings.SOUND_VOLUME = v end,
})

SoundTab:Button({
	Title = "Reload sound.mp3", Action = "Reload",
	Callback = function()
		if CW.reloadSoundAsset then CW.reloadSoundAsset() end
		Elastic:Notify({ Title = "CycleWare", Content = "Sound reloaded.", Duration = 3 })
	end,
})

local TracersTab = Window:Tab({ Title = "Tracers", Icon = "rbxassetid://11295279987" })

TracersTab:Toggle({
	Title = "Custom Tracers", Default = CW.Settings.CUSTOM_BULLET_TRACERS, Flag = "CustomTracers",
	Callback = function(s) CW.Settings.CUSTOM_BULLET_TRACERS = s end,
}):Colorpicker({
	Default = CW.Settings.TRACER_COLOR,
	Callback = function(color) CW.Settings.TRACER_COLOR = color end,
})

TracersTab:Colorpicker({
	Title = "Glow Color", Default = CW.Settings.TRACER_GLOW_COLOR, Flag = "TracerGlow",
	Callback = function(color) CW.Settings.TRACER_GLOW_COLOR = color end,
})

TracersTab:Slider({
	Title = "Tracer Width", Min = 0.01, Max = 0.5, Default = CW.Settings.TRACER_WIDTH,
	Decimal = 2, Flag = "TracerWidth",
	Callback = function(v) CW.Settings.TRACER_WIDTH = v end,
})

TracersTab:Slider({
	Title = "Tracer Lifetime", Min = 0.01, Max = 1, Default = CW.Settings.TRACER_LIFETIME,
	Decimal = 2, Suffix = "s", Flag = "TracerLifetime",
	Callback = function(v) CW.Settings.TRACER_LIFETIME = v end,
})

TracersTab:Toggle({
	Title = "Apply To Others", Default = CW.Settings.TRACER_APPLY_TO_OTHERS, Flag = "TracerOthers",
	Callback = function(s) CW.Settings.TRACER_APPLY_TO_OTHERS = s end,
})

local TextureTab = Window:Tab({ Title = "Weapon Skin", Icon = "rbxassetid://11295279987" })

TextureTab:Button({
	Title = "Reload textures (texture.png / texture_<gun>.png)", Action = "Reload",
	Callback = function()
		if CW.reloadTextures then CW.reloadTextures() end
		Elastic:Notify({ Title = "CycleWare", Content = "Textures reloaded and reapplied.", Duration = 3 })
	end,
})

local ConfigTab = Window.ConfigTab
ConfigTab:Toggle({ Title = "Watermark", Default = true, Callback = function(s) Watermark:SetVisible(s) end })

print("[CW] UI loaded.")
