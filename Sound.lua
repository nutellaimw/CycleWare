local CW = getgenv().__CW_CORE_STATE

CW.reloadSoundAsset = reloadSound
reloadSound()

local SoundService = game:GetService("SoundService")
local Debris       = game:GetService("Debris")

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
