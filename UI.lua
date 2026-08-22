local CW = getgenv().__CW_CORE_STATE
assert(CW, "CycleWare must be loaded before UI.lua")

local HttpService = game:GetService("HttpService")

local Elastic = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/53845052/roblox-uis/refs/heads/main/ElasticLib.lua"
))()

local Icons = {
	Combat  = "rbxassetid://10734950020",
	Visuals = "rbxassetid://10709790948",
	Weapons = "rbxassetid://10734924318",
	Sounds  = "rbxassetid://10734896206",
	Tracers = "rbxassetid://94654949230438",
}

Elastic:SetWindowKeybind(Enum.KeyCode.RightShift)

local Window = Elastic:Window()


local CombatTab = Window:Tab({
	Title = "Hitmarker",
	Icon = Icons.Combat
})

local function applyHitmarkerFile(value)
	if value and value ~= "" then
		CW.Paths.HITMARKER_FILE = value
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

CombatTab:Textbox({
	Title = "Hitmarker File",
	Placeholder = CW.Paths.HITMARKER_FILE,
	Flag = "Hitmarker_FilePath",
	Callback = applyHitmarkerFile,
})

CombatTab:Slider({
	Title = "Hitmarker Size",
	Min = 8,
	Max = 200,
	Default = CW.Settings.HITMARKER_SIZE,
	Suffix = "px",
	Flag = "Hitmarker_Size",
	Callback = applyHitmarkerSize,
})

CombatTab:Toggle({
	Title = "Random Rotation",
	Default = CW.Settings.HITMARKER_RANDOM_ROTATION,
	Flag = "Hitmarker_RandomRotation",
	Callback = applyHitmarkerRandomRotation,
})

CombatTab:Toggle({
	Title = "Follow Mouse",
	Default = CW.Settings.HITMARKER_FOLLOW_MOUSE,
	Flag = "Hitmarker_FollowMouse",
	Callback = applyHitmarkerFollowMouse,
})

CombatTab:Slider({
	Title = "Visible Duration",
	Min = 0,
	Max = 1,
	Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
	Decimal = 2,
	Suffix = "s",
	Flag = "Hitmarker_VisibleDuration",
	Callback = applyHitmarkerVisibleDuration,
})

CombatTab:Toggle({
	Title = "Fadeout",
	Default = CW.Settings.HITMARKER_FADEOUT,
	Flag = "Hitmarker_Fadeout",
	Callback = applyHitmarkerFadeout,
})

CombatTab:Slider({
	Title = "Fadeout Duration",
	Min = 0,
	Max = 1,
	Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
	Decimal = 2,
	Suffix = "s",
	Flag = "Hitmarker_FadeoutDuration",
	Callback = applyHitmarkerFadeoutDuration,
})

CombatTab:Button({
	Title = "Reload Hitmarker",
	Action = "Reload",
	Callback = function()
		if CW.reloadHitmarkerAsset then
			CW.reloadHitmarkerAsset()
		end

		
	end,
})

local VisualsTab = Window:Tab({
	Title = "Cursor",
	Icon = Icons.Visuals
})

local function applyCursorFile(value)
	if value and value ~= "" then
		CW.Paths.CURSOR_FILE = value
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
	Placeholder = CW.Paths.CURSOR_FILE,
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

VisualsTab:Button({
	Title = "Reload Cursor",
	Action = "Reload",
	Callback = function()
		if CW.reloadCursor then
			CW.reloadCursor()
		end

		
	end,
})

local WeaponsTab = Window:Tab({
	Title = "Weapon Textures",
	Icon = Icons.Weapons
})

local function applyTextureFile(value)
	if value and value ~= "" then
		CW.Paths.TEXTURE_FILE = value
	end
end

WeaponsTab:Textbox({
	Title = "Texture File",
	Placeholder = CW.Paths.TEXTURE_FILE,
	Flag = "Texture_FilePath",
	Callback = applyTextureFile,
})

WeaponsTab:Button({
	Title = "Reload Textures",
	Action = "Reload",
	Callback = function()
		if CW.reloadTextures then
			CW.reloadTextures()
		end

		
	end,
})

local SoundsTab = Window:Tab({
	Title = "Gun Sounds",
	Icon = Icons.Sounds
})

local function applySoundFile(value)
	if value and value ~= "" then
		CW.Paths.SOUND_FILE = value
	end
end

local function applySoundVolume(v)
	CW.Settings.SOUND_VOLUME = v
end

SoundsTab:Textbox({
	Title = "Hit Sound File",
	Placeholder = CW.Paths.SOUND_FILE,
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

SoundsTab:Button({
	Title = "Reload Sound",
	Action = "Reload",
	Callback = function()
		if CW.reloadSoundAsset then
			CW.reloadSoundAsset()
		end

		
	end,
})

local TracersTab = Window:Tab({
	Title = "Bullet Tracers",
	Icon = Icons.Tracers
})

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

local ApplyFunctions = {
	Hitmarker_FilePath        = applyHitmarkerFile,
	Hitmarker_Size            = applyHitmarkerSize,
	Hitmarker_RandomRotation  = applyHitmarkerRandomRotation,
	Hitmarker_FollowMouse     = applyHitmarkerFollowMouse,
	Hitmarker_VisibleDuration = applyHitmarkerVisibleDuration,
	Hitmarker_Fadeout         = applyHitmarkerFadeout,
	Hitmarker_FadeoutDuration = applyHitmarkerFadeoutDuration,

	Cursor_FilePath = applyCursorFile,
	Cursor_Size     = function(v) applyCursorSize(v, true) end,

	Texture_FilePath = applyTextureFile,

	Sound_FilePath = applySoundFile,
	Sound_Volume   = applySoundVolume,

	Tracer_Enabled       = applyTracerEnabled,
	Tracer_Color         = applyTracerColor,
	Tracer_GlowColor     = applyTracerGlowColor,
	Tracer_Width         = applyTracerWidth,
	Tracer_Lifetime      = applyTracerLifetime,
	Tracer_ApplyToOthers = applyTracerApplyToOthers,
}

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

	local touchedPaths = {}

	for flag, entry in pairs(data) do
		local component = Elastic.Flags[flag]

		if component and type(entry) == "table" and entry[1] then
			local componentType, saved = entry[1], entry[2]

			local ok3, currentType = pcall(function()
				return component:GetComponentType()
			end)

			if ok3 and currentType == componentType then
				local applyFn = ApplyFunctions[flag]
				local restored = false

				local ok4 = pcall(function()
					if componentType == "Colorpicker" then
						local color, transparency = deserializeValue(componentType, saved)
						if color then
							component:SetValue(color)
							if transparency ~= nil and component.SetTransparency then
								component:SetTransparency(transparency)
							end
							if applyFn then applyFn(color) end
							restored = true
						end
					else
						local value = deserializeValue(componentType, saved)
						if value ~= nil then
							component:SetValue(value)
							if applyFn then applyFn(value) end
							restored = true
						end
					end
				end)

				if ok4 and restored and flag:find("_FilePath$") then
					touchedPaths[flag] = true
				end
			end
		end
	end

	if touchedPaths.Cursor_FilePath and CW.reloadCursor then CW.reloadCursor() end
	if touchedPaths.Hitmarker_FilePath and CW.reloadHitmarkerAsset then CW.reloadHitmarkerAsset() end
	if touchedPaths.Sound_FilePath and CW.reloadSoundAsset then CW.reloadSoundAsset() end
	if touchedPaths.Texture_FilePath and CW.reloadTextures then CW.reloadTextures() end
end

SettingsTab:Button({
	Title = "Save Settings",
	Action = "Save",
	Callback = function()
		saveSettings()
	end,
})

loadSettings()

print("[CW] UI loaded.")
