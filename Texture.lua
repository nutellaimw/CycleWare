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

-- Weapons with a native MeshPart already in the tool — just look it up.
local WEAPON_MESHES = _cfg.WEAPON_MESHES or {
	["M9"]            = "Meshes/M9_3",
	["M4A1"]          = "Meshes/m4_7",
	["Remington 870"] = "Meshes/r870_2",
	["Revolver"]      = "Meshes/revolver (3)",
	["MP5"]           = "GunMesh",
	["AK-47"]         = "Meshes/AK47_7",
}

-- Weapons with NO native MeshPart — we build one ourselves, but ONLY
-- once we know a texture is actually available to put on it. If no
-- texture is loaded for these, the tool is left completely untouched.
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

CW.Assets.weaponTextures = CW.Assets.weaponTextures or {}

local function normalizeKey(s)
	return (s:gsub("%A", "")):lower()
end

local NORMALIZED_TO_WEAPON = {}
for weaponName in pairs(WEAPON_MESHES) do
	NORMALIZED_TO_WEAPON[normalizeKey(weaponName)] = weaponName
end
for weaponName in pairs(CUSTOM_MESH_WEAPONS) do
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

-- ── Custom mesh builder (only ever called once we KNOW a texture exists) ──
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

-- ── Main apply logic ──────────────────────────────────────────────────
local function applyTexture(tool)
	local textureId = CW.Assets.weaponTextures[tool.Name] or CW.Assets.weaponTexture
	if not textureId then return end -- nothing to apply for ANY weapon type

	local customCfg = CUSTOM_MESH_WEAPONS[tool.Name]
	if customCfg then
		-- Rebuild fresh every time a texture is confirmed available —
		-- keeps geometry in sync if this fires again after a re-equip.
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
