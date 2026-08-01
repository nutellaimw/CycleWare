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

local asset, failReason = CW.loadCachedAsset({
	file        = CW.Paths.TEXTURE_FILE,
	sigFile     = CW.Paths.TEXTURE_SIG_FILE,
	cacheFolder = CW.Paths.TEXTURE_CACHE_FOLDER,
	prefix      = "tex",
	ext         = ".png",
	label       = "texture.png",
	isUnchanged = function() return CW.Assets.weaponTexture ~= nil end,
})

if asset then
	CW.Assets.weaponTexture = asset
elseif failReason == "missing" or failReason == "error" then
	CW.Assets.weaponTexture = nil
end

local function applyTexture(tool)
	if not CW.Assets.weaponTexture then return end
	local meshName = WEAPON_MESHES[tool.Name]
	if not meshName then return end
	local mesh = tool:FindFirstChild(meshName, true)
	if mesh and mesh:IsA("MeshPart") then
		mesh.TextureID = CW.Assets.weaponTexture
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
