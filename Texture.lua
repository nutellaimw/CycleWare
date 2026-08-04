local CW = getgenv().__CW_CORE_STATE

local Players     = game:GetService("Players")
local LocalPlayer = CW.LocalPlayer

local _cfg = getgenv().CW_CONFIG or {}

CW.Paths.TEXTURE_FILE         = _cfg.TEXTURE_FILE or "CycleWare/Assets/texture.png"
CW.Paths.TEXTURE_CACHE_FOLDER = CW.Paths.CACHE_FOLDER.."/TextureCache"
CW.Paths.TEXTURE_SIG_FILE     = CW.Paths.CACHE_FOLDER.."/texture.sig"

if not isfolder(CW.Paths.TEXTURE_CACHE_FOLDER) then
	pcall(makefolder, CW.Paths.TEXTURE_CACHE_FOLDER)
end

local WEAPON_MESHES = _cfg.WEAPON_MESHES or {
	["M9"]            = "Meshes/M9_3",
	["M4A1"]          = "Meshes/m4_7",
	["Remington 870"] = "Meshes/r870_2",
	["Revolver"]      = "Meshes/revolver (3)",
	["MP5"]           = "GunMesh",
	["AK-47"]         = "Meshes/AK47_7",
}

CW.Assets.weaponTextures = CW.Assets.weaponTextures or {}

local function normalizeKey(s)
	return (s:gsub("%A", "")):lower()
end

local NORMALIZED_TO_WEAPON = {}
for weaponName in pairs(WEAPON_MESHES) do
	NORMALIZED_TO_WEAPON[normalizeKey(weaponName)] = weaponName
end

local genericAsset, genericFailReason = CW.loadCachedAsset({
	file        = CW.Paths.TEXTURE_FILE,
	sigFile     = CW.Paths.TEXTURE_SIG_FILE,
	cacheFolder = CW.Paths.TEXTURE_CACHE_FOLDER,
	prefix      = "tex",
	ext         = ".png",
	label       = "texture.png",
	isUnchanged = function() return CW.Assets.weaponTexture ~= nil end,
})

if genericAsset then
	CW.Assets.weaponTexture = genericAsset
elseif genericFailReason == "missing" or genericFailReason == "error" then
	CW.Assets.weaponTexture = nil
end

local function scanPerGunTextureFiles()
	local found = {}
	local ok, files = pcall(listfiles, CW.Paths.CURSOR_FOLDER)
	if not ok or not files then return found end

	for _, path in ipairs(files) do
		local name = path:match("([^/\\]+)$")
		if name then
			local lower = name:lower()
			if lower:sub(1, 8) == "texture_" and lower:sub(-4) == ".png" and lower ~= "texture.png" then
				local suffix      = name:sub(9, #name - 4)
				local normSuffix  = normalizeKey(suffix)
				local weaponName  = NORMALIZED_TO_WEAPON[normSuffix]
				if weaponName then
					found[weaponName] = path
				end
			end
		end
	end
	return found
end

local perGunFiles     = scanPerGunTextureFiles()
local activeThisRun    = {}

for weaponName, filePath in pairs(perGunFiles) do
	local key     = normalizeKey(weaponName)
	local sigFile = CW.Paths.TEXTURE_CACHE_FOLDER.."/gun_"..key..".sig"

	local asset, failReason = CW.loadCachedAsset({
		file        = filePath,
		sigFile     = sigFile,
		cacheFolder = CW.Paths.TEXTURE_CACHE_FOLDER,
		prefix      = "tex_"..key,
		ext         = ".png",
		label       = "texture for "..weaponName,
		isUnchanged = function() return CW.Assets.weaponTextures[weaponName] ~= nil end,
	})

	if asset then
		CW.Assets.weaponTextures[weaponName] = asset
	elseif failReason == "missing" or failReason == "error" then
		CW.Assets.weaponTextures[weaponName] = nil
	end
	activeThisRun[weaponName] = true
end

for weaponName in pairs(CW.Assets.weaponTextures) do
	if not activeThisRun[weaponName] then
		CW.Assets.weaponTextures[weaponName] = nil
	end
end

local function applyTexture(tool)
	local meshName = WEAPON_MESHES[tool.Name]
	if not meshName then return end

	local textureId = CW.Assets.weaponTextures[tool.Name] or CW.Assets.weaponTexture
	if not textureId then return end

	local mesh = tool:FindFirstChild(meshName, true)
	if mesh and mesh:IsA("MeshPart") then
		mesh.TextureID = textureId
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

if CW.IsFirstRun then
	monitor(LocalPlayer:WaitForChild("Backpack"))

	LocalPlayer.CharacterAdded:Connect(function(character)
		monitor(character)
	end)

	if LocalPlayer.Character then
		monitor(LocalPlayer.Character)
	end
else
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then applyToContainer(backpack) end
	if LocalPlayer.Character then applyToContainer(LocalPlayer.Character) end
end
