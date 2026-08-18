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
		CW.Warn("No valid cursor image found at "..CW.Paths.CURSOR_FILE.." — place a PNG there and re-run.")
		return false
	end
	local ok2, px, w, h = pcall(CW.parsePNG, data)
	if not ok2 then
		CW.Warn("parsePNG failed: "..tostring(px))
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

local function generateCursors()
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
