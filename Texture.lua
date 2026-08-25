local CW = getgenv().__CW_CORE_STATE

local Players     = game:GetService("Players")
local LocalPlayer = CW.LocalPlayer

local _cfg = getgenv().CW_CONFIG or {}

CW.Paths.TEXTURE_FILE         = CW.Paths.TEXTURE_FILE or _cfg.TEXTURE_FILE or "CycleWare/Assets/texture.png"
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

local CUSTOM_MESH_WEAPONS = _cfg.CUSTOM_MESH_WEAPONS or {
	["FAL"] = {
		meshId      = "rbxassetid://90772329772088",
		meshName    = "FAL/Meshes",
		removeNames = { ["Smooth Block Model"] = true, ["Black"] = true },
		offset      = Vector3.new(0.05, 0.2, -0.55),
		rotation    = Vector3.new(0, 90, 0),
		size        = Vector3.new(0.4, 0.4, 0.4),
	},
	["M700"] = {
		meshId      = "rbxassetid://109235772617313",
		meshName    = "M700/Meshes",
		removeNames = { ["Smooth Block Model"] = true },
		offset      = Vector3.new(0, 0.43, -0.8),
		rotation    = Vector3.new(0, 90, 0),
		size        = Vector3.new(1, 1, 1),
	},
}

local function normalizeKey(s)
	return (s:gsub("%A", "")):lower()
end

local WEAPON_LIST = {}
local NORMALIZED_TO_WEAPON = {}
for weaponName in pairs(WEAPON_MESHES) do
	table.insert(WEAPON_LIST, weaponName)
	NORMALIZED_TO_WEAPON[normalizeKey(weaponName)] = weaponName
end
for weaponName in pairs(CUSTOM_MESH_WEAPONS) do
	table.insert(WEAPON_LIST, weaponName)
	NORMALIZED_TO_WEAPON[normalizeKey(weaponName)] = weaponName
end
table.sort(WEAPON_LIST)

CW.WeaponList          = WEAPON_LIST
CW.normalizeTextureKey = normalizeKey

CW.Assets.weaponTextures = CW.Assets.weaponTextures or {}
CW.Settings.WeaponTextureFiles = CW.Settings.WeaponTextureFiles or {}

if CW.Settings.WeaponTextureFilesByKey then
	for key, path in pairs(CW.Settings.WeaponTextureFilesByKey) do
		local weaponName = NORMALIZED_TO_WEAPON[key]
		if weaponName then
			CW.Settings.WeaponTextureFiles[weaponName] = path
		end
	end
end

function CW.setWeaponTextureFile(weaponName, filename)
	local resolved = CW.resolveAssetPath(filename)
	CW.Settings.WeaponTextureFiles[weaponName] = resolved
	if not resolved then
		CW.Assets.weaponTextures[weaponName] = nil
	end
end

local function reloadGenericTexture()
	local asset, failReason = CW.loadCachedAsset({
		file        = CW.Paths.TEXTURE_FILE,
		sigFile     = CW.Paths.TEXTURE_SIG_FILE,
		cacheFolder = CW.Paths.TEXTURE_CACHE_FOLDER,
		prefix      = "tex",
		ext         = ".png",
		label       = "generic texture ("..CW.Paths.TEXTURE_FILE..")",
		isUnchanged = function() return CW.Assets.weaponTexture ~= nil end,
	})
	if asset then
		CW.Assets.weaponTexture = asset
	elseif failReason == "missing" or failReason == "error" then
		CW.Assets.weaponTexture = nil
	end
end

local function reloadPerGunTextures()
	for _, weaponName in ipairs(WEAPON_LIST) do
		local filePath = CW.Settings.WeaponTextureFiles[weaponName]

		if not filePath then
			CW.Assets.weaponTextures[weaponName] = nil
		else
			local key     = normalizeKey(weaponName)
			local sigFile = CW.Paths.TEXTURE_CACHE_FOLDER.."/gun_"..key..".sig"

			local asset, failReason = CW.loadCachedAsset({
				file        = filePath,
				sigFile     = sigFile,
				cacheFolder = CW.Paths.TEXTURE_CACHE_FOLDER,
				prefix      = "tex_"..key,
				ext         = ".png",
				label       = weaponName.." texture ("..filePath..")",
				isUnchanged = function() return CW.Assets.weaponTextures[weaponName] ~= nil end,
			})

			if asset then
				CW.Assets.weaponTextures[weaponName] = asset
			elseif failReason == "missing" then
				CW.Warn(weaponName.." texture file not found: "..filePath)
				CW.Assets.weaponTextures[weaponName] = nil
			elseif failReason == "error" then
				CW.Assets.weaponTextures[weaponName] = nil
			end
		end
	end
end

local function buildCustomMesh(tool, cfg)
	for _, desc in ipairs(tool:GetDescendants()) do
		if cfg.removeNames[desc.Name] then
			desc:Destroy()
		end
	end

	local old = tool:FindFirstChild(cfg.meshName)
	if old then old:Destroy() end

	local handle = tool:FindFirstChild("Handle")
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

	if handle then
		mesh.CFrame = handle.CFrame
			* CFrame.new(cfg.offset)
			* CFrame.Angles(math.rad(cfg.rotation.X), math.rad(cfg.rotation.Y), math.rad(cfg.rotation.Z))
		mesh.Parent = tool
		local weld  = Instance.new("WeldConstraint")
		weld.Part0  = handle
		weld.Part1  = mesh
		weld.Parent = mesh
	else
		mesh.Parent = tool
	end

	CW.Log("Custom mesh built for "..tool.Name)
	return mesh
end

local function applyTexture(tool)
	local textureId = CW.Assets.weaponTextures[tool.Name] or CW.Assets.weaponTexture
	if not textureId then return end

	local customCfg = CUSTOM_MESH_WEAPONS[tool.Name]
	if customCfg then
		local mesh = buildCustomMesh(tool, customCfg)
		mesh.TextureID = textureId
		return
	end

	local meshName = WEAPON_MESHES[tool.Name]
	if not meshName then return end

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

local function reloadTexturesAndApply()
	reloadGenericTexture()
	reloadPerGunTextures()

	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then applyToContainer(backpack) end
	if LocalPlayer.Character then applyToContainer(LocalPlayer.Character) end
end
CW.reloadTextures = reloadTexturesAndApply
reloadTexturesAndApply()

if CW.IsFirstRun then
	monitor(LocalPlayer:WaitForChild("Backpack"))

	LocalPlayer.CharacterAdded:Connect(function(character)
		monitor(character)
	end)

	if LocalPlayer.Character then
		monitor(LocalPlayer.Character)
	end
end
