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
