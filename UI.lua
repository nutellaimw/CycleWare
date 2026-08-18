local CW = getgenv().__CW_CORE_STATE
assert(CW, "CycleWare must be loaded before UI.lua")

local HttpService = game:GetService("HttpService")

local Elastic = loadstring(game:HttpGet(
	"https://raw.githubusercontent.com/53845052/roblox-uis/refs/heads/main/ElasticLib.lua"
))()

local Icons = {
	Combat    = "rbxassetid://10734950020",
	Visuals   = "rbxassetid://10709790948",
	Weapons   = "rbxassetid://10734924318",
	Sounds    = "rbxassetid://10734896206",
	Tracers   = "rbxassetid://121226081123510",
}

Elastic:SetWindowKeybind(Enum.KeyCode.RightShift)

local Window = Elastic:Window()

local Watermark = Window:Watermark("CycleWare")
Watermark:SetPosition("TopLeft")
Watermark:SetVisible(true)

local CombatTab = Window:Tab({ Title = "Hitmarker", Icon = Icons.Combat })

CombatTab:Textbox({
	Title       = "Hitmarker File",
	Placeholder = CW.Paths.HITMARKER_FILE,
	Flag        = "Hitmarker_FilePath",
	Callback    = function(value)
		if value ~= "" then CW.Paths.HITMARKER_FILE = value end
	end,
})

CombatTab:Slider({
	Title = "Hitmarker Size", Min = 8, Max = 200, Default = CW.Settings.HITMARKER_SIZE,
	Suffix = "px", Flag = "Hitmarker_Size",
	Callback = function(v)
		CW.Settings.HITMARKER_SIZE = v
		if CW.HMTemplate then CW.HMTemplate.Size = UDim2.new(0, v, 0, v) end
	end,
})

CombatTab:Toggle({
	Title = "Random Rotation", Default = CW.Settings.HITMARKER_RANDOM_ROTATION,
	Flag = "Hitmarker_RandomRotation",
	Callback = function(s) CW.Settings.HITMARKER_RANDOM_ROTATION = s end,
})

CombatTab:Toggle({
	Title = "Follow Mouse", Default = CW.Settings.HITMARKER_FOLLOW_MOUSE,
	Flag = "Hitmarker_FollowMouse",
	Callback = function(s) CW.Settings.HITMARKER_FOLLOW_MOUSE = s end,
})

CombatTab:Slider({
	Title = "Visible Duration", Min = 0, Max = 1, Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
	Decimal = 2, Suffix = "s", Flag = "Hitmarker_VisibleDuration",
	Callback = function(v) CW.Settings.HITMARKER_VISIBLE_DURATION = v end,
})

CombatTab:Toggle({
	Title = "Fadeout", Default = CW.Settings.HITMARKER_FADEOUT,
	Flag = "Hitmarker_Fadeout",
	Callback = function(s) CW.Settings.HITMARKER_FADEOUT = s end,
})

CombatTab:Slider({
	Title = "Fadeout Duration", Min = 0, Max = 1, Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
	Decimal = 2, Suffix = "s", Flag = "Hitmarker_FadeoutDuration",
	Callback = function(v) CW.Settings.HITMARKER_FADEOUT_DURATION = v end,
})

CombatTab:Button({
	Title = "Reload Hitmarker", Action = "Reload",
	Callback = function()
		if CW.reloadHitmarkerAsset then CW.reloadHitmarkerAsset() end
		Elastic:Notify({ Title = "CycleWare", Content = "Hitmarker reloaded.", Duration = 3 })
	end,
})

local VisualsTab = Window:Tab({ Title = "Cursor", Icon = Icons.Visuals })

VisualsTab:Textbox({
	Title       = "Cursor File",
	Placeholder = CW.Paths.CURSOR_FILE,
	Flag        = "Cursor_FilePath",
	Callback    = function(value)
		if value ~= "" then CW.Paths.CURSOR_FILE = value end
	end,
})

VisualsTab:Slider({
	Title = "Cursor Size", Min = 16, Max = 256, Default = CW.Settings.CURSOR_TARGET_SIZE,
	Suffix = "px", Flag = "Cursor_Size",
	Callback = function(v)
		CW.Settings.CURSOR_TARGET_SIZE = v
		if CW.reloadCursor then CW.reloadCursor() end
	end,
})

VisualsTab:Button({
	Title = "Reload Cursor", Action = "Reload",
	Callback = function()
		if CW.reloadCursor then CW.reloadCursor() end
		Elastic:Notify({ Title = "CycleWare", Content = "Cursor reloaded.", Duration = 3 })
	end,
})

local WeaponsTab = Window:Tab({ Title = "Weapon Textures", Icon = Icons.Weapons })

WeaponsTab:Textbox({
	Title       = "Texture File",
	Placeholder = CW.Paths.TEXTURE_FILE,
	Flag        = "Texture_FilePath",
	Callback    = function(value)
		if value ~= "" then CW.Paths.TEXTURE_FILE = value end
	end,
})

WeaponsTab:Button({
	Title = "Reload Textures", Action = "Reload",
	Callback = function()
		if CW.reloadTextures then CW.reloadTextures() end
		Elastic:Notify({ Title = "CycleWare", Content = "Textures reloaded and reapplied.", Duration = 3 })
	end,
})

local SoundsTab = Window:Tab({ Title = "Gun Sounds", Icon = Icons.Sounds })

SoundsTab:Textbox({
	Title       = "Hit Sound File",
	Placeholder = CW.Paths.SOUND_FILE,
	Flag        = "Sound_FilePath",
	Callback    = function(value)
		if value ~= "" then CW.Paths.SOUND_FILE = value end
	end,
})

SoundsTab:Slider({
	Title = "Hit Sound Volume", Min = 0, Max = 2, Default = CW.Settings.SOUND_VOLUME,
	Decimal = 2, Suffix = "x", Flag = "Sound_Volume",
	Callback = function(v) CW.Settings.SOUND_VOLUME = v end,
})

SoundsTab:Button({
	Title = "Reload Sound", Action = "Reload",
	Callback = function()
		if CW.reloadSoundAsset then CW.reloadSoundAsset() end
		Elastic:Notify({ Title = "CycleWare", Content = "Hit sound reloaded.", Duration = 3 })
	end,
})

local TracersTab = Window:Tab({ Title = "Bullet Tracers", Icon = Icons.Tracers })

TracersTab:Toggle({
	Title = "Custom Bullet Tracers", Default = CW.Settings.CUSTOM_BULLET_TRACERS,
	Flag = "Tracer_Enabled",
	Callback = function(s) CW.Settings.CUSTOM_BULLET_TRACERS = s end,
}):Colorpicker({
	Default  = CW.Settings.TRACER_COLOR,
	Flag     = "Tracer_Color",
	Callback = function(color) CW.Settings.TRACER_COLOR = color end,
})

TracersTab:Colorpicker({
	Title = "Glow Color", Default = CW.Settings.TRACER_GLOW_COLOR, Flag = "Tracer_GlowColor",
	Callback = function(color) CW.Settings.TRACER_GLOW_COLOR = color end,
})

TracersTab:Slider({
	Title = "Tracer Width", Min = 0.01, Max = 0.5, Default = CW.Settings.TRACER_WIDTH,
	Decimal = 2, Flag = "Tracer_Width",
	Callback = function(v) CW.Settings.TRACER_WIDTH = v end,
})

TracersTab:Slider({
	Title = "Tracer Lifetime", Min = 0.01, Max = 1, Default = CW.Settings.TRACER_LIFETIME,
	Decimal = 2, Suffix = "s", Flag = "Tracer_Lifetime",
	Callback = function(v) CW.Settings.TRACER_LIFETIME = v end,
})

TracersTab:Toggle({
	Title = "Apply To Others", Default = CW.Settings.TRACER_APPLY_TO_OTHERS,
	Flag = "Tracer_ApplyToOthers",
	Callback = function(s) CW.Settings.TRACER_APPLY_TO_OTHERS = s end,
})

local SettingsTab = Window.ConfigTab

SettingsTab:Toggle({
	Title = "Show Watermark", Default = true, Flag = "Config_Watermark",
	Callback = function(s) Watermark:SetVisible(s) end,
})

do
	local Theme = Elastic:GetTheme()
	SettingsTab:Colorpicker({
		Title = "Accent Color", Default = Theme.Accent, Flag = "Config_ThemeAccent",
		Callback = function(color)
			local currentTheme = Elastic:GetTheme()
			currentTheme.Accent = color
			Elastic:SetTheme(currentTheme)
		end,
	})
end

local CONFIG_FILE = CW.Paths.CACHE_FOLDER.."/ui_config.json"

local function serializeValue(componentType, value, component)
	if componentType == "Keybind" then
		if typeof(value) == "EnumItem" then
			return { EnumType = tostring(value.EnumType), Name = value.Name }
		end
		return tostring(value)
	elseif componentType == "Colorpicker" then
		return {
			R = value.R, G = value.G, B = value.B,
			Transparency = component.GetTransparency and component:GetTransparency() or 0,
		}
	else
		return value
	end
end

local function deserializeValue(componentType, saved)
	if componentType == "Keybind" then
		if type(saved) == "table" and saved.EnumType and saved.Name then
			local enumType = Enum[saved.EnumType:match("Enum%.(.+)") or saved.EnumType]
			if enumType then
				local ok, item = pcall(function() return enumType[saved.Name] end)
				if ok then return item end
			end
		end
		return nil
	elseif componentType == "Colorpicker" then
		return Color3.new(saved.R, saved.G, saved.B), saved.Transparency
	else
		return saved
	end
end

SettingsTab:Button({
	Title = "Save Config", Action = "Save",
	Callback = function()
		local out = {}
		for flag, component in pairs(Elastic.Flags) do
			if not flag:find("^Config_") then
				local ok, componentType = pcall(function() return component:GetComponentType() end)
				if ok and componentType then
					local ok2, value = pcall(function() return component:GetValue() end)
					if ok2 then
						out[flag] = { componentType, serializeValue(componentType, value, component) }
					end
				end
			end
		end

		local ok, encoded = pcall(HttpService.JSONEncode, HttpService, out)
		if ok then
			writefile(CONFIG_FILE, encoded)
			Elastic:Notify({ Title = "CycleWare", Content = "Configuration saved.", Duration = 3 })
		else
			Elastic:Notify({ Title = "CycleWare", Content = "Failed to save configuration.", Duration = 3 })
		end
	end,
})

SettingsTab:Button({
	Title = "Load Config", Action = "Load",
	Callback = function()
		if not isfile(CONFIG_FILE) then
			Elastic:Notify({ Title = "CycleWare", Content = "No saved configuration found.", Duration = 3 })
			return
		end

		local ok, raw = pcall(readfile, CONFIG_FILE)
		if not ok then
			Elastic:Notify({ Title = "CycleWare", Content = "Failed to read configuration.", Duration = 3 })
			return
		end

		local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)
		if not ok2 or type(data) ~= "table" then
			Elastic:Notify({ Title = "CycleWare", Content = "Configuration file is corrupted.", Duration = 3 })
			return
		end

		for flag, entry in pairs(data) do
			local component = Elastic.Flags[flag]
			if component and type(entry) == "table" and entry[1] then
				local componentType, saved = entry[1], entry[2]
				if componentType == "Colorpicker" then
					local color, transparency = deserializeValue(componentType, saved)
					if color then
						component:SetValue(color)
						if transparency and component.SetTransparency then
							component:SetTransparency(transparency)
						end
					end
				else
					local value = deserializeValue(componentType, saved)
					if value ~= nil then
						component:SetValue(value)
					end
				end
			end
		end

		Elastic:Notify({ Title = "CycleWare", Content = "Configuration loaded.", Duration = 3 })
	end,
})

print("[CW] UI loaded.")
