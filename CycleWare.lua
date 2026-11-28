-- CycleWare. Standalone entry point; module bodies below are kept in isolated scopes.

--=============================================================================
-- Thread permissions
--   Roblox keeps a thread's permissions as they are across yields and resumes (checked in Studio). Some
--   executors don't: one of their functions can return with the permissions of the thread that called it
--   lowered, and from then on that thread can't touch the GUI ("The current thread cannot access 'Instance'
--   (lacking capability Plugin)"). That once stopped a whole start: the interface never showed and the loading
--   screen only left when its safety timer ran out, a minute later. Three rules keep the script's own threads
--   out of it:
--     * every executor function is called on a short-lived thread of its own (Exec.call): whatever it does to
--       that thread, the caller keeps its permissions;
--     * the startup and the GUI run on threads from cleanThread, made here before any executor call;
--     * a startup step or a UI section that finds its thread lowered anyway runs on a new clean thread
--       (runClean), and the console says which executor function did it.
--=============================================================================
local SCRIPT_VERSION = "2.0.0"

-- New threads made by a thread that never calls an executor function, so each one starts with the
-- permissions this script started with (a new thread gets those of the thread that made it).
local cleanThread
do
	local factory = coroutine.create(function()
		local fn = coroutine.yield()
		while true do
			fn = coroutine.yield(coroutine.create(fn))
		end
	end)
	coroutine.resume(factory)
	function cleanThread(fn)
		local made, thread = coroutine.resume(factory, fn)
		if made and type(thread) == "thread" then return thread end
		return coroutine.create(fn)
	end
end

-- A small object in the GUI container (see CW.attachGui). Changing it fails on a thread that lost its
-- permissions, which is how such a thread is told apart. Until it exists every thread counts as fine.
local guiProbe
local function threadCanTouchGui()
	if not guiProbe then return true end
	return (pcall(function() guiProbe.Name = "CW_Probe" end))
end

local Exec = {}
do
	local reported = {}
	-- Once per function: the console names the executor function that lowered a thread.
	function Exec.noteLowered(name)
		if reported[name] then return end
		reported[name] = true
		warn("[CW] The executor's " .. name .. " lowered the permissions of the thread that called it. CycleWare "
			.. "calls executor functions on threads of their own, so it keeps working.")
	end

	-- Calls fn(...) on a thread of its own and returns what it returns (raises its error). A call that yields (HTTP)
	-- is waited for, up to `timeout` seconds (30 when nil); then it raises "<name> did not answer in N s".
	function Exec.call(name, timeout, fn, ...)
		local box = {}
		local worker = coroutine.create(function(...)
			local clean = threadCanTouchGui()
			box.result = table.pack(pcall(fn, ...))
			if clean and not threadCanTouchGui() then Exec.noteLowered(name) end
			box.done = true
		end)
		local started, startError = coroutine.resume(worker, ...)
		if not started then error(startError, 0) end
		if not box.done then
			local limit = timeout or 30
			local deadline = os.clock() + limit
			while not box.done do
				if os.clock() >= deadline then error(name .. " did not answer in " .. limit .. " s", 0) end
				task.wait()
			end
		end
		local result = box.result
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end

	-- The executor's function wrapped so every call goes through Exec.call; nil when the executor has none.
	function Exec.wrap(name, fn, timeout)
		if type(fn) ~= "function" then return nil end
		return function(...) return Exec.call(name, timeout, fn, ...) end
	end

	-- Starts fn(...) on a thread of its own without waiting for it (firesignal: the game's handlers can yield).
	function Exec.spawn(name, fn, ...)
		local worker = coroutine.create(function(...)
			local clean = threadCanTouchGui()
			local ok, err = pcall(fn, ...)
			if clean and not threadCanTouchGui() then Exec.noteLowered(name) end
			if not ok then warn("[CW] " .. name .. " failed: " .. tostring(err)) end
		end)
		local started, startError = coroutine.resume(worker, ...)
		if not started then warn("[CW] " .. name .. " failed: " .. tostring(startError)) end
	end
end

-- Runs fn(...) now. On a thread that lost its permissions it runs on a new clean thread instead; the caller
-- waits for it either way (a fn that yields is waited for). Returns pcall's results.
local function runClean(label, fn, ...)
	if threadCanTouchGui() then return pcall(fn, ...) end
	warn("[CW] The thread running " .. label .. " lost its permissions; continuing on a new thread.")
	local box = {}
	local thread = cleanThread(function(...)
		box.result = table.pack(pcall(fn, ...))
		box.done = true
	end)
	local started, startError = coroutine.resume(thread, ...)
	if not started then return false, startError end
	while not box.done do task.wait() end
	return table.unpack(box.result, 1, box.result.n)
end

--=============================================================================
-- Preflight
--   Executor functions this script depends on. Whatever is missing is replaced by a safe
--   stand-in, so a single missing function disables one feature instead of aborting the
--   whole script. What was found is stored in CW.Caps and reported once at startup.
--=============================================================================
local CAPS = {
	files = type(isfile) == "function" and type(isfolder) == "function"
		and type(makefolder) == "function" and type(readfile) == "function"
		and type(writefile) == "function" and type(listfiles) == "function",
	customAsset = type(getcustomasset) == "function" or type(getsynasset) == "function",
	getgenv = type(getgenv) == "function",
	gethui = type(gethui) == "function",
	delfile = type(delfile) == "function",
	hook = type(hookmetamethod) == "function" and type(getnamecallmethod) == "function",
	signals = type(firesignal) == "function" or type(getconnections) == "function",
	upvalues = type(getconnections) == "function" and type(debug) == "table"
		and (type(debug.getupvalues) == "function" or type(debug.getupvalue) == "function"),
	request = (type(request) == "function" and request)
		or (type(http_request) == "function" and http_request)
		or (syn and type(syn.request) == "function" and syn.request)
		or (http and type(http.request) == "function" and http.request)
		or nil,
}
do
	local indexed, value = pcall(function() return game.HttpGet end)
	CAPS.httpGet = indexed and type(value) == "function"
end

-- The executor's environment, read once (every getgenv call would be one more executor call).
local genv
if CAPS.getgenv then
	local ok, env = pcall(Exec.call, "getgenv", nil, getgenv)
	if ok and type(env) == "table" then genv = env else CAPS.getgenv = false end
end
genv = genv or {}
local function getgenv() return genv end

-- File functions, each call on a thread of its own (Exec); a missing one is a safe stand-in.
local isfile         = Exec.wrap("isfile", isfile) or function() return false end
local isfolder       = Exec.wrap("isfolder", isfolder) or function() return false end
local makefolder     = Exec.wrap("makefolder", makefolder) or function() end
local readfile       = Exec.wrap("readfile", readfile) or function() error("readfile is unavailable", 0) end
local writefile      = Exec.wrap("writefile", writefile) or function() error("writefile is unavailable", 0) end
local delfile        = Exec.wrap("delfile", delfile) or function() error("delfile is unavailable", 0) end
local listfiles      = Exec.wrap("listfiles", listfiles) or function() return {} end
local getcustomasset = Exec.wrap("getcustomasset", getcustomasset or getsynasset)
	or function() error("getcustomasset is unavailable", 0) end

-- Every other executor function the script calls, wrapped the same way (nil when the executor lacks it).
-- getnamecallmethod and checkcaller are not here: they describe the thread they run on, so the hooks call them
-- directly.
local dbg = type(debug) == "table" and debug or {}
local X = {
	gethui         = Exec.wrap("gethui", gethui),
	hookmetamethod = Exec.wrap("hookmetamethod", hookmetamethod),
	newcclosure    = Exec.wrap("newcclosure", newcclosure),
	getconnections = Exec.wrap("getconnections", getconnections),
	getupvalues    = Exec.wrap("debug.getupvalues", dbg.getupvalues),
	getupvalue     = Exec.wrap("debug.getupvalue", dbg.getupvalue),
	setupvalue     = Exec.wrap("debug.setupvalue", dbg.setupvalue),
	getinfo        = Exec.wrap("debug.getinfo", dbg.getinfo),
	islclosure     = Exec.wrap("islclosure", islclosure),
	iscclosure     = Exec.wrap("iscclosure", iscclosure),
	keypress       = Exec.wrap("keypress", keypress),
	keyrelease     = Exec.wrap("keyrelease", keyrelease),
	loadstring     = Exec.wrap("loadstring", loadstring),
	setclipboard   = Exec.wrap("setclipboard", setclipboard or toclipboard),
	cloneref       = Exec.wrap("cloneref", cloneref),
	protectGui     = Exec.wrap("protect_gui", syn and syn.protect_gui),
	firesignal     = type(firesignal) == "function" and function(...) Exec.spawn("firesignal", firesignal, ...) end or nil,
}

-- The connections of a signal (getconnections) as plain tables { fn, foreign, canFire, raw }, read on a thread of their own
-- (on some executors even reading a connection's fields runs executor code). Empty without getconnections.
local function connectionsOf(signal)
	if not X.getconnections then return {} end
	local ok, list = pcall(Exec.call, "getconnections", nil, function()
		local result = {}
		for _, connection in ipairs(getconnections(signal)) do
			local entry = { raw = connection }
			pcall(function() entry.foreign = connection.ForeignState end)
			-- (connections of a foreign Luau state, such as CoreScripts, are left alone)
			if entry.foreign ~= true then pcall(function() entry.fn = connection.Function end) end
			pcall(function() entry.canFire = type(connection.Fire) == "function" end)
			table.insert(result, entry)
		end
		return result
	end)
	return ok and type(list) == "table" and list or {}
end

-- Startup steps: each module of this file, then the interface. runModule only records a step; the Startup section
-- (end of the file) runs them in order on a clean thread. A step that throws is reported and the next one still runs.
local steps = {}
local function runModule(name, fn)
	table.insert(steps, { name = name, fn = fn })
end
-- What failed while starting (step or UI section name -> error); the window lists them (Finish step).
local startupProblems = {}

local _env = getgenv()
local _cfg = _env.CW_CONFIG
if type(_cfg) ~= "table" then
	_cfg = {}
	_env.CW_CONFIG = _cfg
end
if type(_cfg.ASSET_MANIFEST_URL) ~= "string" or _cfg.ASSET_MANIFEST_URL == "" then
	_cfg.ASSET_MANIFEST_URL = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/manifest.json"
end

local function boolOr(v, default)
	if v == nil then return default end
	return v
end

local function numOr(v, default, minValue)
	v = tonumber(v)
	if v == nil then v = default end
	if minValue and v < minValue then v = minValue end
	return v
end

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local GuiService        = game:GetService("GuiService")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local Mouse       = LocalPlayer:GetMouse()

local CW = getgenv().__CW_CORE_STATE
local isFirstRun = false

if not CW then
	isFirstRun = true
	CW = {
		Settings = {},
		Paths    = {},
		Assets   = {},
		ActiveFollowClones = {},
		State    = {
			cursorsReady     = false,
			currentCursorKey = nil,
			settingCursor    = false,
			lastTarget       = nil,
			enforcerConn     = nil,
			enableConn       = nil,
			mouseX           = 0,
			mouseY           = 0,
		},
	}
	getgenv().__CW_CORE_STATE = CW
end

CW.IsFirstRun  = isFirstRun
CW.LocalPlayer = LocalPlayer
CW.Mouse       = Mouse

-- Each run has a number; a run whose number is no longer the latest stops at its next step (a re-run took over).
CW.State.runId = (CW.State.runId or 0) + 1
local runId = CW.State.runId
local function isCurrentRun() return CW.State.runId == runId end
if CW.State.startupThread and coroutine.status(CW.State.startupThread) == "suspended" then
	pcall(task.cancel, CW.State.startupThread) -- the last run was still starting
end
CW.State.startupProblems = startupProblems

CW.PreviousVersion = CW.Version
CW.Version         = SCRIPT_VERSION
CW.Caps            = CAPS

-- Every bullet gun has its own tracer. A field a gun never set starts from these values.
CW.GunTracerDefaults = {
	color = Color3.fromRGB(170, 0, 255), glow = Color3.fromRGB(200, 100, 255),
	width = 0.05, life = 0.05, transparency = 0.1, light = false,
}

if CW.Debug == nil then CW.Debug = true end
CW.Debug = boolOr(_cfg.DEBUG, CW.Debug)

function CW.Log(msg)
	if CW.Debug then
		print("[CW] " .. msg)
	end
end

function CW.Warn(msg)
	warn("[CW] " .. msg)
end

--// Connection registry -------------------------------------------------------------
-- Registering again under the same key disconnects the previous connection, so a re-run
-- REPLACES the old code instead of leaving it active next to the new one.
CW.State.conns = CW.State.conns or {}

function CW.track(key, connection)
	local conns = CW.State.conns
	local previous = conns[key]
	if previous then
		pcall(function() previous:Disconnect() end)
	end
	conns[key] = connection
	return connection
end

function CW.untrack(key)
	local conns = CW.State.conns
	local previous = conns[key]
	conns[key] = nil
	if previous then
		pcall(function() previous:Disconnect() end)
	end
end

function CW.untrackAll()
	for key in pairs(CW.State.conns) do
		CW.untrack(key)
	end
end

--// GUI parent -----------------------------------------------------------------------
-- Parents the GUI to the first container that accepts it: gethui() when the executor has it,
-- otherwise CoreGui, otherwise PlayerGui. The first GUI also takes the permission probe (guiProbe) along:
-- it sits in the same container, so it is protected exactly like the GUI.
local function placeProbe(container)
	if guiProbe and guiProbe.Parent == container then return end
	local probe = Instance.new("Folder")
	probe.Name = "CW_Probe"
	if pcall(function() probe.Parent = container end) and probe.Parent == container then
		local previous = CW.State.guiProbe -- the last run's
		if previous and previous ~= probe then pcall(function() previous:Destroy() end) end
		CW.State.guiProbe = probe
		guiProbe = probe
	end
end
function CW.attachGui(gui)
	local candidates = {}
	if X.gethui then
		local ok, container = pcall(X.gethui)
		if ok and typeof(container) == "Instance" then table.insert(candidates, container) end
	end
	local okCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
	if okCore and coreGui then table.insert(candidates, coreGui) end
	local playerGui = CW.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then table.insert(candidates, playerGui) end

	for _, container in ipairs(candidates) do
		local attached = pcall(function() gui.Parent = container end)
		if attached and gui.Parent == container then
			if not guiProbe then placeProbe(container) end
			return true
		end
	end
	return false
end

--// Loading screen -------------------------------------------------------------------
-- On screen from here until the interface is built; the window stays hidden until it goes. Size, text sizes,
-- places and the opening and closing come from the owner's Intro (350x200); the look (colors, texts, color bar,
-- lighter band, ring) from the owner's reference image. Arimo is the closest Roblox font to the reference's
-- regular sans.
-- It only shows what the startup reports: step(label, progress) while loading, then finish(outcome, message,
-- onClosed). It draws from its own frame loop, made on a clean thread, so a step whose thread lost its
-- permissions can't break it, and the end it shows is the real one:
--   "ready"     Ready, then it goes and onClosed opens the window;
--   "problems"  the window opens too, after the screen said how many parts failed (the window lists them);
--   "failed"    the interface could not start: the screen says why and stays until clicked (or FAILED_SHOWN s).
-- A step that takes long gets a "taking longer than usual" line; a startup that ends without a result is shown
-- as stopped, at the step it was on.
local loadingScreen = {} -- step(label, progress), finish(outcome, message, onClosed), watch(thread)
-- Stand-ins, for when the screen can't be built: steps are ignored and finish opens the window at once.
function loadingScreen.step() end
function loadingScreen.watch() end
function loadingScreen.finish(outcome, message, onClosed)
	if outcome == "failed" then warn("[CW] " .. tostring(message)) end
	if onClosed then task.spawn(cleanThread(onClosed)) end
end
local screenBuilt, screenError = pcall(function()
	local RunService = game:GetService("RunService")
	local TweenService = game:GetService("TweenService")
	local MIN_SHOWN = 1.7 -- seconds: shortest time on screen (the opening takes 1.65)
	local SLOW_AFTER = 15 -- seconds on one step before the "taking longer" line shows
	local FAILED_SHOWN = 20 -- seconds a failure stays up when not clicked
	local FONT = Font.new("rbxasset://fonts/families/Arimo.json")
	local DARK, BAND, WHITE = Color3.fromRGB(38, 38, 38), Color3.fromRGB(64, 64, 64), Color3.new(1, 1, 1)

	if CW.closeLoadingScreen then pcall(CW.closeLoadingScreen, true) end -- a re-run replaces the last run's screen

	-- With Reduced Motion on (Roblox's settings), it shows and goes at once and the ring stays still.
	local still = false
	pcall(function() still = GuiService.ReducedMotionEnabled end)

	local function make(class, props, parent)
		local inst = Instance.new(class)
		for key, value in pairs(props) do inst[key] = value end
		inst.Parent = parent
		return inst
	end
	local function text(content, size, props, parent)
		props.BackgroundTransparency = 1
		props.Text = content
		props.TextSize = size
		props.FontFace = FONT
		props.TextColor3 = WHITE
		return make("TextLabel", props, parent)
	end
	local function after(seconds, fn) task.delay(still and 0 or seconds, fn) end
	local function tween(inst, seconds, goal, style, direction)
		TweenService:Create(inst, TweenInfo.new(still and 0 or seconds, style or Enum.EasingStyle.Quad,
			direction or Enum.EasingDirection.Out), goal):Play()
	end
	-- Calls step(a) as a goes from 0 to 1 over the time (Quad Out), for what a tween can't move, like a gradient.
	local function animate(seconds, step)
		local value = make("NumberValue", {})
		value.Changed:Connect(step)
		local run = TweenService:Create(value, TweenInfo.new(still and 0 or seconds, Enum.EasingStyle.Quad), { Value = 1 })
		run.Completed:Connect(function()
			step(1)
			value:Destroy()
		end)
		run:Play()
	end
	-- A transparency sequence from { time, value } points; a point not after the one before it is skipped.
	local function sequence(points)
		local keys, last = {}, -1
		for _, point in ipairs(points) do
			local t = math.clamp(point[1], 0, 1)
			if t > last then
				table.insert(keys, NumberSequenceKeypoint.new(t, point[2]))
				last = t
			end
		end
		return NumberSequence.new(keys)
	end

	local gui = make("ScreenGui", {
		Name = "CW_Loading", IgnoreGuiInset = true, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 1000000, -- over the window (999999)
	})
	-- A CanvasGroup clips the turned dark side to the card; its gradient (mask) opens the card and sweeps it away.
	local card = make("CanvasGroup", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(350, 200),
		BackgroundColor3 = BAND, BorderSizePixel = 0,
	}, gui)
	local mask = make("UIGradient", { Rotation = -30, Transparency = NumberSequence.new(1) }, card)

	-- The dark side: a large square turned 30 degrees whose lower edge runs from (107, 200) to (350, 60), leaving
	-- the lighter band at the bottom right. It wipes in from the top left and, when closing, covers the card.
	local DARK_IN, DARK_AT, DARK_OVER = UDim2.fromOffset(-37, -329), UDim2.fromOffset(79, -130), UDim2.fromOffset(144, -17)
	local dark = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = DARK_IN, Size = UDim2.fromOffset(1000, 600), Rotation = -30,
		BackgroundColor3 = DARK, BorderSizePixel = 0, ZIndex = 0,
	}, card)

	-- The texts start off the card and slide in from the left.
	local title = text("Cycle-Ware", 25, {
		Position = UDim2.fromOffset(-190, 15), Size = UDim2.fromOffset(100, 50), TextTransparency = 1,
	}, card)
	local subtitle = text("Developed by Nutella", 18, {
		Position = UDim2.fromOffset(-230, 60), Size = UDim2.fromOffset(180, 25), TextTransparency = 1,
	}, card)
	local version = text("V" .. SCRIPT_VERSION, 14, {
		Position = UDim2.fromOffset(8, 173), Size = UDim2.fromOffset(105, 20), TextXAlignment = Enum.TextXAlignment.Left,
	}, card)
	local versionMask = make("UIGradient", { Transparency = NumberSequence.new(1) }, version)
	-- What is loading and how far along it is, under the title. The progress bar is the reference's color line:
	-- the filled part uncovers the colors one after another, and a full bar is the whole line.
	local status = text("Loading modules", 14, {
		Position = UDim2.fromOffset(20, 110), Size = UDim2.fromOffset(180, 25), TextTransparency = 1,
	}, card)
	-- Under the bar: "taking longer than usual" while a step is slow; after a failure, where the details are.
	local hint = text("", 12, {
		Position = UDim2.fromOffset(20, 152), Size = UDim2.fromOffset(180, 18), TextTransparency = 1,
	}, card)
	local track = make("Frame", {
		Position = UDim2.fromOffset(110, 145), Size = UDim2.fromOffset(0, 4), BackgroundColor3 = BAND, BorderSizePixel = 0,
	}, card)
	local fill = make("Frame", {
		Size = UDim2.fromScale(0.1, 1), BackgroundTransparency = 1, ClipsDescendants = true,
	}, track)
	make("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, SortOrder = Enum.SortOrder.LayoutOrder }, fill)
	for i, piece in ipairs({ { 18, "fc5dff" }, { 46, "ff3164" }, { 18, "72ff9a" }, { 18, "00b4ff" } }) do -- widths add up to the bar's 100
		make("Frame", {
			LayoutOrder = i, Size = UDim2.new(0, piece[1], 1, 0), BackgroundColor3 = Color3.fromHex(piece[2]),
			BorderSizePixel = 0,
		}, fill)
	end

	-- The ring: short pieces around a circle, shaded like the reference (white at the round head, then
	-- darker around the circle), turning counterclockwise so the head leads.
	local ring = make("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(329, 179), Size = UDim2.fromOffset(26, 26),
		BackgroundTransparency = 1,
	}, card)
	local ringScale = make("UIScale", { Scale = 0 }, ring)
	local SHADES = { { 0, 255 }, { 0.13, 255 }, { 0.3, 212 }, { 0.53, 241 }, { 0.7, 209 }, { 0.8, 176 }, { 1, 113 } }
	local function shade(t)
		for i = 2, #SHADES do
			local a, b = SHADES[i - 1], SHADES[i]
			if t <= b[1] then
				local v = math.floor(a[2] + (b[2] - a[2]) * (t - a[1]) / (b[1] - a[1]) + 0.5)
				return Color3.fromRGB(v, v, v)
			end
		end
		return Color3.fromRGB(113, 113, 113)
	end
	local INNER, OUTER, PIECES, HEAD = 9.5, 13, 48, 80 -- radii of the ring; HEAD: degrees clockwise from 3 o'clock
	local middle, width = (INNER + OUTER) / 2, OUTER - INNER
	local function round(props)
		local frame = make("Frame", props, ring)
		make("UICorner", { CornerRadius = UDim.new(1, 0) }, frame)
		return frame
	end
	for i = 0, PIECES - 1 do
		local t = (i + 0.5) / PIECES
		local angle = math.rad(HEAD + 360 * t)
		make("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, middle * math.cos(angle), 0.5, middle * math.sin(angle)),
			Size = UDim2.fromOffset(2 * math.pi * middle / PIECES + 2, width + 2), Rotation = math.deg(angle) + 90,
			BackgroundColor3 = shade(t), BorderSizePixel = 0,
		}, ring)
	end
	round({ -- the head
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, middle * math.cos(math.rad(HEAD)), 0.5, middle * math.sin(math.rad(HEAD))),
		Size = UDim2.fromOffset(width, width), BackgroundColor3 = WHITE, BorderSizePixel = 0, ZIndex = 2,
	})
	-- The pieces reach 1 px past both edges; two smooth circles in the band's color (the ring sits on the band)
	-- trim them to a clean ring.
	local outerEdge = round({
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(2 * OUTER, 2 * OUTER),
		BackgroundTransparency = 1, ZIndex = 3,
	})
	make("UIStroke", { Color = BAND, Thickness = 3 }, outerEdge)
	round({
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(2 * INNER, 2 * INNER),
		BackgroundColor3 = BAND, BorderSizePixel = 0, ZIndex = 3,
	})

	CW.attachGui(gui)

	-- Opening, as in the Intro: the card closes in from both ends; then the dark side wipes in, the title and
	-- subtitle slide in and the version is uncovered; then the status, the progress bar and the ring come up.
	animate(0.4, function(a)
		local v = a / 2
		mask.Transparency = v >= 0.49 and NumberSequence.new(0)
			or sequence({ { 0, 0 }, { v, 0 }, { v + 0.02, 1 }, { 1 - v - 0.02, 1 }, { 1 - v, 0 }, { 1, 0 } })
	end)
	after(0.4, function()
		tween(dark, 0.4, { Position = DARK_AT })
		tween(title, 0.4, { Position = UDim2.fromOffset(60, 15), TextTransparency = 0 })
		tween(subtitle, 0.4, { Position = UDim2.fromOffset(20, 60), TextTransparency = 0 })
		animate(0.4, function(a) versionMask.Transparency = sequence({ { 0, 0 }, { a, 0 }, { a + 0.02, 1 }, { 1, 1 } }) end)
	end)
	after(1.3, function()
		tween(status, 0.25, { Position = UDim2.fromOffset(20, 120), TextTransparency = 0.3 })
		tween(track, 0.25, { Position = UDim2.fromOffset(60, 145), Size = UDim2.fromOffset(100, 4) })
		tween(ringScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end)

	--// What the startup reports (plain values: these never touch the GUI)
	local report = { label = "Loading modules", progress = 0.1 }
	local reportedAt, shownAt = os.clock(), os.clock()
	local finished -- { outcome, message, onClosed } once finish was called
	local startupThread -- the thread running the startup: if it ends without finish, the startup stopped

	function loadingScreen.step(label, progress)
		report.label, report.progress = label, progress or report.progress
		reportedAt = os.clock()
	end
	function loadingScreen.finish(outcome, message, onClosed)
		if finished then return end
		finished = { outcome = outcome or "ready", message = message, onClosed = onClosed }
	end
	function loadingScreen.watch(thread) startupThread = thread end

	--// Drawing, from the frame loop only
	local driver
	local removed, closing, failedShown = false, false, false
	local drawn: { [string]: any } = {} -- what is on screen now (label, progress, hint, when the end began)
	local function remove()
		if removed then return end
		removed = true
		if driver then driver:Disconnect() end
		gui:Destroy()
	end
	local function showHint(content)
		if drawn.hint == content then return end
		drawn.hint = content
		hint.Text = content
		tween(hint, 0.25, { TextTransparency = content == "" and 1 or 0.4 })
	end
	-- As the Intro closes: the texts fade, the dark side covers the card and a last sweep takes it away. onClosed
	-- (the window opening) runs as the card goes.
	local function closeCard(onClosed)
		if closing then return end
		closing = true
		for _, label in ipairs({ title, subtitle, status, version, hint }) do tween(label, 0.25, { TextTransparency = 1 }) end
		for _, piece in ipairs(fill:GetChildren()) do
			if piece:IsA("Frame") then tween(piece, 0.25, { BackgroundTransparency = 1 }) end
		end
		tween(track, 0.25, { BackgroundTransparency = 1 })
		tween(ringScale, 0.25, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		tween(dark, 0.4, { Position = DARK_OVER }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		after(0.5, function()
			if onClosed then
				local ok, err = pcall(onClosed)
				if not ok then warn("[CW] Opening the window failed: " .. tostring(err)) end
			end
			mask.Rotation = 30
			animate(0.4, function(a) mask.Transparency = sequence({ { 0, 1 }, { a, 1 }, { a + 0.05, 0 }, { 1, 1 } }) end)
			after(0.45, remove)
		end)
	end
	-- A failure: the message takes the status line (left-aligned, room for two lines), the bar and the ring go,
	-- and a click on the card (or FAILED_SHOWN seconds) closes it.
	local function showFailure(message)
		if failedShown then return end
		failedShown = true
		status.TextXAlignment = Enum.TextXAlignment.Left
		status.TextWrapped = true
		status.Size = UDim2.fromOffset(300, 34)
		status.Position = UDim2.fromOffset(20, 108)
		status.Text = message
		drawn.label = message
		tween(status, 0.25, { TextTransparency = 0 })
		tween(track, 0.25, { BackgroundTransparency = 1 })
		for _, piece in ipairs(fill:GetChildren()) do
			if piece:IsA("Frame") then tween(piece, 0.25, { BackgroundTransparency = 1 }) end
		end
		tween(ringScale, 0.25, { Scale = 0 })
		hint.TextXAlignment = Enum.TextXAlignment.Left -- under the message, as wide
		hint.Size = UDim2.fromOffset(300, 18)
		showHint("Details in the console (F9). Click to close.")
		local closer = make("TextButton", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "", ZIndex = 10, AutoButtonColor = false,
		}, card)
		closer.MouseButton1Click:Connect(function() closeCard(nil) end)
		task.delay(FAILED_SHOWN, function() closeCard(nil) end)
	end

	local function drive(dt)
		if not still then ring.Rotation = (ring.Rotation - 330 * dt) % 360 end
		if closing then return end
		if failedShown then
			-- a startup that went on after all (on a new thread) still opens the window
			if finished and finished.outcome ~= "failed" then closeCard(finished.onClosed) end
			return
		end
		local now = os.clock()
		if not finished then
			if report.label ~= drawn.label then
				drawn.label = report.label
				status.Text = report.label
			end
			if report.progress ~= drawn.progress then
				drawn.progress = report.progress
				tween(fill, 0.25, { Size = UDim2.fromScale(math.clamp(report.progress, 0, 1), 1) })
			end
		else
			-- Nothing is shown before the opening is over (MIN_SHOWN): its last tweens would move it back.
			if now - shownAt < MIN_SHOWN then return end
			if finished.outcome == "failed" then
				showFailure(finished.message or "CycleWare could not start")
				return
			end
			-- Ready (or how many parts failed) a moment on screen, then the card goes and the window opens.
			if not drawn.ending then
				drawn.ending = now
				local problems = finished.outcome == "problems"
				status.Text = problems and (finished.message or "Loaded with problems") or "Ready"
				drawn.label = status.Text
				tween(fill, 0.25, { Size = UDim2.fromScale(1, 1) })
				showHint(problems and "The window lists them" or "")
			end
			if now - drawn.ending >= (finished.outcome == "problems" and 2 or 0.5) then closeCard(finished.onClosed) end
			return
		end
		if startupThread and coroutine.status(startupThread) == "dead" and now - shownAt >= MIN_SHOWN then
			showFailure("CycleWare stopped while: " .. tostring(report.label))
			return
		end
		showHint(now - reportedAt >= SLOW_AFTER and "Taking longer than usual" or "")
	end
	task.spawn(cleanThread(function()
		driver = RunService.RenderStepped:Connect(drive)
	end))

	-- A re-run takes this screen away at once (the new run brings its own).
	CW.closeLoadingScreen = function()
		closing = true
		pcall(remove)
	end
end)
if not screenBuilt then warn("[CW] The loading screen could not be shown: " .. tostring(screenError)) end

--// Teams ----------------------------------------------------------------------------
-- The original rule: anyone on a different team than you is an enemy, whether or not a shot could
-- actually hurt them (a ForceField, or a Guard against a calm Inmate, still counts). The hit sound,
-- the hitmarker and the red cursor use it; the same team gets the green cursor. The team color is
-- read straight from the player, so no cache or signal is needed.
function CW.isEnemy(player)
	return player ~= nil and player ~= LocalPlayer and player.TeamColor ~= LocalPlayer.TeamColor
end

--// HTTP -----------------------------------------------------------------------------
-- The executor's request function goes first: game:HttpGet blocks the main thread on many
-- executors, so it is only the fallback. Each runs on a thread of its own (Exec) and is waited for
-- `timeout` seconds at most (20 by default); a request that did not answer is not tried again with
-- HttpGet (the connection is the problem then). Raises an error when nothing works.
function CW.httpGet(url, timeout)
	timeout = timeout or 20
	local lastError, timedOut
	local requestFn = CW.Caps.request
	if requestFn then
		local sent, response = pcall(Exec.call, "request", timeout, requestFn, { Url = url, Method = "GET" })
		if sent and type(response) == "table" then
			local status = tonumber(response.StatusCode)
			local success = response.Success == true or (status ~= nil and status >= 200 and status < 300)
			if success and type(response.Body) == "string" then return response.Body end
			lastError = "HTTP " .. tostring(response.StatusCode or "?") .. " " .. tostring(response.StatusMessage or "")
		else
			lastError = response
			timedOut = type(response) == "string" and response:find("did not answer", 1, true) ~= nil
		end
	end

	if CW.Caps.httpGet and not timedOut then
		local ok, result = pcall(Exec.call, "HttpGet", timeout, function() return game:HttpGet(url) end)
		if ok and type(result) == "string" then return result end
		lastError = lastError or result
	end
	error(tostring(lastError or "no HTTP function available"), 0)
end

--// Running again ----------------------------------------------------------------------
-- Runs CycleWare again; the new run replaces this one (its window, its connections), as when the player runs it
-- twice. Used to load a settings slot. The code comes from CW_CONFIG.SCRIPT_FILE (a file in the executor's
-- workspace, for local tests, like UI_FILE) or else from CW_CONFIG.SCRIPT_URL (the repository's copy by default).
-- Returns false and the reason when the code could not be had.
local SCRIPT_URL = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/CycleWare.lua"
function CW.restart()
	local source
	local file = type(_cfg.SCRIPT_FILE) == "string" and _cfg.SCRIPT_FILE ~= "" and _cfg.SCRIPT_FILE or nil
	if file then
		local ok, data = pcall(readfile, file)
		if ok and type(data) == "string" and data ~= "" then source = data end
	end
	if not source then
		local url = type(_cfg.SCRIPT_URL) == "string" and _cfg.SCRIPT_URL ~= "" and _cfg.SCRIPT_URL or SCRIPT_URL
		local ok, data = pcall(CW.httpGet, url)
		if not (ok and type(data) == "string" and data:find("__CW_CORE_STATE", 1, true)) then
			return false, "could not download CycleWare (" .. tostring(data) .. ")"
		end
		source = data
	end
	if not X.loadstring then return false, "this executor has no loadstring" end
	local compiled, run, compileError = pcall(X.loadstring, source)
	if not compiled or type(run) ~= "function" then return false, tostring(compileError or run) end
	-- On a clean thread: the button that asked for it runs on a thread that has just called the executor.
	task.spawn(cleanThread(run))
	return true
end

--// Startup report -------------------------------------------------------------------
do
	local missing = {}
	if not CAPS.getgenv then table.insert(missing, "getgenv (re-running without rejoining will not be clean)") end
	if not CAPS.files then table.insert(missing, "file functions (asset library, cursor, textures, sounds and saved settings are disabled; custom IDs last until you rejoin)") end
	if not CAPS.customAsset then table.insert(missing, "getcustomasset (custom images and sounds are disabled)") end
	if not CAPS.hook then table.insert(missing, "hookmetamethod/getnamecallmethod (hitmarker and hit sound detection is disabled)") end
	if not CAPS.signals then table.insert(missing, "firesignal/getconnections (Auto Reload presses R instead of reloading instantly)") end
	if not CAPS.gethui then table.insert(missing, "gethui (using CoreGui instead)") end
	if not CAPS.upvalues then table.insert(missing, "getconnections + debug.getupvalue (Auto Slot works only with Use Old Backpack)") end
	if not CAPS.delfile then table.insert(missing, "delfile (removing a cursor added by ID leaves its PNG in the Cursors folder)") end
	if not CAPS.httpGet and not CAPS.request then table.insert(missing, "HTTP (asset sync and the UI download are disabled)") end
	if #missing > 0 then
		CW.Warn("Missing executor functions: " .. table.concat(missing, "; "))
	end
end

CW.Log(isFirstRun and "First run: initializing." or "Re-run detected: reloading modules and replacing the previous run's connections.")
if not isFirstRun and CW.PreviousVersion == nil then
	CW.Warn("State from an older script version was found. Connections made by that version stay active until you rejoin, so rejoin once for a fully clean update.")
end

CW.Paths.CURSOR_ROOT = "CycleWare"
CW.Paths.LIBRARY_ROOT = CW.Paths.CURSOR_ROOT .. "/Library"
CW.Paths.CURSORS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Cursors"
CW.Paths.HITMARKERS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Hitmarkers"
CW.Paths.HIT_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/HitSounds"
CW.Paths.WEAPON_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/WeaponSounds"
CW.Paths.RELOAD_SOUNDS_FOLDER = CW.Paths.LIBRARY_ROOT .. "/ReloadSounds"
CW.Paths.TEXTURES_FOLDER = CW.Paths.LIBRARY_ROOT .. "/Textures"
CW.Paths.OFFICIAL_FOLDER = "_Official"
CW.Paths.CACHE_FOLDER = CW.Paths.CURSOR_ROOT .. "/Cache"
CW.Paths.GENERATED_FOLDER = CW.Paths.CACHE_FOLDER .. "/Generated"
CW.Paths.TINTED_FOLDER = CW.Paths.GENERATED_FOLDER .. "/Cursors"
CW.Paths.CURSOR_SIG_FILE = CW.Paths.TINTED_FOLDER .. "/cursor.sig"
CW.Paths.MANIFEST_FILE = CW.Paths.LIBRARY_ROOT .. "/manifest.json"
CW.Paths.CUSTOM_IDS_FILE = CW.Paths.CURSOR_ROOT .. "/custom_ids.json"
CW.Paths.LIBRARY_REVISION_FILE = CW.Paths.LIBRARY_ROOT .. "/.revision"
CW.Paths.SETTINGS_FILE = CW.Paths.CACHE_FOLDER .. "/ui_settings.json"
-- Settings slots (Settings tab): one file per slot, written like SETTINGS_FILE. Outside the cache, which can be cleared.
CW.Paths.SETTINGS_SLOTS_FOLDER = CW.Paths.CURSOR_ROOT .. "/Settings Slots"
CW.Paths.AUDIO_COPIES_FOLDER = CW.Paths.CACHE_FOLDER .. "/Audio"
CW.Paths.AUDIO_PROBE_FILE = CW.Paths.CACHE_FOLDER .. "/audio_probe.json"
-- The official files the sync has checked: relative path -> { crc32, size } (see CW.Library.sync).
CW.Paths.LIBRARY_INDEX_FILE = CW.Paths.LIBRARY_ROOT .. "/.index.json"
CW.Paths.UI_CACHE_FILE = CW.Paths.CACHE_FOLDER .. "/CWUI.lua"

--// Interface source -----------------------------------------------------------------
-- The UI library (CWUI.lua) is downloaded from the start, while the modules load, so it is mostly in by the time
-- the interface is built (Interface step). CW_CONFIG.UI_FILE (a file in the executor's workspace) is used instead
-- when set. The last good download is kept (UI_CACHE_FILE): when GitHub is slow, that copy is used after
-- UI_CACHED_WAIT seconds, and the download, which goes on, refreshes it for the next run. The asset sync waits
-- for this download, so the two don't share the connection.
local UI_URL = "https://raw.githubusercontent.com/nutellaimw/CycleWare/refs/heads/main/CWUI.lua"
local UI_CACHED_WAIT, UI_DOWNLOAD_WAIT = 4, 25 -- seconds to wait for the download, with and without a saved copy
local function isUISource(text) return type(text) == "string" and text:find("CreateWindow", 1, true) ~= nil end
local uiFetch = { done = false } -- source or error once done
do
	local localFile = type(_cfg.UI_FILE) == "string" and _cfg.UI_FILE ~= "" and _cfg.UI_FILE or nil
	local localSource
	if localFile then
		local ok, data = pcall(readfile, localFile)
		if ok and isUISource(data) then
			localSource = data
		else
			CW.Warn("UI_FILE could not be read (" .. localFile .. "); downloading the UI instead")
		end
	end
	if localSource then
		uiFetch.source, uiFetch.fromFile, uiFetch.done = localSource, localFile, true
	else
		CW.Log("Downloading CycleWare UI from GitHub")
		task.spawn(function()
			local ok, body = pcall(CW.httpGet, UI_URL, UI_DOWNLOAD_WAIT)
			if ok and isUISource(body) then
				uiFetch.source = body
				if not isfolder(CW.Paths.CACHE_FOLDER) then
					pcall(makefolder, CW.Paths.CURSOR_ROOT)
					pcall(makefolder, CW.Paths.CACHE_FOLDER)
				end
				pcall(writefile, CW.Paths.UI_CACHE_FILE, body) -- the last good copy
			else
				uiFetch.error = ok and "the downloaded file is not the UI library" or tostring(body)
			end
			uiFetch.done = true
		end)
	end
end

CW.Paths.CURSOR_FILE = nil
CW.Paths.HITMARKER_FILE = nil
CW.Paths.SOUND_FILE = nil

-- Everything is off by default; only what the player changes is saved (see saveSettings).
CW.Settings.HITMARKER_SIZE             = numOr(_cfg.HITMARKER_SIZE, 50, 1)
CW.Settings.SOUND_VOLUME               = numOr(_cfg.SOUND_VOLUME, 1, 0)
CW.Settings.CURSOR_TARGET_SIZE         = numOr(_cfg.CURSOR_TARGET_SIZE, 82, 1)
CW.Settings.HITMARKER_VISIBLE_DURATION = numOr(_cfg.HITMARKER_VISIBLE_DURATION, 0.05, 0)
CW.Settings.HITMARKER_FADEOUT_DURATION = numOr(_cfg.HITMARKER_FADEOUT_DURATION, 0.15, 0)

CW.Settings.HITMARKER_RANDOM_ROTATION = boolOr(_cfg.HITMARKER_RANDOM_ROTATION, false)
CW.Settings.HITMARKER_FOLLOW_MOUSE    = boolOr(_cfg.HITMARKER_FOLLOW_MOUSE, false)
CW.Settings.HITMARKER_FADEOUT         = boolOr(_cfg.HITMARKER_FADEOUT, false)

-- Cursor team check: the cursor takes the enemy color over an enemy and the teammate color over a teammate.
-- On by default because that is how the cursor always behaved.
CW.Settings.CURSOR_TEAM_CHECK  = boolOr(_cfg.CURSOR_TEAM_CHECK, true)
CW.Settings.CURSOR_ENEMY_COLOR = Color3.fromRGB(255, 56, 56)
CW.Settings.CURSOR_TEAM_COLOR  = Color3.fromRGB(56, 255, 56)

-- UI look (CWUI.SetTheme): only what the player changed. Colors as hex, transparencies 0..1,
-- Image = Roblox ID or workspace path, ImageTransparency 0..1.
CW.Settings.UI_THEME = {}
-- Background layers (CWUI SetBackgroundLayers), kept as one JSON string because the settings file only holds
-- flat values. Each layer: Image (Roblox ID or workspace path), X, Y, W, H (fractions of the window), Depth,
-- Transparency, Scale, Fill (hex), FillTransparency.
CW.Settings.UI_LAYERS = ""
-- Per-asset settings (see CW.Profiles below): { [category] = { [asset's library path] = { [setting] = value } } }.
CW.Settings.ASSET_PROFILES = {}
-- Hit sound of each gun (CW.HitSounds, Sound module): { [gun] = library path or "id:123" }, and the volume of
-- each gun's sounds: { ["<gun>|<path>"] = volume }.
CW.Settings.HIT_SOUND_GUNS = {}
CW.Settings.HIT_SOUND_GUN_VOLUMES = {}
-- What each mesh of a gun keeps for itself (CW.MeshProfiles, Texture module): { [gun] = { [mesh] = profile } },
-- mesh = "Default" or "id:123". A profile: Texture, Shoot, Reload, Effect (of a mesh not in use) and Fire.
CW.Settings.MESH_PROFILES = {}
-- The settings slot the settings in use were last loaded from or saved to ("" when none; Settings tab).
CW.Settings.SETTINGS_SLOT = ""
-- Anti-AFK (AntiAFK module): on unless the player turns it off, since it only keeps Roblox's idle kick away.
CW.Settings.ANTI_AFK_ENABLED = boolOr(_cfg.ANTI_AFK, true)

-- Snapshot of the defaults, taken before any saved value is applied. The save routine
-- writes only the settings whose value differs from these.
CW.Defaults = {}
for _, key in ipairs({
	"HITMARKER_SIZE", "SOUND_VOLUME", "CURSOR_TARGET_SIZE", "HITMARKER_VISIBLE_DURATION",
	"HITMARKER_FADEOUT_DURATION", "HITMARKER_RANDOM_ROTATION", "HITMARKER_FOLLOW_MOUSE", "HITMARKER_FADEOUT",
	"CURSOR_TEAM_CHECK", "CURSOR_ENEMY_COLOR", "CURSOR_TEAM_COLOR", "UI_LAYERS", "ANTI_AFK_ENABLED",
}) do
	CW.Defaults[key] = CW.Settings[key]
end

CW.Settings.ASSET_SELECTIONS = CW.Settings.ASSET_SELECTIONS or {
	Cursor = nil,
	Hitmarker = nil,
	HitSound = nil,
	Textures = {},
	Meshes = {},
}
CW._SavedSettings = {}

local settingsFileExists = false
pcall(function()
	settingsFileExists = isfile(CW.Paths.SETTINGS_FILE)
end)

if settingsFileExists then
	local ok, raw = pcall(readfile, CW.Paths.SETTINGS_FILE)

	if ok then
		local ok2, data = pcall(HttpService.JSONDecode, HttpService, raw)

		if ok2 and type(data) == "table" then
			local savedVersion = tonumber(data.schemaVersion) or 1
			local values = data.Settings
			if type(values) ~= "table" then
				values = {}
				local legacyFlags = {
					Hitmarker_Size = "HITMARKER_SIZE",
					Hitmarker_RandomRotation = "HITMARKER_RANDOM_ROTATION",
					Hitmarker_FollowMouse = "HITMARKER_FOLLOW_MOUSE",
					Hitmarker_VisibleDuration = "HITMARKER_VISIBLE_DURATION",
					Hitmarker_Fadeout = "HITMARKER_FADEOUT",
					Hitmarker_FadeoutDuration = "HITMARKER_FADEOUT_DURATION",
					Cursor_Size = "CURSOR_TARGET_SIZE",
					Sound_Volume = "SOUND_VOLUME",
					Tracer_ApplyToOthers = "TRACER_APPLY_TO_OTHERS",
					Sprint_ToggleEnabled = "SHIFT_TOGGLE_ENABLED",
					Chat_ToggleEnabled = "CHAT_TOGGLE_ENABLED",
					AutoReload_Enabled = "AUTO_RELOAD_ENABLED",
					WeaponSoundOverrides_Enabled = "WEAPON_SOUND_OVERRIDE_ENABLED",
					WeaponSoundOverrides_Others = "WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS",
				}
				for flag, key in pairs(legacyFlags) do
					local entry = data[flag]
					if type(entry) == "table" then values[key] = entry[2] end
				end
			end

			-- Files written before schema 3 stored every setting, including toggles that used to be
			-- ON by default. Those toggles are now OFF by default, so the old values are dropped once.
			if savedVersion < 3 then
				local reset = {}
				for _, key in ipairs({
					"AUTO_RELOAD_ENABLED", "WEAPON_SOUND_OVERRIDE_ENABLED", "HITMARKER_RANDOM_ROTATION",
					"HITMARKER_FOLLOW_MOUSE", "HITMARKER_FADEOUT",
				}) do
					if values[key] ~= nil then
						values[key] = nil
						table.insert(reset, key)
					end
				end
				if #reset > 0 then
					CW.Warn("Settings are now off by default. Reset once from the old save: " .. table.concat(reset, ", ") .. ". Turn on what you want; it will be saved.")
				end
			end

			CW._SavedSettings = values
			for key, value in pairs(values) do
				local current = CW.Settings[key]
				if type(current) == type(value) and type(value) ~= "table" then
					CW.Settings[key] = value
				elseif type(current) == "table" and type(value) == "table" then
					CW.Settings[key] = value
				end
			end

			local selections = data.AssetSelections
			if type(selections) == "table" then
				for _, key in ipairs({ "Cursor", "Hitmarker", "HitSound" }) do
					if type(selections[key]) == "string" then
						CW.Settings.ASSET_SELECTIONS[key] = selections[key]
					end
				end
				for _, key in ipairs({ "Textures", "Meshes" }) do
					if type(selections[key]) == "table" then CW.Settings.ASSET_SELECTIONS[key] = selections[key] end
				end
			end

			CW.Log("Loaded saved UI settings and asset selections")
		end
	end
end

-- Cursor colors saved by an older build as hex (Color3 can't go into JSON). They are only read once, to
-- become the profile of the cursor in use (CW.Profiles.start).
for _, key in ipairs({ "CURSOR_ENEMY_COLOR", "CURSOR_TEAM_COLOR" }) do
	local hex = CW._SavedSettings[key .. "_HEX"]
	local ok, color = pcall(Color3.fromHex, type(hex) == "string" and hex or "")
	if ok and typeof(color) == "Color3" then CW.Settings[key] = color end
end

--// Per-asset settings -------------------------------------------------------------------------------------
-- Each cursor, hitmarker and hit sound keeps its own settings, saved in ASSET_PROFILES under its category and
-- its library path ("Cursors/arrow.png", or "id:123" for a custom ID). CW.Settings.<key> always holds the values
-- of the asset in use, so the code that draws the cursor or the hitmarker reads them as before. Choosing another
-- asset loads its profile, or the defaults when it has none; a profile only keeps what differs from the defaults.
CW.Profiles = {
	keys = {
		Cursors = { "CURSOR_TARGET_SIZE", "CURSOR_TEAM_CHECK", "CURSOR_ENEMY_COLOR", "CURSOR_TEAM_COLOR" },
		Hitmarkers = {
			"HITMARKER_SIZE", "HITMARKER_RANDOM_ROTATION", "HITMARKER_FOLLOW_MOUSE", "HITMARKER_FADEOUT",
			"HITMARKER_VISIBLE_DURATION", "HITMARKER_FADEOUT_DURATION",
		},
		HitSounds = { "SOUND_VOLUME" },
	},
	current = {},   -- [category] = library path of the asset in use
	listeners = {}, -- [category] = function() the UI shows the values again
	isKey = {},     -- these settings are saved per asset, never in the shared list
}
for _, keys in pairs(CW.Profiles.keys) do
	for _, key in ipairs(keys) do CW.Profiles.isKey[key] = true end
end

local function differsFromDefault(key, value)
	local default = CW.Defaults[key]
	if typeof(value) == "Color3" then return typeof(default) ~= "Color3" or value:ToHex() ~= default:ToHex() end
	if type(value) == "number" and type(default) == "number" then return math.abs(value - default) > 1e-6 end
	return value ~= default
end

-- Makes `relative` the asset in use: its saved values (or the defaults) go into CW.Settings.
function CW.Profiles.use(category, relative)
	CW.Profiles.current[category] = relative
	local all = CW.Settings.ASSET_PROFILES[category]
	local profile = relative and type(all) == "table" and all[relative] or nil
	for _, key in ipairs(CW.Profiles.keys[category]) do
		local default, saved = CW.Defaults[key], nil
		if type(profile) == "table" then saved = profile[key] end -- not `and/or`: a saved false must stay false
		local value = default
		if typeof(default) == "Color3" then
			local ok, color = pcall(Color3.fromHex, type(saved) == "string" and saved or "")
			if ok and typeof(color) == "Color3" then value = color end
		elseif type(saved) == type(default) then
			value = saved
		end
		CW.Settings[key] = value
	end
	local listener = CW.Profiles.listeners[category]
	if listener then pcall(listener) end
end

-- Saves the values in CW.Settings as the profile of the asset in use. Called by every control of that asset.
function CW.Profiles.store(category)
	local relative = CW.Profiles.current[category]
	if not relative then return end
	local profiles = CW.Settings.ASSET_PROFILES
	local profile = {}
	for _, key in ipairs(CW.Profiles.keys[category]) do
		local value = CW.Settings[key]
		if differsFromDefault(key, value) then
			profile[key] = typeof(value) == "Color3" and value:ToHex() or value
		end
	end
	profiles[category] = type(profiles[category]) == "table" and profiles[category] or {}
	profiles[category][relative] = next(profile) and profile or nil
	if next(profiles[category]) == nil then profiles[category] = nil end
end

-- First use of a category: settings saved by an older build (shared by every asset) become the profile of the
-- asset in use, so nothing the player set is lost. Then that asset's profile is loaded as usual.
function CW.Profiles.start(category, relative)
	if CW.Settings.ASSET_PROFILES[category] == nil and relative then
		CW.Profiles.current[category] = relative
		CW.Profiles.store(category)
	end
	CW.Profiles.use(category, relative)
end

do
	local loc = UserInputService:GetMouseLocation()
	CW.State.mouseX, CW.State.mouseY = loc.X, loc.Y
end

-- Created on every run and registered with CW.track: a re-run replaces the previous connections.
do
	CW.track("mouseMove", UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		if next(CW.ActiveFollowClones) == nil then return end -- nothing to move

		local inset = GuiService:GetGuiInset()

		CW.State.mouseX = input.Position.X + inset.X
		CW.State.mouseY = input.Position.Y + inset.Y

		for clone in pairs(CW.ActiveFollowClones) do
			local ok = pcall(function()
				clone.Position = UDim2.fromOffset(
					CW.State.mouseX,
					CW.State.mouseY
				)
			end)

			if not ok then
				CW.ActiveFollowClones[clone] = nil
			end
		end
	end))
end

runModule("Cache", function()
-- Cache.lua
local CW = getgenv().__CW_CORE_STATE

local sbyte   = string.byte
local sformat = string.format
local band    = bit32.band
local bxor    = bit32.bxor
local rshift  = bit32.rshift

local ALL_FOLDERS = {
	CW.Paths.CURSOR_ROOT,
	CW.Paths.LIBRARY_ROOT,
	CW.Paths.CURSORS_FOLDER,
	CW.Paths.CURSORS_FOLDER.."/"..CW.Paths.OFFICIAL_FOLDER,
	CW.Paths.HITMARKERS_FOLDER,
	CW.Paths.HITMARKERS_FOLDER.."/"..CW.Paths.OFFICIAL_FOLDER,
	CW.Paths.HIT_SOUNDS_FOLDER,
	CW.Paths.HIT_SOUNDS_FOLDER.."/"..CW.Paths.OFFICIAL_FOLDER,
	CW.Paths.WEAPON_SOUNDS_FOLDER,
	CW.Paths.RELOAD_SOUNDS_FOLDER,
	CW.Paths.TEXTURES_FOLDER,
	CW.Paths.CACHE_FOLDER,
	CW.Paths.GENERATED_FOLDER,
	CW.Paths.TINTED_FOLDER,
	CW.Paths.AUDIO_COPIES_FOLDER,
}

function CW.ensureFolders()
	for _, folder in ipairs(ALL_FOLDERS) do
		if not isfolder(folder) then
			pcall(makefolder, folder)
		end
	end
end
CW.ensureFolders()

-- Cooperative yielding for heavy loops (PNG codec, checksums) so the game never freezes.
local lastYield = os.clock()
function CW.yieldBudget()
	if os.clock() - lastYield > 0.008 then
		task.wait()
		lastYield = os.clock()
	end
end

function CW.readSigFile(path)
	if not isfile(path) then return nil end
	local ok, data = pcall(readfile, path)
	if ok then return data end
	return nil
end

function CW.pruneOldFiles(folder, prefix, keepHash, label)
	local ok, files = pcall(listfiles, folder)
	if not ok or not files then return end
	local deleted = 0
	for _, path in ipairs(files) do
		local name = path:match("([^/\\]+)$")
		if name and name:sub(1, #prefix) == prefix and not name:find(keepHash, 1, true) then
			if pcall(delfile, path) then deleted = deleted + 1 end
		end
	end
	if deleted > 0 then
		CW.Log(sformat("Pruned %d stale %s file(s)", deleted, label))
	end
end

if not CW._crcT then
	local t = {}
	for i = 0, 255 do
		local c = i
		for _ = 1, 8 do
			c = band(c, 1) == 1
				and bxor(0xEDB88320, rshift(c, 1))
				or  rshift(c, 1)
		end
		t[i] = c
	end
	CW._crcT = t
end
local _crcT = CW._crcT

-- Eight bytes per step (slicing-by-8): the same checksum about twice as fast as one byte at a time, which
-- matters on a first start, when every downloaded file (9 MB of them) is checked. T[k][i] is the table for
-- the byte k places before the end of the eight. Needs the buffer library; without it, one byte at a time.
local crcSlices
if type(buffer) == "table" and type(buffer.readu32) == "function" then
	crcSlices = { [0] = _crcT }
	for k = 1, 7 do
		local previous, current = crcSlices[k - 1], {}
		for i = 0, 255 do current[i] = bxor(rshift(previous[i], 8), _crcT[band(previous[i], 0xFF)]) end
		crcSlices[k] = current
	end
end

local function crc32Of(s, yielding)
	local c = 0xFFFFFFFF
	local length = #s
	if not crcSlices then
		for i = 1, length do
			c = bxor(_crcT[band(bxor(c, sbyte(s, i)), 0xFF)], rshift(c, 8))
			if yielding and i % 65536 == 0 then CW.yieldBudget() end
		end
		return bxor(c, 0xFFFFFFFF)
	end
	local T0, T1, T2, T3 = crcSlices[0], crcSlices[1], crcSlices[2], crcSlices[3]
	local T4, T5, T6, T7 = crcSlices[4], crcSlices[5], crcSlices[6], crcSlices[7]
	local readu32, readu8 = buffer.readu32, buffer.readu8
	local bytes = buffer.fromstring(s)
	local i, last = 0, length - 8
	while i <= last do
		local low = bxor(c, readu32(bytes, i))
		local high = readu32(bytes, i + 4)
		c = bxor(T7[band(low, 255)], T6[band(rshift(low, 8), 255)], T5[band(rshift(low, 16), 255)], T4[rshift(low, 24)],
			T3[band(high, 255)], T2[band(rshift(high, 8), 255)], T1[band(rshift(high, 16), 255)], T0[rshift(high, 24)])
		i += 8
		if yielding and i % 65536 == 0 then CW.yieldBudget() end
	end
	while i < length do
		c = bxor(T0[band(bxor(c, readu8(bytes, i)), 255)], rshift(c, 8))
		i += 1
	end
	return bxor(c, 0xFFFFFFFF)
end

function CW.crc32(s) return crc32Of(s, false) end

-- Same result as CW.crc32, but hands the thread back to the game now and then. Only call it
-- from a thread that is allowed to yield (the sync thread, a task.spawn, the executor thread).
function CW.crc32Yielding(s) return crc32Of(s, true) end

function CW.computeFileSignature(path, prefix, extra)
	extra = extra or ""
	if not path or not isfile(path) then
		return prefix..":none"..extra, nil
	end
	local ok, data = pcall(readfile, path)
	if not ok or not data then
		return prefix..":readfail"..extra, nil
	end
	return prefix..":"..CW.crc32(data)..extra, data
end

function CW.loadLibraryAsset(cfg)
	-- A custom ID (added in the UI) is already an engine asset: nothing to read from disk.
	if type(cfg.file) == "string" and cfg.file:match("^rbxassetid://%d+$") then
		CW.Log(cfg.label .. " uses Roblox asset " .. cfg.file)
		return cfg.file, nil
	end
	if not cfg.file or not isfile(cfg.file) then
		CW.Log(cfg.label .. " file not found in the asset library")
		return nil, "missing"
	end

	local ok, asset, reason
	if cfg.audio and CW.Library and CW.Library.audioAsset then
		-- Audio goes through the library: format detected by content, compatibility copy if needed.
		ok, asset, reason = pcall(CW.Library.audioAsset, cfg.file)
		if ok and not asset then ok, asset = false, reason end
	else
		ok, asset = pcall(getcustomasset, cfg.file)
	end
	if not ok or not asset then
		CW.Warn("Could not load " .. cfg.label .. ": " .. tostring(asset))
		return nil, "error"
	end

	CW.Log(cfg.label .. " loaded from " .. cfg.file)
	return asset, nil
end
end)


runModule("AssetLibrary", function()
-- AssetLibrary.lua
local CW = getgenv().__CW_CORE_STATE
local HttpService = game:GetService("HttpService")

local CATEGORY_INFO = {
	Cursors = { folder = CW.Paths.CURSORS_FOLDER, extensions = { png = true } },
	Hitmarkers = { folder = CW.Paths.HITMARKERS_FOLDER, extensions = { png = true } },
	HitSounds = { folder = CW.Paths.HIT_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
}
local SELECTION_KEYS = {
	Cursors = "Cursor",
	Hitmarkers = "Hitmarker",
	HitSounds = "HitSound",
}
-- Categories stored per weapon: <category>/<Weapon>/<file>. The weapon names are the same
-- ones the Textures folders use.
local WEAPON_CATEGORIES = {
	Textures = { folder = CW.Paths.TEXTURES_FOLDER, extensions = { png = true } },
	WeaponSounds = { folder = CW.Paths.WEAPON_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
	ReloadSounds = { folder = CW.Paths.RELOAD_SOUNDS_FOLDER, extensions = { mp3 = true, ogg = true, wav = true, flac = true }, audio = true },
}
local ASSET_EXTENSIONS = { png = true, mp3 = true, ogg = true, wav = true, flac = true }
local AUDIO_FORMATS = { mp3 = true, ogg = true, wav = true, flac = true }

local function ensureFolderPath(path)
	local current = ""
	for segment in path:gmatch("[^/]+") do
		current = current == "" and segment or current .. "/" .. segment
		local exists = false
		pcall(function() exists = isfolder(current) end)
		if not exists then pcall(makefolder, current) end
	end
end

local function validWeaponName(weapon)
	return type(weapon) == "string"
		and weapon ~= "." and weapon ~= ".."
		and weapon:match("^[%w_%-%. ]+$") ~= nil
end

local function validManifestPath(category, path)
	if type(path) ~= "string" or path:find("\\", 1, true) or path:match("^/") then return false end
	for segment in path:gmatch("[^/]+") do
		if segment == "." or segment == ".." or segment:find("[%c]") then return false end
	end
	local extension = path:match("%.([%w]+)$")
	if not extension then return false end
	extension = extension:lower()
	local info = CATEGORY_INFO[category]
	if info then
		return path:match("^" .. category .. "/[^/]+$") ~= nil
			and info.extensions[extension] == true
	end
	local weaponInfo = WEAPON_CATEGORIES[category]
	if weaponInfo then
		return path:match("^" .. category .. "/[^/]+/[^/]+$") ~= nil
			and weaponInfo.extensions[extension] == true
	end
	return false
end

local function detectAssetFormat(data)
	if type(data) ~= "string" or #data < 4 then return "empty or truncated" end

	if data:sub(1, 8) == "\137\80\78\71\13\10\26\10" then return "png" end
	if data:sub(1, 4) == "MM\0\42" or data:sub(1, 4) == "II\42\0" then return "tiff" end
	if data:sub(1, 3) == "\255\216\255" then return "jpeg" end
	if data:sub(1, 4) == "OggS" then return "ogg" end
	if data:sub(1, 3) == "ID3" then return "mp3" end
	local first, second = string.byte(data, 1, 2)
	if first == 0xFF and second and bit32.band(second, 0xE0) == 0xE0 then return "mp3" end
	if data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WAVE" then return "wav" end
	if data:sub(1, 4) == "fLaC" then return "flac" end
	if data:match("^%d%d%d:%s") then return "HTTP error response" end
	return "unknown"
end

-- Images must be PNG with a matching extension. Audio is judged by its content only: any of
-- mp3/ogg/wav/flac is accepted whatever the file is called (a WAV named .mp3 is fine).
local function isAudioCategory(category)
	local info = CATEGORY_INFO[category] or WEAPON_CATEGORIES[category]
	return info ~= nil and info.audio == true
end

local function formatMatches(category, path, actual)
	if isAudioCategory(category) then return AUDIO_FORMATS[actual] == true end
	local extension = path:match("%.([%w]+)$")
	return extension ~= nil and actual == extension:lower()
end

local invalidAssetWarnings = {}

local function libraryRelative(path)
	if type(path) ~= "string" then return nil end
	local normalized = path:gsub("\\", "/")
	local prefix = CW.Paths.LIBRARY_ROOT .. "/"
	if normalized:sub(1, #prefix) == prefix then
		return normalized:sub(#prefix + 1)
	end
	local marker = "/" .. prefix
	local markerIndex = normalized:find(marker, 1, true)
	if markerIndex then return normalized:sub(markerIndex + #marker) end
	return nil
end

CW.Library = {}
CW.Library.ensureFolder = ensureFolderPath

-- Directory scans read and validate every file, so the result is cached per category/weapon.
-- The cache is cleared whenever the library can have changed (CW.Library.sync).
local listCache = {}
local audioAssetCache, audioPending = {}, {}

function CW.Library.invalidate()
	table.clear(listCache)
	table.clear(audioAssetCache)
end

-- The official files the sync checked (format and checksum) when it saved or verified them:
-- library-relative path -> { crc = "xxxxxxxx", size = bytes }. A file listed here is not read again to
-- learn its format (scanLibrary), and the sync only compares its size (the checksum, computed in Luau,
-- was most of the work of every start).
local libraryIndex = {}
do
	local ok, text = pcall(readfile, CW.Paths.LIBRARY_INDEX_FILE)
	local decoded, data = false, nil
	if ok and type(text) == "string" then decoded, data = pcall(HttpService.JSONDecode, HttpService, text) end
	if decoded and type(data) == "table" and type(data.files) == "table" then
		for relative, info in pairs(data.files) do
			if type(relative) == "string" and type(info) == "table" and type(info.crc) == "string" and tonumber(info.size) then
				libraryIndex[relative] = { crc = info.crc, size = tonumber(info.size) }
			end
		end
	end
end
local function saveLibraryIndex()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, { schemaVersion = 1, files = libraryIndex })
	if ok then pcall(writefile, CW.Paths.LIBRARY_INDEX_FILE, encoded) end
end

local function scanLibrary(category, weapon)
	local info = CATEGORY_INFO[category]
	local weaponInfo = WEAPON_CATEGORIES[category]
	local directories = {}
	if info then
		table.insert(directories, info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, info.folder)
	elseif weaponInfo and type(weapon) == "string" then
		local weaponFolder = weaponInfo.folder .. "/" .. weapon
		table.insert(directories, weaponFolder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
		table.insert(directories, weaponFolder)
	else
		return nil
	end

	local extensions = (info or weaponInfo).extensions
	local result = {}
	for directoryIndex, directory in ipairs(directories) do
		local official = directoryIndex == 1 -- the _Official folder comes first
		local ok, files = pcall(listfiles, directory)
		if ok and type(files) == "table" then
			for _, filePath in ipairs(files) do
				local normalized = tostring(filePath):gsub("\\", "/")
				local filename = normalized:match("([^/]+)$") or normalized
				local extension = filename:match("%.([%w]+)$")
				if extension and extensions[extension:lower()] then
					local relative = libraryRelative(normalized)
					if relative then
						local actualFormat = "checked"
						if not (official and libraryIndex[relative]) then
							local okData, data = pcall(readfile, normalized)
							actualFormat = okData and detectAssetFormat(data) or "unreadable"
						end
						if actualFormat == "checked" or formatMatches(category, normalized, actualFormat) then
							table.insert(result, {
								Name = filename:gsub("%.[%w]+$", ""),
								Path = CW.Paths.LIBRARY_ROOT .. "/" .. relative,
								Relative = relative,
							})
						elseif not invalidAssetWarnings[normalized] then
							invalidAssetWarnings[normalized] = true
							CW.Warn("Skipped invalid library asset " .. relative .. " (expected " .. (isAudioCategory(category) and "audio" or extension:lower()) .. ", detected " .. actualFormat .. ")")
						end
					end
				end
			end
		end
	end
	table.sort(result, function(left, right)
		return left.Relative:lower() < right.Relative:lower()
	end)
	return result
end

function CW.Library.list(category, weapon)
	-- (the weapon only picks a folder in the per-weapon categories; HitSounds files are shared by every gun)
	local key = tostring(category) .. "|" .. (WEAPON_CATEGORIES[category] and tostring(weapon) or "")
	local cached = listCache[key]
	if not cached then
		cached = scanLibrary(category, weapon)
		if not cached then return {} end
		listCache[key] = cached
	end
	local copy = table.create and table.create(#cached) or {}
	for index, item in ipairs(cached) do
		copy[index] = { Name = item.Name, Path = item.Path, Relative = item.Relative }
	end
	return copy
end

--// Audio assets ------------------------------------------------------------------------
-- getcustomasset decides how to decode a local file from its NAME, so a WAV called .mp3 (or a
-- format the engine only accepts under another name) can fail. For those files a copy is
-- written to the cache folder with a name that works; the original is never touched.
-- Which name works is found once per audio format by loading the copy and checking that the
-- sound has a length (real extension first, then .mp3, then .ogg); the result is remembered
-- in audio_probe.json, so nothing is guessed on later runs. mp3/ogg files with a matching
-- name are played directly, with no probe and no copy.
local STANDARD_AUDIO = { mp3 = true, ogg = true }
local MAX_AUDIO_BYTES = 20 * 1024 * 1024 -- Roblox's documented limit for audio files
local audioWarned = {}
local audioProbe

local function warnAudioOnce(key, message)
	if audioWarned[key] then return end
	audioWarned[key] = true
	CW.Warn(message)
end

local function loadAudioProbe()
	if audioProbe then return audioProbe end
	audioProbe = {}
	local okExists, exists = pcall(isfile, CW.Paths.AUDIO_PROBE_FILE)
	if okExists and exists then
		local okRead, raw = pcall(readfile, CW.Paths.AUDIO_PROBE_FILE)
		if okRead then
			local decoded, data = pcall(HttpService.JSONDecode, HttpService, raw)
			if decoded and type(data) == "table" then
				for format, extension in pairs(data) do
					if AUDIO_FORMATS[format] and AUDIO_FORMATS[extension] then audioProbe[format] = extension end
				end
			end
		end
	end
	return audioProbe
end

local function saveAudioProbe()
	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, audioProbe or {})
	if ok then pcall(writefile, CW.Paths.AUDIO_PROBE_FILE, encoded) end
end

-- True when the engine can load the asset as a sound with a length above zero.
local function audioLoads(asset)
	local ok, loaded = pcall(function()
		local sound = Instance.new("Sound")
		sound.Volume = 0
		sound.SoundId = asset
		sound.Parent = game:GetService("SoundService")
		local done = false
		task.spawn(function()
			pcall(function() game:GetService("ContentProvider"):PreloadAsync({ sound }) end)
			done = true
		end)
		local deadline = os.clock() + 4
		while not done and os.clock() < deadline do task.wait(0.05) end
		local settle = os.clock() + 0.5
		while sound.TimeLength <= 0 and os.clock() < settle do task.wait(0.05) end
		local length = sound.TimeLength
		sound:Destroy()
		return length > 0
	end)
	return ok and loaded == true
end

local function audioCopyPath(path, data, extension)
	local name = path:match("([^/\\]+)$") or "audio"
	name = name:gsub("%.[%w]+$", "")
	name = name:gsub("[^%w_%-]", "_")
	return CW.Paths.AUDIO_COPIES_FOLDER .. "/" .. string.format("%08x", CW.crc32Yielding(data)) .. "_" .. name .. "." .. extension
end

local function compatAudioAsset(path, data, format, originalExtension)
	local probe = loadAudioProbe()
	local known = probe[format] ~= nil
	local candidates = {}
	if known then
		candidates[1] = probe[format]
	else
		for _, extension in ipairs({ format, "mp3", "ogg" }) do
			if not table.find(candidates, extension) then table.insert(candidates, extension) end
		end
	end

	CW.Library.ensureFolder(CW.Paths.AUDIO_COPIES_FOLDER)
	for _, extension in ipairs(candidates) do
		local target = path
		if extension ~= originalExtension then
			target = audioCopyPath(path, data, extension)
			local okFile, exists = pcall(isfile, target)
			if not (okFile and exists) then
				if not pcall(writefile, target, data) then target = nil end
			end
		end
		if target then
			local okAsset, asset = pcall(getcustomasset, target)
			if okAsset and type(asset) == "string" and (known or audioLoads(asset)) then
				if not known then
					probe[format] = extension
					saveAudioProbe()
					CW.Log("Audio probe: " .. format .. " files load as ." .. extension .. " on this executor")
				end
				return asset
			end
			-- This name did not work: do not leave its copy behind.
			if target ~= path and not known then pcall(delfile, target) end
		end
	end
	if known then
		probe[format] = nil -- the remembered name stopped working: probe again next time
		saveAudioProbe()
	end
	return nil
end

-- Returns the asset id for an audio file, or nil plus the reason.
function CW.Library.audioAsset(path)
	if type(path) ~= "string" then return nil, "invalid path" end
	local cached = audioAssetCache[path]
	if cached then return cached end
	-- Another thread is already preparing this file: wait for it, but not forever (a cancelled
	-- thread never clears its flag).
	local waitDeadline = os.clock() + 60
	while audioPending[path] do
		if os.clock() > waitDeadline then return nil, "timed out waiting for another load of this file" end
		task.wait(0.05)
	end
	cached = audioAssetCache[path]
	if cached then return cached end

	audioPending[path] = true
	local ok, asset, reason = pcall(function()
		local okRead, data = pcall(readfile, path)
		if not okRead or type(data) ~= "string" then return nil, "unreadable" end
		local format = detectAssetFormat(data)
		if not AUDIO_FORMATS[format] then return nil, "not an audio file (detected " .. format .. ")" end
		if #data > MAX_AUDIO_BYTES then
			warnAudioOnce(path, (CW.Library.relative(path) or path) .. " is larger than 20 MB; Roblox may refuse to play it")
		end

		local originalExtension = (path:match("%.([%w]+)$") or ""):lower()
		if STANDARD_AUDIO[format] and originalExtension == format then
			local okAsset, direct = pcall(getcustomasset, path)
			if okAsset and direct then return direct end
			return nil, tostring(direct)
		end

		local compat = compatAudioAsset(path, data, format, originalExtension)
		if compat then return compat end

		-- Last resort: the original file, as is.
		local okAsset, direct = pcall(getcustomasset, path)
		if okAsset and direct then
			warnAudioOnce("fallback|" .. path, "Could not verify that " .. (CW.Library.relative(path) or path) .. " plays as " .. format .. "; using the original file")
			return direct
		end
		return nil, tostring(direct)
	end)
	audioPending[path] = nil

	if ok and asset then
		audioAssetCache[path] = asset
		return asset
	end
	return nil, ok and reason or tostring(asset)
end

--// Custom asset IDs ------------------------------------------------------------------
-- Roblox asset IDs the player adds in the UI, saved in CycleWare/custom_ids.json:
--   { "schemaVersion": 2,
--     "Hitmarkers": [ { "Name": "Pop", "Id": "123" } ],           one list
--     "WeaponSounds": { "AK-47": [ { "Name": "...", "Id": "..." } ] }   one list per gun
--     (HitSounds, ReloadSounds, Textures and Meshes are per gun as well) }
-- An ID is listed next to the library files of its category (and gun), and choosing it is saved
-- like a file choice, as "id:<number>".
-- A mesh ID also keeps what was found behind it when it was added (see CW.resolveMeshAsset): Mesh (the mesh
-- asset shown; another ID when the ID was an accessory or a model) and Texture (the texture that came with it),
-- and how the player adjusted it on that gun: Adjust = { Size, Right, Up, Forward, Turn, Tilt, Roll } (only the
-- fields away from their default; see MESH_ADJUST).
-- Without the file functions (CAPS.files) the IDs still work, but only until the player rejoins.
local CUSTOM_ID_CATEGORIES = { -- true = one list per gun
	Hitmarkers = false, Cursors = false,
	HitSounds = true, Textures = true, WeaponSounds = true, ReloadSounds = true, Meshes = true,
}
-- A list saved before its category was per gun (HitSounds was one list for every gun): it becomes the start
-- of each gun's own list once the guns are known (CW.CustomIds.splitPerGun).
local legacyLists = {}
-- Categories whose IDs are downloaded into a real library file (the cursor needs the PNG's pixels to
-- make its tinted copies). Their entries also keep File = "<Category>/<name>.png", and they are listed
-- through that file, not as an rbxassetid item.
local DOWNLOADED_CATEGORIES = { Cursors = true }
local CUSTOM_ID_LIMIT = 200      -- per list
local CUSTOM_NAME_LIMIT = 40     -- characters

CW.CustomIds = {}
-- Kept in the shared state, so a re-run without file functions does not lose what was added.
if type(CW.State.customIdLists) ~= "table" or CW.State.customIdLists.schemaVersion ~= 2 then
	CW.State.customIdLists = { schemaVersion = 2 }
end
local customLists = CW.State.customIdLists

-- Accepts a bare number or the usual ways an ID is pasted: rbxassetid://123, a roblox.com asset
-- link (?id=123, /library/123/..., /catalog/123/..., /asset/123). Returns the ID as a string, or nil.
local function parseAssetId(value)
	if type(value) == "number" then
		if value ~= value or value < 1 or value >= 2 ^ 53 then return nil end
		value = string.format("%d", value)
	end
	if type(value) ~= "string" then return nil end
	value = value:match("^%s*(.-)%s*$")
	local id = value:match("^(%d+)$")
		or value:match("^rbxassetid://(%d+)$")
		or value:match("[?&][iI][dD]=(%d+)")
		or value:match("/library/(%d+)")
		or value:match("/catalog/(%d+)")
		or value:match("/asset/(%d+)")
	if not id then return nil end
	id = id:gsub("^0+", "")
	if id == "" or #id > 19 then return nil end
	return id
end
CW.CustomIds.parse = parseAssetId

local function cleanName(name, id)
	name = type(name) == "string" and name:gsub("[%c]", ""):match("^%s*(.-)%s*$") or ""
	if name == "" then name = id end -- no name given: it is named after its ID
	if utf8.len(name) and utf8.len(name) > CUSTOM_NAME_LIMIT then
		name = name:sub(1, utf8.offset(name, CUSTOM_NAME_LIMIT + 1) - 1)
	end
	return name
end

-- The list of one category (and gun, for the per-gun categories); nil when there is none.
local function listOf(category, weapon, create)
	local perGun = CUSTOM_ID_CATEGORIES[category]
	if perGun == nil then return nil end
	if perGun then
		if not validWeaponName(weapon) then return nil end
		local byGun = customLists[category]
		if type(byGun) ~= "table" then
			if not create then return nil end
			byGun = {}
			customLists[category] = byGun
		end
		local list = byGun[weapon]
		if type(list) ~= "table" then
			if not create then return nil end
			list = {}
			byGun[weapon] = list
		end
		return list
	end
	local list = customLists[category]
	if type(list) ~= "table" then
		if not create then return nil end
		list = {}
		customLists[category] = list
	end
	return list
end

local function copyEntry(entry)
	return {
		Name = entry.Name, Id = entry.Id, File = entry.File, Mesh = entry.Mesh, Texture = entry.Texture,
		Adjust = entry.Adjust and table.clone(entry.Adjust) or nil,
	}
end

local function copyEntries(source)
	local entries = {}
	for _, entry in ipairs(source) do table.insert(entries, copyEntry(entry)) end
	return entries
end

-- How a custom mesh can be adjusted on its gun: { lowest, highest, default } of each field. Size multiplies the
-- size it is fitted to; Right, Up and Forward move it (studs, along the gun); Turn, Tilt and Roll turn it (degrees,
-- positive = to the right, nose up, rolled to the right).
local MESH_ADJUST = {
	Size = { 0.1, 4, 1 },
	Right = { -2, 2, 0 }, Up = { -2, 2, 0 }, Forward = { -2, 2, 0 },
	Turn = { -180, 180, 0 }, Tilt = { -180, 180, 0 }, Roll = { -180, 180, 0 },
}
CW.MeshAdjust = MESH_ADJUST

-- An Adjust table checked: numbers in range, fields at their default left out (nil when nothing is left).
local function cleanAdjust(source)
	local adjust = {}
	for field, limits in pairs(MESH_ADJUST) do
		local value = type(source) == "table" and tonumber(source[field])
		if value and value == value then
			value = math.clamp(value, limits[1], limits[2])
			if math.abs(value - limits[3]) > 1e-6 then adjust[field] = value end
		end
	end
	return next(adjust) and adjust or nil
end

-- The mesh fields of an entry, checked: IDs as digits, the Adjust table in range. Facing, from the first
-- version of the mesh list (1 turned around, 2 upside down, 3 both), becomes Turn and Roll.
local function meshFields(source)
	local adjust = type(source.Adjust) == "table" and table.clone(source.Adjust) or {}
	local facing = tonumber(source.Facing)
	if facing == 1 or facing == 3 then adjust.Turn = adjust.Turn or 180 end
	if facing == 2 or facing == 3 then adjust.Roll = adjust.Roll or 180 end
	return { Mesh = parseAssetId(source.Mesh), Texture = parseAssetId(source.Texture), Adjust = cleanAdjust(adjust) }
end

-- A downloaded file must stay inside its own category folder, outside the official one.
local function validDownloadedFile(category, file)
	return type(file) == "string"
		and file:sub(1, #category + 1) == category .. "/"
		and not file:find("..", 1, true) and not file:find("\\", 1, true)
		and not file:find("/" .. CW.Paths.OFFICIAL_FOLDER .. "/", 1, true)
		and file:match("^[^/]+/[^/]+%.png$") ~= nil
end

local saveWarned = false
function CW.CustomIds.save()
	if not CAPS.files then
		if not saveWarned then
			saveWarned = true
			CW.Warn("File functions are missing: custom IDs work now but are not saved after you rejoin")
		end
		return false
	end
	local data = { schemaVersion = 2 }
	for category, perGun in pairs(CUSTOM_ID_CATEGORIES) do
		local stored = customLists[category]
		if perGun then
			local byGun = {}
			for weapon, list in pairs(type(stored) == "table" and stored or {}) do
				if #list > 0 then byGun[weapon] = copyEntries(list) end
			end
			if next(byGun) then data[category] = byGun end
		elseif type(stored) == "table" and #stored > 0 then
			data[category] = copyEntries(stored)
		end
	end
	local okEncode, json = pcall(HttpService.JSONEncode, HttpService, data)
	if not okEncode then
		CW.Warn("Could not encode custom IDs: " .. tostring(json))
		return false
	end
	local okWrite, err = pcall(writefile, CW.Paths.CUSTOM_IDS_FILE, json)
	if not okWrite then
		CW.Warn("Could not save " .. CW.Paths.CUSTOM_IDS_FILE .. ": " .. tostring(err))
		return false
	end
	return true
end

-- Valid, unique entries of a list read from the file.
local function sanitizeList(source, category)
	local loaded, seen = {}, {}
	if type(source) ~= "table" then return loaded end
	local downloaded = DOWNLOADED_CATEGORIES[category]
	for _, entry in ipairs(source) do
		local id = type(entry) == "table" and parseAssetId(entry.Id)
		local fileOk = not downloaded or validDownloadedFile(category, entry.File)
		if id and fileOk and not seen[id] and #loaded < CUSTOM_ID_LIMIT then
			seen[id] = true
			local clean = { Name = cleanName(entry.Name, id), Id = id, File = downloaded and entry.File or nil }
			if category == "Meshes" then
				local fields = meshFields(entry)
				clean.Mesh, clean.Texture, clean.Adjust = fields.Mesh, fields.Texture, fields.Adjust
			end
			table.insert(loaded, clean)
		end
	end
	return loaded
end

-- Reads custom_ids.json. A file that cannot be read is copied to custom_ids.broken.json and the lists stay as they are.
function CW.CustomIds.load()
	if not CAPS.files then return end
	local okExists, exists = pcall(isfile, CW.Paths.CUSTOM_IDS_FILE)
	if not (okExists and exists) then return end
	local okRead, raw = pcall(readfile, CW.Paths.CUSTOM_IDS_FILE)
	local okDecode, data = false, nil
	if okRead and type(raw) == "string" then
		okDecode, data = pcall(HttpService.JSONDecode, HttpService, raw)
	end
	if not okDecode or type(data) ~= "table" then
		CW.Warn(CW.Paths.CUSTOM_IDS_FILE .. " could not be read; it was kept as custom_ids.broken.json")
		if okRead and type(raw) == "string" then
			pcall(writefile, CW.Paths.CURSOR_ROOT .. "/custom_ids.broken.json", raw)
		end
		return
	end
	for category, perGun in pairs(CUSTOM_ID_CATEGORIES) do
		local source = data[category]
		if perGun then
			local byGun = {}
			-- A map of gun -> list; a plain list is from before the category was per gun.
			if type(source) == "table" and source[1] ~= nil then
				legacyLists[category] = sanitizeList(source, category)
			elseif type(source) == "table" then
				for weapon, list in pairs(source) do
					if validWeaponName(weapon) then
						local loaded = sanitizeList(list, category)
						if #loaded > 0 then byGun[weapon] = loaded end
					end
				end
			end
			customLists[category] = byGun
		else
			customLists[category] = sanitizeList(source, category)
		end
	end
end

function CW.CustomIds.list(category, weapon)
	local list = listOf(category, weapon, false)
	return list and copyEntries(list) or {}
end

-- The entry whose downloaded file is this relative path (Cursors), or nil.
function CW.CustomIds.byFile(category, weapon, relative)
	for _, entry in ipairs(listOf(category, weapon, false) or {}) do
		if entry.File and entry.File == relative then return copyEntry(entry) end
	end
	return nil
end

-- The entry of one ID, or nil.
function CW.CustomIds.get(category, weapon, rawId)
	local id = parseAssetId(rawId)
	for _, entry in ipairs(listOf(category, weapon, false) or {}) do
		if entry.Id == id then return copyEntry(entry) end
	end
	return nil
end

-- Saves the file a second after the last call: a slider calls this on every step while it is dragged.
local saveThread
function CW.CustomIds.saveSoon()
	if saveThread then task.cancel(saveThread) end
	saveThread = task.delay(1, function()
		saveThread = nil
		CW.CustomIds.save()
	end)
end

-- Sets how a custom mesh is adjusted on its gun (an Adjust table, or nil for none). Returns true when the ID was
-- found.
function CW.CustomIds.setAdjust(weapon, rawId, adjust)
	local id = parseAssetId(rawId)
	for _, entry in ipairs(listOf("Meshes", weapon, false) or {}) do
		if entry.Id == id then
			entry.Adjust = cleanAdjust(adjust)
			CW.CustomIds.saveSoon()
			return true
		end
	end
	return false
end

function CW.CustomIds.has(category, weapon, rawId)
	local id = parseAssetId(rawId)
	for _, entry in ipairs(listOf(category, weapon, false) or {}) do
		if entry.Id == id then return true end
	end
	return false
end

-- Two assets of the same list can't share a name: not two custom IDs, and not a custom ID and a
-- library file (official or the player's own). Compared without case. exceptId is the ID being renamed;
-- exceptFile is a library file that belongs to it. Returns the reason when the name is taken.
function CW.CustomIds.nameTaken(category, weapon, name, exceptId, exceptFile)
	local lowered = tostring(name):lower()
	for _, entry in ipairs(listOf(category, weapon, false) or {}) do
		if entry.Id ~= exceptId and entry.Name:lower() == lowered then
			return "the name \"" .. name .. "\" is already used by ID " .. entry.Id
		end
	end
	for _, item in ipairs(CW.Library.list(category, weapon)) do
		if item.Relative ~= exceptFile and tostring(item.Name):lower() == lowered then
			return "the name \"" .. name .. "\" is already used by the library file " .. tostring(item.Relative)
		end
	end
	return nil
end

-- Adds an ID (or renames it when it is already there). Returns the entry, or nil, the reason and the
-- kind of problem ("name" when the name is taken). extra.File: the downloaded file (Cursors); extra.Mesh,
-- Texture, Adjust: what a mesh ID turned out to be and how it is adjusted (Meshes).
function CW.CustomIds.add(category, weapon, rawId, name, extra)
	if CUSTOM_ID_CATEGORIES[category] == nil then return nil, "this category has no custom IDs" end
	local id = parseAssetId(rawId)
	if not id then return nil, "not a valid asset ID" end
	local list = listOf(category, weapon, true)
	if not list then return nil, "no gun selected" end
	local downloaded = DOWNLOADED_CATEGORIES[category]
	local file = extra and extra.File
	if downloaded and not validDownloadedFile(category, file) then return nil, "invalid downloaded file" end
	local existing
	for _, entry in ipairs(list) do
		if entry.Id == id then
			existing = entry
			break
		end
	end
	if existing and downloaded then return nil, "this ID was already added", "duplicate" end
	local newName = (type(name) == "string" and name:match("%S")) and cleanName(name, id)
		or (existing and existing.Name) or cleanName(nil, id)

	local taken = CW.CustomIds.nameTaken(category, weapon, newName, existing and existing.Id, file)
	if taken then return nil, taken, "name" end

	-- What a mesh ID turned out to be; a rename passes nothing and keeps what it had.
	local function keepMeshFields(entry)
		if category ~= "Meshes" or type(extra) ~= "table" then return end
		local fields = meshFields(extra)
		entry.Mesh, entry.Texture = fields.Mesh, fields.Texture
		if extra.Adjust ~= nil then entry.Adjust = fields.Adjust end
	end

	if existing then
		existing.Name = newName
		keepMeshFields(existing)
		CW.CustomIds.save()
		return copyEntry(existing), nil
	end
	if #list >= CUSTOM_ID_LIMIT then return nil, "limit of " .. CUSTOM_ID_LIMIT .. " IDs reached" end
	local entry = { Name = newName, Id = id, File = downloaded and file or nil }
	keepMeshFields(entry)
	table.insert(list, entry)
	CW.CustomIds.save()
	return copyEntry(entry), nil
end

function CW.CustomIds.remove(category, weapon, rawId)
	local list = listOf(category, weapon, false)
	local id = parseAssetId(rawId)
	if not list or not id then return false end
	for index, entry in ipairs(list) do
		if entry.Id == id then
			table.remove(list, index)
			CW.CustomIds.save()
			return true
		end
	end
	return false
end

-- "id:123" <-> "rbxassetid://123"
-- Gives every gun that has no list yet a copy of the list saved before the category was per gun (once).
function CW.CustomIds.splitPerGun(category, guns)
	local legacy = legacyLists[category]
	if not legacy or not CUSTOM_ID_CATEGORIES[category] then return end
	legacyLists[category] = nil
	local byGun = customLists[category]
	if type(byGun) ~= "table" then
		byGun = {}
		customLists[category] = byGun
	end
	for _, gun in ipairs(guns) do
		if validWeaponName(gun) and byGun[gun] == nil and #legacy > 0 then byGun[gun] = copyEntries(legacy) end
	end
	CW.CustomIds.save()
end

function CW.CustomIds.selectionOf(id) return "id:" .. id end
function CW.CustomIds.assetOf(selection)
	local id = type(selection) == "string" and selection:match("^id:(%d+)$")
	return id and ("rbxassetid://" .. id) or nil
end

pcall(CW.CustomIds.load)

function CW.Library.relative(path)
	local id = type(path) == "string" and path:match("^rbxassetid://(%d+)$")
	if id then return "id:" .. id end
	return libraryRelative(path)
end

-- Library files plus the custom IDs of the category (and gun). Downloaded IDs (cursors) are files already.
-- An ID item has Path = "rbxassetid://<id>", Relative = "id:<id>" and CustomId = "<id>".
function CW.Library.items(category, weapon)
	local items = CW.Library.list(category, weapon)
	if DOWNLOADED_CATEGORIES[category] then return items end -- already listed as library files
	for _, entry in ipairs(listOf(category, weapon, false) or {}) do
		table.insert(items, {
			Name = entry.Name,
			Path = "rbxassetid://" .. entry.Id,
			Relative = "id:" .. entry.Id,
			CustomId = entry.Id,
		})
	end
	return items
end

-- Categories chosen per gun: ASSET_SELECTIONS.<category> = { [gun] = relative path or "id:123" }, nothing = the
-- game's own look.
local PER_GUN_SELECTIONS = { Textures = true, Meshes = true }

-- Clears the saved choice of one category (and gun) when it points at a relative path
-- (used when a custom ID is removed). The weapon sounds keep their choices in the sound changers.
function CW.Library.replaceSelectionOf(category, weapon, oldRelative, newRelative)
	local selections = CW.Settings.ASSET_SELECTIONS
	if PER_GUN_SELECTIONS[category] then
		local byGun = selections[category]
		if type(byGun) == "table" and byGun[weapon] == oldRelative then byGun[weapon] = newRelative end
		return
	end
	local key = SELECTION_KEYS[category]
	if key and selections[key] == oldRelative then selections[key] = newRelative end
end

function CW.Library.clearSelectionOf(category, weapon, relative)
	CW.Library.replaceSelectionOf(category, weapon, relative, nil)
end

function CW.Library.setSelection(category, weapon, relative)
	local selections = CW.Settings.ASSET_SELECTIONS
	if PER_GUN_SELECTIONS[category] then
		if type(selections[category]) ~= "table" then selections[category] = {} end
		selections[category][weapon] = relative
	else
		local key = SELECTION_KEYS[category]
		if key then selections[key] = relative end
	end
end

-- Returns the file to use for a category (and weapon) plus its relative path.
-- A saved selection whose file is not on disk is NOT overwritten: it stays saved and is used as soon
-- as the file exists. The cursor and the per-gun looks use nothing meanwhile, and nothing at all until
-- the player picks one (the game's own cursor and guns). The hitmarker and the hit sound need a file to
-- work, so with nothing chosen, or a chosen file that is still missing once the download finished, they
-- use the library's file named "default" (or else its first file). That fallback is never saved as a
-- selection, and a custom ID is never picked on its own.
local NEEDS_A_FILE = { Hitmarkers = true, HitSounds = true }
function CW.Library.selectedPath(category, weapon)
	local selections = CW.Settings.ASSET_SELECTIONS
	local selected
	if PER_GUN_SELECTIONS[category] then
		selected = type(selections[category]) == "table" and selections[category][weapon] or nil
	else
		local key = SELECTION_KEYS[category]
		selected = key and selections[key]
	end
	if selected == "" then selected = nil end
	for _, item in ipairs(CW.Library.items(category, weapon)) do
		if item.Relative == selected then return item.Path, item.Relative end
	end
	if not NEEDS_A_FILE[category] then return nil, nil end
	if selected ~= nil and not CW.State.syncFinished then return nil, nil end -- still downloading

	local files = CW.Library.list(category, weapon)
	for _, item in ipairs(files) do
		if tostring(item.Name):lower() == "default" then return item.Path, item.Relative end
	end
	local first = files[1]
	if not first then return nil, nil end
	return first.Path, first.Relative
end

local function officialDestination(category, relativePath)
	local weaponInfo = WEAPON_CATEGORIES[category]
	if weaponInfo then
		local weapon, filename = relativePath:match("^" .. category .. "/([^/]+)/([^/]+)$")
		if not validWeaponName(weapon) then return nil end
		return weaponInfo.folder .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER .. "/" .. filename
	end
	local info = CATEGORY_INFO[category]
	if not info then return nil end
	local filename = relativePath:match("^" .. category .. "/([^/]+)$")
	if not filename then return nil end
	return info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER .. "/" .. filename
end

local function encodeURLPath(path)
	return (path:gsub("([^%w_%.%-~/])", function(character)
		return string.format("%%%02X", string.byte(character))
	end))
end

-- Removes official files that no longer exist in the manifest (never touches user files).
-- Returns true when it removed something.
local function pruneOfficial(expected)
	local removed = false
	local function pruneFolder(folder)
		local okFolder, exists = pcall(isfolder, folder)
		if not okFolder or not exists then return end
		local ok, files = pcall(listfiles, folder)
		if not ok or type(files) ~= "table" then return end
		for _, filePath in ipairs(files) do
			local normalized = tostring(filePath):gsub("\\", "/")
			local relative = libraryRelative(normalized)
			local extension = normalized:match("%.([%w]+)$")
			if relative and extension and ASSET_EXTENSIONS[extension:lower()] and not expected[relative] then
				if pcall(delfile, filePath) then
					removed = true
					CW.Log("Removed obsolete official asset " .. relative)
				end
			end
		end
	end

	for _, info in pairs(CATEGORY_INFO) do
		pruneFolder(info.folder .. "/" .. CW.Paths.OFFICIAL_FOLDER)
	end
	for _, info in pairs(WEAPON_CATEGORIES) do
		local ok, weaponFolders = pcall(listfiles, info.folder)
		if ok and type(weaponFolders) == "table" then
			for _, weaponFolder in ipairs(weaponFolders) do
				pruneFolder((tostring(weaponFolder):gsub("\\", "/")) .. "/" .. CW.Paths.OFFICIAL_FOLDER)
			end
		end
	end
	return removed
end

local DOWNLOAD_WORKERS = 4 -- downloads at the same time

local function syncImpl()
	local manifestURL = _cfg.ASSET_MANIFEST_URL
	if type(manifestURL) ~= "string" or manifestURL == "" then
		CW.Log("Asset manifest URL is unset; using files already in Library")
		return false
	end
	if not CW.Caps.files then
		CW.Warn("File functions unavailable; skipping the asset sync")
		return false
	end
	CW.Log("Fetching asset manifest")
	if not (CW.Caps.httpGet or CW.Caps.request) then
		CW.Warn("HTTP unavailable; using files already in Library")
		return false
	end

	local fetched, raw = pcall(CW.httpGet, manifestURL)
	if not fetched or type(raw) ~= "string" then
		CW.Warn("Could not download the asset manifest: " .. tostring(raw))
		return false
	end
	local decoded, manifest = pcall(HttpService.JSONDecode, HttpService, raw)
	if not decoded or type(manifest) ~= "table" or manifest.schemaVersion ~= 1 or type(manifest.assets) ~= "table" then
		CW.Warn("Asset manifest is invalid or uses an unsupported schema")
		return false
	end

	local baseURL = manifestURL:match("^(.*)/[^/]+$")
	if not baseURL then
		CW.Warn("Asset manifest URL must point to a file under a raw repository URL")
		return false
	end
	local revision = type(manifest.revision) == "string" and manifest.revision ~= ""
		and manifest.revision or string.format("%08x", CW.crc32(raw))
	local previousRevision = CW.readSigFile(CW.Paths.LIBRARY_REVISION_FILE)
	local complete = true
	local skipped = 0
	local pending = {}
	-- False when an entry of the manifest itself is malformed: the list of files to keep is then
	-- not reliable, so nothing is removed from the _Official folders in that run.
	local entriesTrusted = true

	for category, entries in pairs(manifest.assets) do
		local weaponInfo = WEAPON_CATEGORIES[category]
		if weaponInfo and type(entries) == "table" then
			-- assets.<Category>[Weapon] = { { path = "<Category>/<Weapon>/<file>", crc32 = "..." }, ... }
			for weapon, weaponEntries in pairs(entries) do
				if validWeaponName(weapon) and type(weaponEntries) == "table" then
					ensureFolderPath(weaponInfo.folder .. "/" .. weapon .. "/" .. CW.Paths.OFFICIAL_FOLDER)
					for _, entry in ipairs(weaponEntries) do
						local manifestWeapon
						if type(entry) == "table" and type(entry.path) == "string" then
							manifestWeapon = entry.path:match("^" .. category .. "/([^/]+)/")
						end
						if type(entry) == "table" and manifestWeapon == weapon and validManifestPath(category, entry.path) then
							table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
						else
							skipped = skipped + 1
							entriesTrusted = false
							CW.Warn("Skipped invalid " .. category .. " entry in manifest")
						end
					end
				else
					skipped = skipped + 1
					entriesTrusted = false
				end
			end
		elseif CATEGORY_INFO[category] and type(entries) == "table" then
			for _, entry in ipairs(entries) do
				if type(entry) == "table" and validManifestPath(category, entry.path) then
					table.insert(pending, { category = category, path = entry.path, crc32 = entry.crc32 })
				else
					skipped = skipped + 1
					entriesTrusted = false
					CW.Warn("Skipped invalid " .. category .. " entry in manifest")
				end
			end
		else
			complete = false
			skipped = skipped + 1
			CW.Warn("Skipped unsupported manifest category: " .. tostring(category))
		end
	end

	CW.Log(string.format("Manifest contains %d supported assets; skipped %d unsupported entries", #pending, skipped))
	pcall(writefile, CW.Paths.MANIFEST_FILE, raw)

	-- Which files need a download. A file in the index with the manifest's checksum only has its size compared;
	-- any other file is checked in full (format and checksum).
	local expected = {}
	local downloads = {}
	local changed, indexChanged = false, false
	for index, entry in ipairs(pending) do
		local destination = officialDestination(entry.category, entry.path)
		if not destination then
			complete = false
			entriesTrusted = false
		else
			local destinationRelative = libraryRelative(destination)
			if destinationRelative then expected[destinationRelative] = true end
			ensureFolderPath(destination:match("^(.*)/[^/]+$"))
			local expectedCRC = entry.crc32 and (tostring(entry.crc32):lower():gsub("^0x", "")) or nil

			local needsDownload = true
			if isfile(destination) then
				local ok, existing = pcall(readfile, destination)
				local known = destinationRelative and libraryIndex[destinationRelative]
				if ok and type(existing) == "string" and known and expectedCRC and known.crc == expectedCRC and known.size == #existing then
					needsDownload = false
				else
					local actualFormat = ok and detectAssetFormat(existing) or "unreadable"
					if formatMatches(entry.category, entry.path, actualFormat) then
						if expectedCRC then
							local actualCRC = string.format("%08x", CW.crc32Yielding(existing)):lower()
							needsDownload = actualCRC ~= expectedCRC
							if not needsDownload and destinationRelative then
								libraryIndex[destinationRelative] = { crc = actualCRC, size = #existing }
								indexChanged = true
							end
						else
							needsDownload = previousRevision ~= revision
						end
					else
						CW.Warn("Cached asset " .. entry.path .. " is invalid (detected " .. actualFormat .. "); downloading again")
					end
				end
			end
			if needsDownload then
				table.insert(downloads, { entry = entry, destination = destination, relative = destinationRelative, crc = expectedCRC })
			end
		end
		if index % 8 == 0 then task.wait() end
	end

	-- The downloads, a few at a time. Each file is checked (format, checksum) and written through a temporary
	-- file that is read back, so a half-written file never replaces a good one.
	local function download(job)
		local entry, destination = job.entry, job.destination
		local downloaded, bytes = pcall(CW.httpGet, baseURL .. "/" .. encodeURLPath(entry.path))
		if not (downloaded and type(bytes) == "string") then
			complete = false
			CW.Warn("Could not download official asset " .. entry.path)
			return
		end
		local actualFormat = detectAssetFormat(bytes)
		local expectedFormat = isAudioCategory(entry.category) and "audio" or entry.path:match("%.([%w]+)$"):lower()
		local actualCRC = string.format("%08x", CW.crc32Yielding(bytes)):lower()
		if not formatMatches(entry.category, entry.path, actualFormat) then
			complete = false
			CW.Warn("Rejected " .. entry.path .. ": expected " .. expectedFormat .. " content, detected " .. actualFormat .. ". Check the GitHub path and file format.")
			return
		end
		if job.crc and actualCRC ~= job.crc then
			complete = false
			CW.Warn("Checksum mismatch for " .. entry.path)
			return
		end
		local temporary = destination .. ".download"
		local wrote = pcall(writefile, temporary, bytes)
		local readOK, verified = pcall(readfile, temporary)
		local saved = wrote and readOK and verified == bytes
		if saved then saved = pcall(writefile, destination, verified) end
		pcall(delfile, temporary)
		if saved then
			changed = true
			if job.relative then
				libraryIndex[job.relative] = { crc = actualCRC, size = #bytes }
				indexChanged = true
			end
		else
			complete = false
			CW.Warn("Could not save official asset " .. entry.path)
		end
	end
	if #downloads > 0 then
		CW.Log(string.format("Downloading %d of %d assets", #downloads, #pending))
		local nextJob, running = 0, 0
		for _ = 1, math.min(DOWNLOAD_WORKERS, #downloads) do
			running += 1
			task.spawn(function()
				while isCurrentRun() do
					nextJob += 1
					local job = downloads[nextJob]
					if not job then break end
					local ok, err = pcall(download, job)
					if not ok then
						complete = false
						CW.Warn("Could not sync " .. tostring(job.entry.path) .. ": " .. tostring(err))
					end
				end
				running -= 1
			end)
		end
		while running > 0 do task.wait() end
	end

	-- Persist a valid manifest revision even when a few entries fail. Good files stay cached,
	-- while missing/invalid paths are retried because their files fail validation.
	pcall(writefile, CW.Paths.LIBRARY_REVISION_FILE, revision)
	-- Official files that are no longer in the manifest (for example a cursor removed from the
	-- repository) are deleted from the _Official folders. This no longer depends on every other
	-- download having succeeded; user files outside _Official are never touched.
	if #pending > 0 then
		if entriesTrusted then
			if pruneOfficial(expected) then changed = true end
			for relative in pairs(libraryIndex) do
				if not expected[relative] then
					libraryIndex[relative] = nil
					indexChanged = true
				end
			end
		else
			CW.Warn("The manifest has invalid entries; obsolete official files were not removed this time")
		end
	end
	if indexChanged then saveLibraryIndex() end
	if complete then
		CW.Log("Asset library synchronized at revision " .. revision .. (changed and "" or " (nothing changed)"))
	else
		CW.Warn("Asset sync finished with invalid or unavailable files; valid assets were kept")
	end
	return complete, changed
end

-- Only one sync at a time; concurrent callers wait for the running one. Returns whether every file is
-- in place and whether the library changed (files written or removed).
function CW.Library.sync()
	if CW.State.syncing then
		local waitDeadline = os.clock() + 180
		while CW.State.syncing do
			if os.clock() > waitDeadline then return false end -- the running sync is stuck: report "incomplete"
			task.wait(0.1)
		end
		return CW.State.lastSyncResult == true
	end
	CW.State.syncing = true
	CW.Library.invalidate() -- files may have been added or removed by hand since the last scan
	local ok, result, changed = pcall(syncImpl)
	CW.Library.invalidate() -- ... and the sync itself may have written new ones
	CW.State.syncing = false
	CW.State.lastSyncResult = ok and result == true
	if not ok then error(result, 0) end
	return result, changed == true
end

CW.Paths.CURSOR_FILE = CW.Library.selectedPath("Cursors")
CW.Paths.HITMARKER_FILE = CW.Library.selectedPath("Hitmarkers")
CW.Paths.SOUND_FILE = CW.Library.selectedPath("HitSounds")
-- Before the cursor and the hitmarker are built: they read the settings of the assets in use.
CW.Profiles.start("Cursors", CW.Library.relative(CW.Paths.CURSOR_FILE))
CW.Profiles.start("Hitmarkers", CW.Library.relative(CW.Paths.HITMARKER_FILE))
CW.Profiles.start("HitSounds", CW.Library.relative(CW.Paths.SOUND_FILE))
end)

runModule("PNG", function()
-- PNG.lua
local CW = getgenv().__CW_CORE_STATE

local floor   = math.floor
local mmin    = math.min
local mmax    = math.max
local mabs    = math.abs
local sbyte   = string.byte
local schar   = string.char
local sformat = string.format
local tconcat = table.concat
local tunpack = table.unpack
local band    = bit32.band
local bxor    = bit32.bxor
local rshift  = bit32.rshift

local function adler32(s)
	local s1, s2 = 1, 0
	for i = 1, #s do
		local b = sbyte(s, i)
		s1 = (s1 + b) % 65521
		s2 = (s2 + s1) % 65521
		if i % 65536 == 0 then CW.yieldBudget() end
	end
	return s2 * 65536 + s1
end

local function u32be(n)
	return schar(rshift(n,24), band(rshift(n,16),0xFF),
		band(rshift(n,8),0xFF), band(n,0xFF))
end

local function pngChunk(t, data)
	local p = t..data
	return u32be(#data)..p..u32be(CW.crc32Yielding(p))
end

-- Deflate "stored" blocks (no compression). The cursor files are small, local and only read by
-- the engine, so skipping compression makes the encoder dramatically faster than the old
-- bit-by-bit Huffman writer. Each block holds at most 65535 bytes.
local function deflateStored(raw)
	local parts = {}
	local total = #raw
	local pos = 1
	repeat
		local len = mmin(65535, total - pos + 1)
		local final = (pos + len > total) and 1 or 0
		local nlen = bxor(len, 0xFFFF)
		parts[#parts + 1] = schar(final, band(len, 0xFF), rshift(len, 8), band(nlen, 0xFF), rshift(nlen, 8))
		parts[#parts + 1] = raw:sub(pos, pos + len - 1)
		pos = pos + len
	until pos > total
	return tconcat(parts)
end

function CW.encodePNG(px, w, h)
	local rows = {}
	local rowLen = w * 4
	for y = 0, h - 1 do
		local base = y * rowLen
		local parts = { "\0" }
		for s = 1, rowLen, 4096 do
			parts[#parts + 1] = schar(tunpack(px, base + s, base + mmin(s + 4095, rowLen)))
		end
		rows[y + 1] = tconcat(parts)
		if y % 16 == 0 then CW.yieldBudget() end
	end
	local raw = tconcat(rows)
	return "\137\80\78\71\13\10\26\10"
		.. pngChunk("IHDR", u32be(w)..u32be(h).."\8\6\0\0\0")
		.. pngChunk("IDAT", "\120\1"..deflateStored(raw)..u32be(adler32(raw)))
		.. pngChunk("IEND", "")
end

local COLOR_CHANNELS = {[0]=1, [2]=3, [3]=1, [4]=2, [6]=4}
local MAX_PNG_PIXELS = 2048 * 2048 -- the largest PNG in the library is 728x728

local function inflate(data)
	local bytes = {}
	for i = 1, #data do bytes[i] = sbyte(data, i) end
	local pos, bitbuf, bitcount = 1, 0, 0
	local out, opos = {}, 1
	local ticks = 0

	local function readbits(n)
		while bitcount < n do
			if pos <= #bytes then bitbuf = bitbuf + bytes[pos] * (2^bitcount); pos = pos+1 end
			bitcount = bitcount + 8
		end
		local v = bitbuf % (2^n)
		bitbuf = floor(bitbuf / (2^n)); bitcount = bitcount - n
		return v
	end

	local function buildTable(lens, nsym)
		local counts, nextcode = {}, {}
		for i = 0, 15 do counts[i] = 0 end
		for i = 0, nsym-1 do local l = lens[i] or 0; counts[l] = counts[l]+1 end
		counts[0] = 0
		local code = 0
		for b = 1, 15 do code = (code + counts[b-1])*2; nextcode[b] = code end
		local tbl = {}
		for sym = 0, nsym-1 do
			local l = lens[sym] or 0
			if l > 0 then
				local c = nextcode[l]; nextcode[l] = c+1
				local rev, tmp = 0, c
				for _ = 1, l do rev = rev*2 + tmp%2; tmp = floor(tmp/2) end
				tbl[rev*16+l] = sym
			end
		end
		return tbl
	end

	local function decode(tbl, maxbits)
		while bitcount < maxbits and pos <= #bytes do
			bitbuf = bitbuf + bytes[pos] * (2^bitcount); pos = pos+1; bitcount = bitcount+8
		end
		for b = 1, maxbits do
			if bitcount >= b then
				local key = (bitbuf % (2^b))*16 + b
				local sym = tbl[key]
				if sym ~= nil then
					bitbuf = floor(bitbuf/(2^b)); bitcount = bitcount-b; return sym
				end
			end
		end
		error("inflate: decode failed at byte "..pos)
	end

	local fixLL, fixD = {}, {}
	for i=0,143 do fixLL[i]=8 end; for i=144,255 do fixLL[i]=9 end
	for i=256,279 do fixLL[i]=7 end; for i=280,287 do fixLL[i]=8 end
	for i=0,31 do fixD[i]=5 end
	local FLL = buildTable(fixLL,288); local FDT = buildTable(fixD,32)

	local LBASE={3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local LEXT ={0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local DBASE={1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local DEXT ={0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
	local CLORD={16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}

	local function decodeBlock(llt, ddt, mLL, mD)
		while true do
			ticks = ticks + 1
			if ticks % 16384 == 0 then CW.yieldBudget() end
			local sym = decode(llt, mLL)
			if sym < 256 then out[opos]=sym; opos=opos+1
			elseif sym == 256 then break
			else
				assert(LBASE[sym-256], "inflate: invalid length symbol")
				local len  = LBASE[sym-256] + readbits(LEXT[sym-256])
				local dc   = decode(ddt, mD)
				assert(DBASE[dc+1], "inflate: invalid distance symbol")
				local dist = DBASE[dc+1] + readbits(DEXT[dc+1])
				assert(dist <= opos - 1, "inflate: distance reaches before the start of the data")
				local src  = opos - dist
				for _ = 1, len do out[opos]=out[src]; opos=opos+1; src=src+1 end
			end
		end
	end

	repeat
		local bfinal, btype = readbits(1), readbits(2)
		if btype == 0 then
			-- Stored block. The bit reader may already have prefetched whole bytes beyond the
			-- block header, so after discarding the partial byte those bytes are handed back
			-- (pos moves back) before the LEN/NLEN fields and the raw data are read.
			local partial = bitcount % 8
			if partial > 0 then readbits(partial) end
			pos = pos - floor(bitcount / 8)
			bitbuf, bitcount = 0, 0
			assert(pos + 3 <= #bytes, "inflate: truncated stored block header")
			local len = bytes[pos] + bytes[pos+1]*256; pos = pos+4
			assert(pos + len - 1 <= #bytes, "inflate: truncated stored block")
			for i = 0, len-1 do out[opos]=bytes[pos+i]; opos=opos+1 end
			pos = pos+len
		elseif btype == 1 then decodeBlock(FLL, FDT, 9, 5)
		elseif btype == 2 then
			local hlit  = readbits(5)+257
			local hdist = readbits(5)+1
			local hclen = readbits(4)+4
			local clLens = {}
			for i = 0,18 do clLens[i]=0 end
			for i = 1,hclen do clLens[CLORD[i]]=readbits(3) end
			local CLT = buildTable(clLens, 19)
			local combined, ci = {}, 0
			while ci < hlit+hdist do
				local s = decode(CLT, 7)
				if s <= 15 then combined[ci]=s; ci=ci+1
				elseif s == 16 then
					assert(ci > 0, "inflate: repeat code without a previous length")
					local r=readbits(2)+3; for _=1,r do combined[ci]=combined[ci-1]; ci=ci+1 end
				elseif s == 17 then local r=readbits(3)+3; for _=1,r do combined[ci]=0; ci=ci+1 end
				else local r=readbits(7)+11; for _=1,r do combined[ci]=0; ci=ci+1 end end
			end
			assert(ci == hlit+hdist, "inflate: code lengths overflow the table")
			local llLens, distLens, mLL, mD = {}, {}, 0, 0
			for i=0,hlit-1  do llLens[i]=combined[i];       if combined[i]>(mLL or 0) then mLL=combined[i] end end
			for i=0,hdist-1 do distLens[i]=combined[hlit+i]; if combined[hlit+i]>(mD or 0) then mD=combined[hlit+i] end end
			decodeBlock(buildTable(llLens,hlit), buildTable(distLens,hdist), mLL, mD)
		else error("inflate: reserved block type") end
	until bfinal == 1

	local parts = {}
	for i = 1, opos-1, 4096 do
		parts[#parts+1] = schar(tunpack(out, i, mmin(i+4095, opos-1)))
	end
	return tconcat(parts)
end

-- Bit depths the PNG standard allows for each color type.
local VALID_DEPTHS = {
	[0] = { [1] = true, [2] = true, [4] = true, [8] = true, [16] = true }, -- grayscale
	[2] = { [8] = true, [16] = true },                                     -- RGB
	[3] = { [1] = true, [2] = true, [4] = true, [8] = true },              -- palette
	[4] = { [8] = true, [16] = true },                                     -- grayscale + alpha
	[6] = { [8] = true, [16] = true },                                     -- RGBA
}
-- Adam7 passes: x start, y start, x step, y step.
local ADAM7 = {
	{ 0, 0, 8, 8 }, { 4, 0, 8, 8 }, { 0, 4, 4, 8 }, { 2, 0, 4, 4 },
	{ 0, 2, 2, 4 }, { 1, 0, 2, 2 }, { 0, 1, 1, 2 },
}

-- Decodes any standard PNG (every color type and bit depth, interlaced or not) into 8-bit RGBA:
-- returns px (flat array, 1-based, r,g,b,a per pixel), width, height.
function CW.parsePNG(data)
	assert(data:sub(1,8) == "\137\80\78\71\13\10\26\10", "not a PNG")
	local pos, w, h, bitDepth, colorType = 9
	local interlace = 0
	local idatParts, palette, transAlpha = {}, {}, {}
	local transKey -- tRNS for color types 0 and 2: the one gray / RGB value that is transparent (raw samples)

	while pos <= #data do
		assert(pos + 7 <= #data, "parsePNG: truncated chunk header")
		local len   = sbyte(data,pos)*16777216 + sbyte(data,pos+1)*65536
					+ sbyte(data,pos+2)*256    + sbyte(data,pos+3)
		local typ   = data:sub(pos+4, pos+7)
		assert(pos + 8 + len - 1 <= #data, "parsePNG: truncated " .. typ .. " chunk")
		local chunk = data:sub(pos+8, pos+8+len-1)
		pos = pos + 12 + len

		if typ == "IHDR" then
			assert(#chunk >= 13, "parsePNG: invalid IHDR")
			w         = sbyte(chunk,1)*16777216+sbyte(chunk,2)*65536+sbyte(chunk,3)*256+sbyte(chunk,4)
			h         = sbyte(chunk,5)*16777216+sbyte(chunk,6)*65536+sbyte(chunk,7)*256+sbyte(chunk,8)
			bitDepth  = sbyte(chunk,9)
			colorType = sbyte(chunk,10)
			interlace = sbyte(chunk,13)
			-- A header is cheap to forge: refuse sizes that would allocate gigabytes of pixel tables.
			assert(w > 0 and h > 0 and w * h <= MAX_PNG_PIXELS, "parsePNG: unsupported image size " .. w .. "x" .. h)
			assert(VALID_DEPTHS[colorType], "parsePNG: unsupported colorType " .. tostring(colorType))
			assert(VALID_DEPTHS[colorType][bitDepth],
				"parsePNG: invalid bit depth " .. tostring(bitDepth) .. " for colorType " .. tostring(colorType))
			assert(interlace == 0 or interlace == 1, "parsePNG: unknown interlace method " .. tostring(interlace))
		elseif typ == "PLTE" then
			for i = 0, floor(#chunk/3)-1 do
				palette[i] = {sbyte(chunk,i*3+1), sbyte(chunk,i*3+2), sbyte(chunk,i*3+3)}
			end
		elseif typ == "tRNS" then
			if colorType == 3 then
				for i = 1, #chunk do transAlpha[i-1] = sbyte(chunk,i) end
			elseif colorType == 0 and #chunk >= 2 then
				transKey = { sbyte(chunk,1)*256 + sbyte(chunk,2) }
			elseif colorType == 2 and #chunk >= 6 then
				transKey = { sbyte(chunk,1)*256 + sbyte(chunk,2), sbyte(chunk,3)*256 + sbyte(chunk,4),
					sbyte(chunk,5)*256 + sbyte(chunk,6) }
			end
		elseif typ == "IDAT" then idatParts[#idatParts+1] = chunk
		elseif typ == "IEND" then break end
	end

	assert(w and h and colorType, "parsePNG: missing IHDR")
	local ch = COLOR_CHANNELS[colorType]
	local bitsPerPixel = ch * bitDepth
	local bpp = math.max(1, bitsPerPixel // 8) -- bytes per pixel, as the filters see it
	local maxSample = 2 ^ bitDepth - 1

	-- zlib stream: 2-byte header, deflate data, 4-byte Adler-32.
	local zlibData = tconcat(idatParts)
	assert(#zlibData > 6, "parsePNG: missing image data")
	local rawData = inflate(zlibData:sub(3, -5))

	-- Raw sample k (0-based, within one row) of an unfiltered row, at the image's own bit depth.
	local sampleAt
	if bitDepth == 8 then
		sampleAt = function(row, k) return row[k + 1] end
	elseif bitDepth == 16 then
		sampleAt = function(row, k) return row[2*k + 1] * 256 + row[2*k + 2] end
	else
		local perByte = 8 // bitDepth
		sampleAt = function(row, k)
			local byte = row[k // perByte + 1]
			local shift = 8 - bitDepth * (k % perByte + 1)
			return band(rshift(byte, shift), maxSample)
		end
	end
	-- A raw gray/color sample -> 0..255 (palette indexes are not scaled).
	local function to8(v)
		if bitDepth == 8 then return v end
		if bitDepth == 16 then return (v * 255 + 32767) // 65535 end
		return (v * 255 + maxSample // 2) // maxSample
	end

	local px, rpos = {}, 1
	local rowsDone = 0

	-- Unfilters one (sub)image of pw x ph pixels and writes its pixels at (xs + i*xStep, ys + j*yStep).
	local function decodePass(pw, ph, xs, ys, xStep, yStep)
		local rowBytes = (pw * bitsPerPixel + 7) // 8
		assert(rpos + ph * (rowBytes + 1) - 1 <= #rawData, "parsePNG: truncated image data")
		local prev = {}
		for i = 1, rowBytes do prev[i] = 0 end
		for j = 0, ph - 1 do
			rowsDone = rowsDone + 1
			if rowsDone % 8 == 0 then CW.yieldBudget() end
			local ftype = sbyte(rawData, rpos); rpos = rpos + 1
			assert(ftype <= 4, "parsePNG: invalid filter type")
			local row = {}
			for x = 1, rowBytes do
				local b  = sbyte(rawData, rpos); rpos = rpos + 1
				local a  = row[x - bpp] or 0
				local up = prev[x]
				local ul = prev[x - bpp] or 0
				if     ftype == 0 then row[x] = b
				elseif ftype == 1 then row[x] = (b + a) % 256
				elseif ftype == 2 then row[x] = (b + up) % 256
				elseif ftype == 3 then row[x] = (b + floor((a + up) / 2)) % 256
				else
					local p = a + up - ul
					local pa, pb, pc = mabs(p - a), mabs(p - up), mabs(p - ul)
					row[x] = (b + (pa <= pb and pa <= pc and a or pb <= pc and up or ul)) % 256
				end
			end
			prev = row

			local y = ys + j * yStep
			for i = 0, pw - 1 do
				local dst = (y * w + xs + i * xStep) * 4 + 1
				local k = i * ch
				if colorType == 6 then
					px[dst] = to8(sampleAt(row, k)); px[dst+1] = to8(sampleAt(row, k+1))
					px[dst+2] = to8(sampleAt(row, k+2)); px[dst+3] = to8(sampleAt(row, k+3))
				elseif colorType == 2 then
					local r, g, b = sampleAt(row, k), sampleAt(row, k+1), sampleAt(row, k+2)
					px[dst] = to8(r); px[dst+1] = to8(g); px[dst+2] = to8(b)
					px[dst+3] = (transKey and r == transKey[1] and g == transKey[2] and b == transKey[3]) and 0 or 255
				elseif colorType == 0 then
					local v = sampleAt(row, k)
					local gray = to8(v)
					px[dst] = gray; px[dst+1] = gray; px[dst+2] = gray
					px[dst+3] = (transKey and v == transKey[1]) and 0 or 255
				elseif colorType == 4 then
					local gray = to8(sampleAt(row, k))
					px[dst] = gray; px[dst+1] = gray; px[dst+2] = gray; px[dst+3] = to8(sampleAt(row, k+1))
				else -- colorType 3: palette index
					local index = sampleAt(row, k)
					local pal = palette[index] or {255,255,255}
					px[dst] = pal[1]; px[dst+1] = pal[2]; px[dst+2] = pal[3]
					px[dst+3] = transAlpha[index] ~= nil and transAlpha[index] or 255
				end
			end
		end
	end

	if interlace == 1 then
		for _, pass in ipairs(ADAM7) do
			local xs, ys, xStep, yStep = pass[1], pass[2], pass[3], pass[4]
			local pw = (w - xs + xStep - 1) // xStep
			local ph = (h - ys + yStep - 1) // yStep
			if pw > 0 and ph > 0 then decodePass(pw, ph, xs, ys, xStep, yStep) end
		end
	else
		decodePass(w, h, 0, 0, 1, 1)
	end
	return px, w, h
end

-- Smooth resize. Shrinking averages every source pixel under the target pixel (box filter),
-- enlarging interpolates (bilinear). Colors are weighted by alpha, so transparent edges do
-- not bleed dark fringes into the cursor.
function CW.resizePixels(px, w, h, tw, th)
	if tw == w and th == h then return px, w, h end
	local out = {}
	local sx, sy = w / tw, h / th
	local ceil = math.ceil

	local function acc(i, weight, sr, sg, sb, sa)
		local a = (px[i + 3] or 0) * weight
		return sr + (px[i] or 0) * a, sg + (px[i + 1] or 0) * a, sb + (px[i + 2] or 0) * a, sa + a
	end

	for y = 0, th - 1 do
		if y % 4 == 0 then CW.yieldBudget() end
		for x = 0, tw - 1 do
			local dst = (y * tw + x) * 4 + 1
			local sr, sg, sb, sa = 0, 0, 0, 0
			local alpha

			if sx > 1 or sy > 1 then
				local x0 = mmin(floor(x * sx), w - 1)
				local x1 = mmin(mmax(x0, ceil((x + 1) * sx) - 1), w - 1)
				local y0 = mmin(floor(y * sy), h - 1)
				local y1 = mmin(mmax(y0, ceil((y + 1) * sy) - 1), h - 1)
				local count = 0
				for yy = y0, y1 do
					for xx = x0, x1 do
						sr, sg, sb, sa = acc((yy * w + xx) * 4 + 1, 1, sr, sg, sb, sa)
						count = count + 1
					end
				end
				alpha = sa / count
			else
				local fx = mmax(0, (x + 0.5) * sx - 0.5)
				local fy = mmax(0, (y + 0.5) * sy - 0.5)
				local x0, y0 = mmin(floor(fx), w - 1), mmin(floor(fy), h - 1)
				local x1, y1 = mmin(x0 + 1, w - 1), mmin(y0 + 1, h - 1)
				local tx, ty = fx - x0, fy - y0
				sr, sg, sb, sa = acc((y0 * w + x0) * 4 + 1, (1 - tx) * (1 - ty), sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y0 * w + x1) * 4 + 1, tx * (1 - ty), sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y1 * w + x0) * 4 + 1, (1 - tx) * ty, sr, sg, sb, sa)
				sr, sg, sb, sa = acc((y1 * w + x1) * 4 + 1, tx * ty, sr, sg, sb, sa)
				alpha = sa
			end

			if sa > 0 then
				out[dst]     = mmin(255, floor(sr / sa + 0.5))
				out[dst + 1] = mmin(255, floor(sg / sa + 0.5))
				out[dst + 2] = mmin(255, floor(sb / sa + 0.5))
				out[dst + 3] = mmin(255, floor(alpha + 0.5))
			else
				out[dst], out[dst + 1], out[dst + 2], out[dst + 3] = 0, 0, 0, 0
			end
		end
	end
	CW.Log(sformat("Resized to %d×%d", tw, th))
	return out, tw, th
end

function CW.applyTint(px, w, h, tR, tG, tB)
	local out = {}
	for i=1, w*h*4, 4 do
		if (i - 1) % 65536 == 0 then CW.yieldBudget() end
		local r,g,b,a = px[i] or 0, px[i+1] or 0, px[i+2] or 0, px[i+3] or 0
		if a > 10 then
			local lum = (0.299*r + 0.587*g + 0.114*b) / 255
			out[i]  =mmin(255,floor(lum*tR+0.5))
			out[i+1]=mmin(255,floor(lum*tG+0.5))
			out[i+2]=mmin(255,floor(lum*tB+0.5))
			out[i+3]=a
		else out[i]=0; out[i+1]=0; out[i+2]=0; out[i+3]=0 end
	end
	return out
end

-- Crops the fully transparent margins around an image (a Roblox thumbnail is padded to a square).
-- Pixels with alpha <= threshold count as transparent. Returns px, w, h, or nil when nothing is visible.
function CW.trimTransparent(px, w, h, threshold)
	threshold = threshold or 8
	local minX, minY, maxX, maxY = w, h, -1, -1
	for y = 0, h - 1 do
		if y % 8 == 0 then CW.yieldBudget() end
		local row = y * w
		for x = 0, w - 1 do
			if (px[(row + x) * 4 + 4] or 0) > threshold then
				if x < minX then minX = x end
				if x > maxX then maxX = x end
				if y < minY then minY = y end
				if y > maxY then maxY = y end
			end
		end
	end
	if maxX < 0 then return nil end
	local tw, th = maxX - minX + 1, maxY - minY + 1
	if tw == w and th == h then return px, w, h end
	local out = {}
	for y = 0, th - 1 do
		local src = ((minY + y) * w + minX) * 4
		local dst = y * tw * 4
		for k = 1, tw * 4 do out[dst + k] = px[src + k] end
	end
	return out, tw, th
end
end)


runModule("Cursor", function()
-- Cursor.lua
local CW = getgenv().__CW_CORE_STATE

local Players          = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService       = game:GetService("RunService")

local LocalPlayer = CW.LocalPlayer
local Mouse       = CW.Mouse

local sformat = string.format

-- "red" = over an enemy, "green" = over a teammate; their colors come from the settings.
local function tintVariants()
	local variants = {}
	for key, setting in pairs({ red = "CURSOR_ENEMY_COLOR", green = "CURSOR_TEAM_COLOR" }) do
		local color = CW.Settings[setting]
		table.insert(variants, {
			key = key, tR = math.floor(color.R * 255 + 0.5), tG = math.floor(color.G * 255 + 0.5), tB = math.floor(color.B * 255 + 0.5),
		})
	end
	table.sort(variants, function(x, y) return x.key < y.key end) -- stable order for the signature
	return variants
end

local function computeCursorSourceSignature()
	local tintSig = ""
	for _, v in ipairs(tintVariants()) do
		tintSig = tintSig.."|"..v.key..":"..v.tR..","..v.tG..","..v.tB
	end
	-- "|fit" marks the aspect-preserving resize, so caches made by older versions are rebuilt.
	return CW.computeFileSignature(
		CW.Paths.CURSOR_FILE, "cur",
		"|size:"..tostring(CW.Settings.CURSOR_TARGET_SIZE).."|fit"..tintSig
	)
end

local function buildCursorFiles(sigHash)
	return {
		white = CW.Paths.TINTED_FOLDER.."/cur_white_"..sigHash..".png",
		red   = CW.Paths.TINTED_FOLDER.."/cur_red_"..sigHash..".png",
		green = CW.Paths.TINTED_FOLDER.."/cur_green_"..sigHash..".png",
	}
end

-- Every icon this script has put on the mouse (kept across re-runs), to tell them from the game's: the game sets
-- its own (the gun crosshair while a gun is out) and that one is put back when the custom cursor goes.
CW.State.cursorIcons = CW.State.cursorIcons or {}
local function isOurIcon(icon) return icon ~= nil and CW.State.cursorIcons[icon] == true end

local function setOSCursor(key)
	if CW.State.currentCursorKey == key then return end
	CW.State.currentCursorKey = key
	local url = CW.Assets[key]
	if url then
		CW.State.cursorIcons[url] = true
		CW.State.settingCursor = true
		UserInputService.MouseIcon = url
		CW.State.settingCursor = false
	end
end

local function connectEnforcer()
	if CW.State.enforcerConn then CW.State.enforcerConn:Disconnect() end
	-- Stored by the previous version, which forced MouseIconEnabled back on. That fought the
	-- game's sniper scope (it hides the cursor on purpose), so it is no longer done.
	if CW.State.enableConn then
		pcall(function() CW.State.enableConn:Disconnect() end)
		CW.State.enableConn = nil
	end

	CW.State.enforcerConn = UserInputService:GetPropertyChangedSignal("MouseIcon"):Connect(function()
		if CW.State.settingCursor then return end
		local icon = UserInputService.MouseIcon
		if not isOurIcon(icon) then CW.State.gameMouseIcon = icon end -- what the game wants now
		if CW.State.scoped then return end
		if not CW.State.cursorsReady or not CW.State.currentCursorKey then return end
		local expected = CW.Assets[CW.State.currentCursorKey]
		if expected and icon ~= expected then
			CW.State.settingCursor = true
			UserInputService.MouseIcon = expected
			CW.State.settingCursor = false
		end
	end)
end

local function activateCursors()
	local icon = UserInputService.MouseIcon
	if not isOurIcon(icon) then CW.State.gameMouseIcon = icon end
	CW.State.cursorsReady = true
	if not CW.State.scoped then UserInputService.MouseIconEnabled = true end
	CW.State.currentCursorKey = nil
	CW.State.lastTarget = nil -- force the PreRender loop to re-evaluate the hovered target
	setOSCursor("white")
	connectEnforcer()
	if CW.State.scopeUpdate then CW.State.scopeUpdate() end
end

-- No custom cursor: the game's own. Nothing is touched unless this script had put its cursor on (then the
-- game's last icon goes back, the gun crosshair included).
local function deactivateCursors()
	local wasActive = CW.State.cursorsReady
	CW.Assets.white, CW.Assets.red, CW.Assets.green = nil, nil, nil
	CW.State.cursorsReady = false
	CW.State.currentCursorKey = nil
	for _, key in ipairs({ "enforcerConn", "enableConn" }) do
		local connection = CW.State[key]
		if connection then
			pcall(function() connection:Disconnect() end)
			CW.State[key] = nil
		end
	end
	CW.untrack("scopeHide")
	if wasActive or isOurIcon(UserInputService.MouseIcon) then
		pcall(function()
			if isOurIcon(UserInputService.MouseIcon) then UserInputService.MouseIcon = CW.State.gameMouseIcon or "" end
			if not CW.State.scoped then UserInputService.MouseIconEnabled = true end
		end)
	end
end

local function loadCachedCursorAssets(files)
	CW.Assets.white = getcustomasset(files.white)
	CW.Assets.red   = getcustomasset(files.red)
	CW.Assets.green = getcustomasset(files.green)
end

local function reloadCursorFromSource(sigHash, data)
	if not data then
		CW.Warn("No valid cursor image found at " .. tostring(CW.Paths.CURSOR_FILE) .. ". Place a PNG in the cursor library and refresh.")
		return false
	end
	local ok2, px, w, h = pcall(CW.parsePNG, data)
	if not ok2 then
		-- Unsupported PNG variant (interlaced, 16-bit, ...): use the original image as-is.
		CW.Warn("parsePNG failed (" .. tostring(px) .. "); using the original image without resize/tint")
		local okAsset, asset = pcall(getcustomasset, CW.Paths.CURSOR_FILE)
		if okAsset and asset then
			CW.Assets.white, CW.Assets.red, CW.Assets.green = asset, asset, asset
			return true
		end
		return false
	end
	CW.Log(sformat("Loaded new cursor.png (%d×%d)", w, h))

	-- The longest side becomes the target size and the other side follows the image's aspect
	-- ratio, so non-square cursors are no longer stretched.
	local targetSize = CW.Settings.CURSOR_TARGET_SIZE
	if targetSize then
		local scale = targetSize / math.max(w, h)
		local tw = math.max(1, math.floor(w * scale + 0.5))
		local th = math.max(1, math.floor(h * scale + 0.5))
		px, w, h = CW.resizePixels(px, w, h, tw, th)
	end

	local files = buildCursorFiles(sigHash)

	writefile(files.white, CW.encodePNG(px, w, h))
	CW.Assets.white = getcustomasset(files.white)

	for _, v in ipairs(tintVariants()) do
		writefile(files[v.key], CW.encodePNG(CW.applyTint(px, w, h, v.tR, v.tG, v.tB), w, h))
		CW.Assets[v.key] = getcustomasset(files[v.key])
	end

	writefile(CW.Paths.CURSOR_SIG_FILE, sigHash)
	CW.pruneOldFiles(CW.Paths.TINTED_FOLDER, "cur_", sigHash, "cursor")
	return true
end

local function generateCursorsOnce()
	if not CW.Paths.CURSOR_FILE then
		deactivateCursors()
		local chosen = CW.Settings.ASSET_SELECTIONS.Cursor
		if type(chosen) == "string" and chosen ~= "" then
			CW.Log("The chosen cursor (" .. chosen .. ") is not in the library yet; the game's cursor stays until it is")
		end
		return
	end

	local currentSig, data = computeCursorSourceSignature()
	local sigHash    = sformat("%08x", CW.crc32(currentSig))
	local storedHash = CW.readSigFile(CW.Paths.CURSOR_SIG_FILE)

	local files = buildCursorFiles(sigHash)
	local filesExist = isfile(files.white) and isfile(files.red) and isfile(files.green)

	if filesExist and storedHash == sigHash then
		CW.Log("cursor.png unchanged: tinted variants match, using cache")
		loadCachedCursorAssets(files)
		activateCursors()
		CW.Log("OS cursor active (cached).")
		return
	end

	if storedHash and storedHash ~= sigHash then
		CW.Log("cursor.png changed since last run: reloading original and regenerating tints")
	elseif not filesExist then
		CW.Log("Tinted cache incomplete: regenerating from current cursor.png")
	end

	if reloadCursorFromSource(sigHash, data) then
		activateCursors()
		CW.Log("OS cursor active (regenerated from new original).")
	end
end

-- The codec yields, so runs are serialised: a request made while one is running marks the
-- state dirty and triggers exactly one more pass with the latest settings.
local function generateCursors()
	if CW.State.cursorBusy then
		CW.State.cursorDirty = true
		return
	end
	CW.State.cursorBusy = true
	repeat
		CW.State.cursorDirty = false
		local ok, err = pcall(generateCursorsOnce)
		if not ok then CW.Warn("Cursor generation failed: " .. tostring(err)) end
	until not CW.State.cursorDirty
	CW.State.cursorBusy = false
end

CW.reloadCursor = generateCursors
task.spawn(generateCursors)

-- Sniper scope. While the game's scope frame is open, the game hides the cursor on purpose.
-- The custom cursor stays hidden for exactly that time (nothing is drawn over the scope and the
-- game's own crosshair does not come back), and it is restored as soon as the scope closes.
local function restoreCursorIcon()
	local url = CW.State.cursorsReady and CW.Assets[CW.State.currentCursorKey or "white"]
	if url then
		CW.State.settingCursor = true
		UserInputService.MouseIcon = url
		CW.State.settingCursor = false
	end
end

local function watchScope()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 30)
	local crosshairGui = playerGui and playerGui:WaitForChild("CrosshairGui", 30)
	local scopeFrame = crosshairGui and crosshairGui:WaitForChild("ScopeFrame", 30)
	if not scopeFrame then return end

	-- Only with the custom cursor on: with the game's own cursor, the game's scope handles it as it always did.
	local hiding = false
	local function update()
		CW.State.scoped = scopeFrame.Visible
		if CW.State.scoped and CW.State.cursorsReady then
			hiding = true
			UserInputService.MouseIconEnabled = false
			-- Per frame, and only while scoped: whatever turns the icon back on is undone.
			CW.track("scopeHide", RunService.PreRender:Connect(function()
				if UserInputService.MouseIconEnabled then UserInputService.MouseIconEnabled = false end
			end))
		elseif hiding then
			hiding = false
			CW.untrack("scopeHide")
			if not CW.State.scoped then
				UserInputService.MouseIconEnabled = true
				restoreCursorIcon()
			end
		end
	end
	CW.State.scopeUpdate = update
	CW.track("scopeWatch", scopeFrame:GetPropertyChangedSignal("Visible"):Connect(update))
	update()
end
task.spawn(watchScope)

-- Registered with CW.track: a re-run replaces the loop with this version's code.
do
	-- Mouse.Target is a raycast, so it is sampled 25 times per second instead of every frame.
	local CURSOR_CHECK_INTERVAL = 0.04
	local nextCursorCheck = 0
	CW.track("cursorLoop", RunService.PreRender:Connect(function()
		if not CW.State.cursorsReady then return end
		local now = os.clock()
		if now < nextCursorCheck then return end
		nextCursorCheck = now + CURSOR_CHECK_INTERVAL
		local Target = Mouse.Target
		if Target == CW.State.lastTarget then return end
		CW.State.lastTarget = Target
		if not Target or not Target.Parent then setOSCursor("white"); return end

		local Player = Players:GetPlayerFromCharacter(Target.Parent)
			or (Target.Parent.Parent and Players:GetPlayerFromCharacter(Target.Parent.Parent))

		if Player and Player ~= LocalPlayer and CW.Settings.CURSOR_TEAM_CHECK then
			setOSCursor(Player.TeamColor == LocalPlayer.TeamColor and "green" or "red")
		else
			setOSCursor("white")
		end
	end))
end
end)

runModule("Hitmarker", function()
-- Hitmarker.lua
local CW = getgenv().__CW_CORE_STATE

local ContentProvider = game:GetService("ContentProvider")

local attachGui = CW.attachGui

-- Created on the first run, and again on a later run if the GUI is missing or was destroyed.
if not CW.IAPortable or not CW.IAPortable.Parent then
	if CW.IAPortable then pcall(function() CW.IAPortable:Destroy() end) end

	local gui = Instance.new("ScreenGui")
	gui.Name           = "CW_SA"
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn   = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder   = 9998
	if not attachGui(gui) then
		CW.Warn("Could not parent the hitmarker GUI; hitmarkers will not be displayed")
	end
	CW.IAPortable = gui
end

if not CW.HMTemplate then
	CW.HMTemplate = Instance.new("ImageLabel")
	CW.HMTemplate.AnchorPoint            = Vector2.new(0.5,0.5)
	CW.HMTemplate.BackgroundTransparency = 1
	CW.HMTemplate.Image                  = ""
end

CW.HMTemplate.Size = UDim2.new(0, CW.Settings.HITMARKER_SIZE, 0, CW.Settings.HITMARKER_SIZE)

local function reloadHitmarker()
	local asset = CW.loadLibraryAsset({
		file = CW.Paths.HITMARKER_FILE,
		label = "hitmarker",
	})
	-- Clear the old image when the selection is gone, instead of keeping a stale one.
	CW.HMTemplate.Image = asset or ""

	-- Preload in the background so the first hitmarker is not blank.
	if asset then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync({ CW.HMTemplate }) end)
		end)
	end
end

CW.reloadHitmarkerAsset = reloadHitmarker
reloadHitmarker()
end)


runModule("Sound", function()
-- Sound.lua
local CW = getgenv().__CW_CORE_STATE

local SoundService    = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")
local Debris          = game:GetService("Debris")

-- Every gun has its own hit sound (a file of the HitSounds folder or one of that gun's custom IDs) and its
-- own volume for each sound, so switching sounds brings back the volume that one had:
--   HIT_SOUND_GUNS        { ["AK-47"] = "HitSounds/pop.mp3" | "id:123" }
--   HIT_SOUND_GUN_VOLUMES { ["AK-47|HitSounds/pop.mp3"] = 0.6 }   (a sound never set plays at the default)
-- The one hit sound of older versions (ASSET_SELECTIONS.HitSound, with its volume) is where every gun starts,
-- and what a hit plays when no gun is in hand.
--
-- For each sound in use a few Sound objects are created once and preloaded. A hit then only rewinds one of
-- them and calls :Play(), which is immediate; they take turns so rapid hits overlap instead of cutting each
-- other off. If that fails, a fresh Sound per hit is used.

local POOL_SIZE = 4
local pools = {}   -- asset -> { sounds = { Sound }, index = n }
local assets = {}  -- library path or "id:123" -> asset, or false when it could not be loaded
local loading = {} -- paths being loaded right now

local function destroyPool(asset)
	local pool = pools[asset]
	pools[asset] = nil
	for _, sound in ipairs(pool and pool.sounds or {}) do
		pcall(function() sound:Destroy() end)
	end
end
local function destroyPools()
	for asset in pairs(pools) do destroyPool(asset) end
end
CW.State.destroyHitSoundPool = destroyPools

local function poolOf(asset)
	if pools[asset] then return pools[asset] end
	local pool = { sounds = {}, index = 0 }
	for _ = 1, POOL_SIZE do
		local ok, sound = pcall(function()
			local snd = Instance.new("Sound")
			snd.Name    = "CW_HitSound"
			snd.SoundId = asset
			snd.Parent  = SoundService
			return snd
		end)
		if ok and sound then table.insert(pool.sounds, sound) end
	end
	pools[asset] = pool
	if #pool.sounds > 0 then
		task.spawn(function()
			local ok, err = pcall(function() ContentProvider:PreloadAsync(pool.sounds) end)
			if not ok then CW.Log("Hit sound preload skipped: " .. tostring(err)) end
		end)
	end
	return pool
end

-- Loads a library path or a custom ID once (this can yield: an audio file may need a compatible copy).
local function load(relative)
	if type(relative) ~= "string" or relative == "" or assets[relative] ~= nil or loading[relative] then return end
	loading[relative] = true
	local asset = CW.loadLibraryAsset({
		file = CW.CustomIds.assetOf(relative) or (CW.Paths.LIBRARY_ROOT .. "/" .. relative),
		label = "hit sound",
		audio = true,
	})
	loading[relative] = nil
	assets[relative] = asset or false
end

local function general()
	return CW.Settings.ASSET_SELECTIONS.HitSound or CW.Library.relative(CW.Paths.SOUND_FILE)
end
local function volumeKey(gun, relative) return gun .. "|" .. tostring(relative) end

CW.HitSounds = {}
function CW.HitSounds.relative(gun)
	local choice = gun and CW.Settings.HIT_SOUND_GUNS[gun]
	if type(choice) == "string" then return choice end
	return general()
end
function CW.HitSounds.volume(gun)
	if not gun then return CW.Settings.SOUND_VOLUME end
	local saved = CW.Settings.HIT_SOUND_GUN_VOLUMES[volumeKey(gun, CW.HitSounds.relative(gun))]
	return tonumber(saved) or CW.Defaults.SOUND_VOLUME or 1
end

-- Loads every sound in use (each gun's and the one with no gun in hand) and drops the pools of the others.
-- (Before the first download there may be no sound at all: nothing is loaded then.)
local function prepare()
	local wanted = {}
	local base = general()
	if base then wanted[base] = true end
	for _, relative in pairs(CW.Settings.HIT_SOUND_GUNS) do wanted[relative] = true end
	local inUse = {}
	for relative in pairs(wanted) do
		load(relative)
		local asset = assets[relative]
		if asset then
			inUse[asset] = true
			poolOf(asset)
		end
	end
	for asset in pairs(pools) do
		if not inUse[asset] then destroyPool(asset) end
	end
end

function CW.HitSounds.set(gun, relative)
	CW.Settings.HIT_SOUND_GUNS[gun] = relative
	task.spawn(prepare)
end
function CW.HitSounds.setVolume(gun, volume)
	CW.Settings.HIT_SOUND_GUN_VOLUMES[volumeKey(gun, CW.HitSounds.relative(gun))] = math.clamp(tonumber(volume) or 1, 0, 2)
end
-- One of this gun's custom IDs was replaced by another one (newRelative) or removed (nil): its volume moves
-- with it, and a gun that was using it takes the new one, or the first library file.
function CW.HitSounds.replaceChoice(gun, oldRelative, newRelative)
	local volumes = CW.Settings.HIT_SOUND_GUN_VOLUMES
	local oldKey = volumeKey(gun, oldRelative)
	if newRelative then volumes[volumeKey(gun, newRelative)] = volumes[oldKey] end
	volumes[oldKey] = nil
	if CW.HitSounds.relative(gun) == oldRelative then
		local first = CW.Library.list("HitSounds")[1]
		CW.HitSounds.set(gun, newRelative or (first and first.Relative) or "")
	end
end
-- Every gun of the game starts from the one hit sound of older versions, with its volume (a gun added to the
-- game later too); the custom IDs of that one list become each gun's own.
function CW.HitSounds.adoptGuns(guns)
	local base = general()
	local profiles = CW.Settings.ASSET_PROFILES.HitSounds
	local profile = type(profiles) == "table" and base and profiles[base]
	local baseVolume = type(profile) == "table" and tonumber(profile.SOUND_VOLUME) or CW.Defaults.SOUND_VOLUME or 1
	for _, gun in ipairs(guns) do
		if CW.Settings.HIT_SOUND_GUNS[gun] == nil and base then
			CW.Settings.HIT_SOUND_GUNS[gun] = base
			CW.Settings.HIT_SOUND_GUN_VOLUMES[volumeKey(gun, base)] = baseVolume
		end
	end
	CW.CustomIds.splitPerGun("HitSounds", guns)
	task.spawn(prepare)
end

-- The library changed (a sync, a custom ID edited): everything is loaded again.
local function reloadSound()
	table.clear(assets)
	destroyPools()
	prepare()
end
CW.reloadSoundAsset = reloadSound
reloadSound()

local function playOnDemand(asset, volume)
	local ok, s = pcall(function()
		local snd = Instance.new("Sound")
		snd.SoundId = asset
		snd.Volume  = volume
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

-- gun: the name of the tool in hand when the shot hit (nil when there was none).
function CW.playHitSound(gun)
	local relative = CW.HitSounds.relative(gun)
	if type(relative) ~= "string" or relative == "" then return end -- this gun has no hit sound
	local asset = assets[relative]
	if asset == nil then
		task.spawn(prepare) -- not loaded yet: ready for the next hit
		return
	end
	if not asset then return end
	local volume = CW.HitSounds.volume(gun)

	local pool = pools[asset]
	if pool and #pool.sounds > 0 then
		pool.index = pool.index % #pool.sounds + 1
		local sound = pool.sounds[pool.index]
		local ok = pcall(function()
			sound.Volume       = volume
			sound.TimePosition = 0
			sound:Play()
		end)
		if ok then return end
	end
	playOnDemand(asset, volume)
end
end)


runModule("Texture", function()
-- Texture.lua
local CW = getgenv().__CW_CORE_STATE

local ContentProvider   = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer       = CW.LocalPlayer

CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER)

-- Two kinds of weapons can be textured:
--  * Regular guns have exactly one MeshPart, and that part carries the texture.
--  * FAL and M700 have no MeshPart: they are built from many block pieces. For them a custom
--    MeshPart (the whole gun as one model with proper UVs) is built and welded to the Handle, and
--    the original pieces are hidden while a texture is selected. Deselecting the texture removes
--    the custom mesh and shows the original pieces again.
-- The size, offset and rotation were measured in Studio on the pieces each mesh replaces: size is the box those
-- pieces fill (the size the mesh is shown at), offset its center from the Handle, rotation the turn that lays the
-- mesh along the barrel. Laid over the pieces, the outlines match (1:1, in the hand too: it is welded to the Handle).
-- The FAL mesh was made with other proportions, so its size is not its own size times one number.
local CUSTOM_MESH_WEAPONS = {
	["FAL"] = {
		meshId   = "90772329772088",
		meshName = "FAL/Meshes",
		hide     = { ["Smooth Block Model"] = true, ["Black"] = true },
		offset   = Vector3.new(0.0081, 0.3238, -0.5333),
		rotation = Vector3.new(0, 90, 0),
		size     = Vector3.new(4.7413, 1.1476, 0.4912),
	},
	["M700"] = {
		meshId   = "109235772617313",
		meshName = "M700/Meshes",
		hide     = { ["Smooth Block Model"] = true },
		offset   = Vector3.new(0.0411, 0.4626, -0.8174),
		rotation = Vector3.new(0, 90, 0),
		size     = Vector3.new(5.3007, 1.2828, 0.3613),
	},
}

local WEAPON_LIST = {}
local TEXTURABLE = {}
do
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	for _, tool in ipairs(guns and guns:GetChildren() or {}) do
		if tool:IsA("Tool") and tool:FindFirstChildWhichIsA("MeshPart", true) then
			TEXTURABLE[tool.Name] = true
		end
	end
	if next(TEXTURABLE) == nil then
		for _, name in ipairs({ "AK-47", "M4A1", "M9", "MP5", "Remington 870", "Revolver" }) do TEXTURABLE[name] = true end
	end
	for name in pairs(CUSTOM_MESH_WEAPONS) do TEXTURABLE[name] = true end
	for name in pairs(TEXTURABLE) do table.insert(WEAPON_LIST, name) end
	table.sort(WEAPON_LIST)
end

CW.WeaponList = WEAPON_LIST
CW.Assets.weaponTextures = {}
CW.Settings.ASSET_SELECTIONS.Textures = CW.Settings.ASSET_SELECTIONS.Textures or {}

for _, weaponName in ipairs(WEAPON_LIST) do
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName)
	CW.Library.ensureFolder(CW.Paths.TEXTURES_FOLDER .. "/" .. weaponName .. "/" .. CW.Paths.OFFICIAL_FOLDER)
end

-- Guns that have sounds to replace: every gun of the game that has a ToolProperties module. That
-- includes the Taser, which has no MeshPart (so it is not in WEAPON_LIST) but does shoot and reload.
-- Falls back to WEAPON_LIST when the game's folders are not found.
local SOUND_WEAPONS = {}
do
	local shared = ReplicatedStorage:FindFirstChild("SharedModules")
	local properties = shared and shared:FindFirstChild("ToolProperties")
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	if properties and guns then
		for _, tool in ipairs(guns:GetChildren()) do
			if tool:IsA("Tool") and properties:FindFirstChild(tool.Name) then
				table.insert(SOUND_WEAPONS, tool.Name)
			end
		end
	end
	if #SOUND_WEAPONS == 0 then
		for _, name in ipairs(WEAPON_LIST) do table.insert(SOUND_WEAPONS, name) end
	end
	table.sort(SOUND_WEAPONS)
end
CW.SoundWeaponList = SOUND_WEAPONS
-- Each of these guns has its own hit sound (the Sound module).
if CW.HitSounds then CW.HitSounds.adoptGuns(SOUND_WEAPONS) end

for _, weaponName in ipairs(SOUND_WEAPONS) do
	-- Your own mp3, ogg, wav or flac files go in WeaponSounds/<Weapon>/ (shoot) and ReloadSounds/<Weapon>/ (reload).
	for _, folder in ipairs({ CW.Paths.WEAPON_SOUNDS_FOLDER, CW.Paths.RELOAD_SOUNDS_FOLDER }) do
		CW.Library.ensureFolder(folder .. "/" .. weaponName)
		CW.Library.ensureFolder(folder .. "/" .. weaponName .. "/" .. CW.Paths.OFFICIAL_FOLDER)
	end
end

-- What was changed is remembered on the instances themselves, as attributes. They live and die
-- with the instance (a new tool is a fresh clone) and survive a re-run of the script, so no
-- separate bookkeeping is needed to restore anything.
local ORIGINAL_TEXTURE = "CW_OriginalTexture"        -- on a regular gun's MeshPart
local ORIGINAL_TRANSPARENCY = "CW_OriginalTransparency" -- on the pieces hidden for a custom mesh

-- Returns true when the weapon's mesh was found (and the texture applied or restored).
local function applyRegularTexture(tool)
	local mesh = tool:FindFirstChildWhichIsA("MeshPart", true)
	if not mesh then return false end

	local textureId = CW.Assets.weaponTextures[tool.Name]
	local original = mesh:GetAttribute(ORIGINAL_TEXTURE)
	if textureId then
		if original == nil then mesh:SetAttribute(ORIGINAL_TEXTURE, mesh.TextureID) end
		if mesh.TextureID ~= textureId then
			local ok, err = pcall(function() mesh.TextureID = textureId end)
			if not ok then CW.Warn("Could not apply texture to " .. tool.Name .. ": " .. tostring(err)) end
		end
	elseif original ~= nil then
		local ok, err = pcall(function() mesh.TextureID = original end)
		if ok then
			mesh:SetAttribute(ORIGINAL_TEXTURE, nil)
		else
			CW.Warn("Could not restore the original texture of " .. tool.Name .. ": " .. tostring(err))
		end
	end
	return true
end

--// Meshes, loaded once ---------------------------------------------------------------------------------------
-- Every mesh shown on a gun (the FAL/M700 ones and the custom ones) is a copy of a MeshPart made once per mesh with
-- the mesh already loaded, so its Size is final when it is set (no later load can change it).
local AssetService = game:GetService("AssetService")
-- mesh ID -> a loaded MeshPart to clone (false: it could not be loaded, not even after the tries again). Kept across
-- re-runs: it is a download.
local meshTemplates = CW.State.meshTemplates or {}
CW.State.meshTemplates = meshTemplates
local meshLoading = {} -- mesh ID -> true while it loads, or waits to be tried again
local meshTries = {}   -- mesh ID -> how many tries failed (cleared once it loads or the player picks it again)
-- A first join can be slow or throttled: a mesh that fails is tried again by itself after these many seconds, and
-- only after the last one is it given up (until the player picks it again).
local MESH_RETRY_DELAYS = { 2, 5, 12 }

-- Yields. A MeshPart with this mesh loaded, or nil and why.
local function loadMeshPart(meshId)
	local uri = "rbxassetid://" .. meshId
	local created, part = pcall(function() return AssetService:CreateMeshPartAsync(uri) end)
	if created and typeof(part) == "Instance" and part:IsA("MeshPart") then return part end
	local fresh = Instance.new("MeshPart")
	local assigned, err = pcall(function() fresh.MeshId = uri end)
	if not assigned then
		fresh:Destroy()
		return nil, tostring(created and "no mesh" or part) .. "; " .. tostring(err)
	end
	local deadline = os.clock() + 6
	while fresh.MeshSize == Vector3.zero and os.clock() < deadline do task.wait(0.1) end
	if fresh.MeshSize == Vector3.zero then
		fresh:Destroy()
		return nil, "it did not load in 6 s"
	end
	return fresh
end

-- Loads meshes in the background, then puts them on the guns (CW.reloadTextures) and tells the preview. A mesh that
-- fails stays "loading" while it waits to be tried again (MESH_RETRY_DELAYS); only then is it marked false.
local function requestMeshes(ids)
	local missing = {}
	for _, id in ipairs(ids) do
		if meshTemplates[id] == nil and not meshLoading[id] then
			meshLoading[id] = true
			table.insert(missing, id)
		end
	end
	if #missing == 0 then return end
	task.spawn(function()
		local settled = false -- a mesh loaded, or was given up: the guns and the preview change
		for _, id in ipairs(missing) do
			local loaded, part, why = pcall(loadMeshPart, id)
			if not loaded then part, why = nil, part end -- an error while loading is a failed try too
			if part then
				meshTemplates[id], meshTries[id], meshLoading[id] = part, nil, nil
				settled = true
			else
				local tries = (meshTries[id] or 0) + 1
				local retryIn = MESH_RETRY_DELAYS[tries]
				if retryIn then
					meshTries[id] = tries
					task.delay(retryIn, function()
						meshLoading[id] = nil
						requestMeshes({ id })
					end)
				else
					meshTemplates[id], meshTries[id], meshLoading[id] = false, nil, nil
					settled = true
					CW.Warn("Mesh " .. id .. " could not be loaded after " .. tries .. " tries: " .. tostring(why))
				end
			end
		end
		if not settled then return end
		if CW.reloadTextures then pcall(CW.reloadTextures) end
		if CW.onMeshLoaded then pcall(CW.onMeshLoaded) end
	end)
end

-- A mesh that was given up is tried again when the player picks it again.
function CW.retryMesh(meshId)
	if meshTemplates[meshId] == false then
		meshTemplates[meshId], meshTries[meshId] = nil, nil
	end
end

-- nil while the mesh loads (the gun keeps its pieces; it is built when the mesh is there) or without a Handle yet.
local function buildCustomMesh(tool, cfg)
	local handle = tool:FindFirstChild("Handle")
	local template = meshTemplates[cfg.meshId]
	if template == nil then requestMeshes({ cfg.meshId }) end
	if not (handle and template) then return nil end

	local mesh = template:Clone()
	mesh.Name       = cfg.meshName
	mesh.Material   = Enum.Material.SmoothPlastic
	mesh.Size       = cfg.size
	mesh.Anchored   = false
	mesh.CanCollide = false
	mesh.CanQuery   = false
	mesh.CanTouch   = false
	mesh.Massless   = true
	mesh.CFrame = handle.CFrame
		* CFrame.new(cfg.offset)
		* CFrame.Angles(math.rad(cfg.rotation.X), math.rad(cfg.rotation.Y), math.rad(cfg.rotation.Z))
	mesh.Parent = tool

	local weld = Instance.new("WeldConstraint")
	weld.Part0  = handle
	weld.Part1  = mesh
	weld.Parent = mesh
	CW.Log("Custom mesh built for " .. tool.Name)
	return mesh
end

-- Every BasePart of a piece (the piece itself and, for a Model, everything inside it).
local function forEachPart(piece, callback)
	if piece:IsA("BasePart") then callback(piece) end
	for _, descendant in ipairs(piece:GetDescendants()) do
		if descendant:IsA("BasePart") then callback(descendant) end
	end
end

local function hideOriginalPieces(tool, cfg, custom)
	for _, piece in ipairs(tool:GetChildren()) do
		if piece ~= custom and cfg.hide[piece.Name] then
			forEachPart(piece, function(part)
				if part:GetAttribute(ORIGINAL_TRANSPARENCY) == nil then
					part:SetAttribute(ORIGINAL_TRANSPARENCY, part.Transparency)
				end
				if part.Transparency ~= 1 then part.Transparency = 1 end
			end)
		end
	end
end

local function showOriginalPieces(tool)
	for _, descendant in ipairs(tool:GetDescendants()) do
		if descendant:IsA("BasePart") then
			local original = descendant:GetAttribute(ORIGINAL_TRANSPARENCY)
			if original ~= nil then
				descendant.Transparency = original
				descendant:SetAttribute(ORIGINAL_TRANSPARENCY, nil)
			end
		end
	end
end

local function applyCustomTexture(tool, cfg)
	local textureId = CW.Assets.weaponTextures[tool.Name]
	local custom = tool:FindFirstChild(cfg.meshName)
	if textureId then
		if not custom then custom = buildCustomMesh(tool, cfg) end
		if not custom then return false end -- no Handle yet, or the mesh is loading
		hideOriginalPieces(tool, cfg, custom)
		if custom.TextureID ~= textureId then custom.TextureID = textureId end
	else
		if custom then custom:Destroy() end
		showOriginalPieces(tool)
	end
	return true
end

--// Custom meshes (the Mesh list of each gun in the Guns tab) --------------------------------------------
-- A gun whose Meshes choice is one of its custom mesh IDs shows that mesh instead of its own: a MeshPart named
-- CW_Mesh, welded to the Handle, with the game's pieces hidden (the same bookkeeping as the FAL/M700 meshes above).
-- It is placed in the box the gun's own pieces fill around the Handle (the grip and the Muzzle included): its
-- longest side along the barrel, the middle one upright, scaled evenly to the gun's length. Then the Adjust saved
-- with its ID (see MESH_ADJUST) scales, moves and turns it from there, around its own center.
-- Texture: the gun's chosen texture, otherwise the one that came with the mesh (an accessory or a model brings one).
-- Until the mesh has loaded the gun keeps its own look, and a mesh that cannot be loaded leaves it that way.
-- The Muzzle (where the game starts a shot's tracer) goes along with the adjustment, and back when the mesh goes.
local MarketplaceService = game:GetService("MarketplaceService")
local MESH_PART = "CW_Mesh"
local MESH_ASSET_TYPE = 4
local OWN_MESHES = { [MESH_PART] = true } -- parts we add, never measured as the gun's own pieces
for _, cfg in pairs(CUSTOM_MESH_WEAPONS) do OWN_MESHES[cfg.meshName] = true end
local BOX_CORNERS = {}
for _, x in ipairs({ -1, 1 }) do
	for _, y in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -1, 1 }) do table.insert(BOX_CORNERS, Vector3.new(x, y, z)) end
	end
end

local function digitsOf(value)
	if type(value) ~= "string" then return nil end
	return value:match("^rbxassetid://(%d+)$") or value:match("[?&][iI][dD]=(%d+)") or value:match("^(%d+)$")
end

-- The first mesh inside an item (a MeshPart or a SpecialMesh), with the texture it uses: { Mesh, Texture } or nil.
local function meshInside(object)
	local function read(candidate)
		local meshId, textureId
		if candidate:IsA("MeshPart") then
			meshId, textureId = candidate.MeshId, candidate.TextureID
			local look = textureId == "" and candidate:FindFirstChildWhichIsA("SurfaceAppearance")
			if look then pcall(function() textureId = look.ColorMap end) end
		elseif candidate:IsA("FileMesh") then
			meshId, textureId = candidate.MeshId, candidate.TextureId
		end
		local mesh = digitsOf(meshId)
		return mesh and { Mesh = mesh, Texture = digitsOf(textureId) } or nil
	end
	local found = read(object)
	if found then return found end
	for _, descendant in ipairs(object:GetDescendants()) do
		found = read(descendant)
		if found then return found end
	end
	return nil
end

-- What a mesh ID shows (yields), as in the 3D viewer reference: a Mesh asset is the mesh itself; any other item (an
-- accessory, a gear, a model) is opened with game:GetObjects and its first mesh is used, with the texture that
-- comes with it. Returns { Mesh, Texture, Name (the item's name) } or nil and why.
function CW.resolveMeshAsset(id)
	local okInfo, info = pcall(function() return MarketplaceService:GetProductInfo(tonumber(id)) end)
	local assetType = okInfo and type(info) == "table" and tonumber(info.AssetTypeId) or nil
	local result = { Mesh = id }
	if assetType ~= MESH_ASSET_TYPE then
		local opened, objects = pcall(Exec.call, "GetObjects", 20, function() return game:GetObjects("rbxassetid://" .. id) end)
		if opened and type(objects) == "table" then
			for _, object in ipairs(objects) do
				local found = typeof(object) == "Instance" and meshInside(object)
				if found then
					result.Mesh, result.Texture = found.Mesh, found.Texture
					break
				end
			end
			-- The downloaded copy goes a moment later, so destroying a big item does not land on this frame.
			task.delay(1, function()
				for _, object in ipairs(objects) do pcall(function() object:Destroy() end) end
			end)
		end
		if assetType ~= nil and result.Mesh == id then
			return nil, "no mesh was found in this item (or the executor cannot open it)"
		end
	end
	local part, why = loadMeshPart(result.Mesh)
	if not part then return nil, why end
	meshTemplates[result.Mesh] = part
	if assetType ~= MESH_ASSET_TYPE and okInfo and type(info.Name) == "string" and info.Name ~= "" then
		result.Name = info.Name
	end
	return result
end

-- The mesh chosen for this gun (one of its custom mesh IDs), or nil for its own.
local function chosenMesh(gun)
	local selections = CW.Settings.ASSET_SELECTIONS.Meshes
	local selected = type(selections) == "table" and selections[gun]
	local id = type(selected) == "string" and selected:match("^id:(%d+)$")
	return id and CW.CustomIds.get("Meshes", gun, id) or nil
end

--// Per-mesh profiles ---------------------------------------------------------------------------------------
-- Each mesh of a gun (its own, "Default", or one of its custom mesh IDs, "id:123") keeps its texture, shoot sound,
-- reload sound, effect and fire point. The settings those already had (ASSET_SELECTIONS.Textures, the sound
-- changers, the TRACER_* maps) always hold the values of the mesh in use, so everything that reads them works as
-- before; choosing another mesh stores them in the profile of the one left and loads the profile of the new one
-- (CW.MeshProfiles.switch, set up after the sound changers). A mesh never chosen before starts from the game's own.
-- The fire point is the one value read from the profile itself (the mesh in use included): Fire = { x, y, z }, how
-- far the start of the tracers moves from where the gun's Muzzle would be, in the gun's space before Adjust Mesh
-- (so it stays on the same spot of the mesh when the mesh is resized, moved or turned).
local MeshProfiles = {}
CW.MeshProfiles = MeshProfiles
local FIRE_LIMIT = 3 -- studs, on each axis
local DEFAULT_MESH = "Default"
MeshProfiles.DEFAULT = DEFAULT_MESH

-- The mesh in use on a gun: "Default" or "id:123".
function MeshProfiles.keyOf(gun)
	local selections = CW.Settings.ASSET_SELECTIONS.Meshes
	local selected = type(selections) == "table" and selections[gun]
	return type(selected) == "string" and selected:match("^id:%d+$") and selected or DEFAULT_MESH
end

-- The profiles of one gun ({ [mesh] = profile }); with create, made when missing.
function MeshProfiles.ofGun(gun, create)
	if type(CW.Settings.MESH_PROFILES) ~= "table" then CW.Settings.MESH_PROFILES = {} end
	local all = CW.Settings.MESH_PROFILES
	local byMesh = all[gun]
	if type(byMesh) ~= "table" then
		if not create then return nil end
		byMesh = {}
		all[gun] = byMesh
	end
	return byMesh
end

function MeshProfiles.get(gun, key, create)
	local byMesh = MeshProfiles.ofGun(gun, create)
	if not byMesh then return nil end
	local profile = byMesh[key]
	if type(profile) ~= "table" then
		if not create then return nil end
		profile = {}
		byMesh[key] = profile
	end
	return profile
end

-- Drops a profile that has nothing left in it (and the gun's table when it is empty).
function MeshProfiles.tidy(gun, key)
	local byMesh = MeshProfiles.ofGun(gun, false)
	if not byMesh then return end
	if type(byMesh[key]) == "table" and next(byMesh[key]) == nil then byMesh[key] = nil end
	if next(byMesh) == nil then CW.Settings.MESH_PROFILES[gun] = nil end
end

-- The fire point offset of one mesh of a gun (Vector3.zero when it has none).
function MeshProfiles.fireOffset(gun, key)
	local profile = MeshProfiles.get(gun, key or MeshProfiles.keyOf(gun), false)
	local fire = profile and profile.Fire
	if type(fire) ~= "table" then return Vector3.zero end
	local x, y, z = tonumber(fire[1]), tonumber(fire[2]), tonumber(fire[3])
	if not (x and y and z) or x ~= x or y ~= y or z ~= z then return Vector3.zero end
	return Vector3.new(math.clamp(x, -FIRE_LIMIT, FIRE_LIMIT), math.clamp(y, -FIRE_LIMIT, FIRE_LIMIT),
		math.clamp(z, -FIRE_LIMIT, FIRE_LIMIT))
end

-- offset: a Vector3, or nil to put the fire point back where the game has it.
function MeshProfiles.setFireOffset(gun, key, offset)
	key = key or MeshProfiles.keyOf(gun)
	if typeof(offset) == "Vector3" and offset.Magnitude > 1e-4 then
		-- 4 decimals: Adjust Mesh scales the offset up to 4x, and the dot has to land where it was let go.
		local function round(n) return math.floor(math.clamp(n, -FIRE_LIMIT, FIRE_LIMIT) * 10000 + 0.5) / 10000 end
		MeshProfiles.get(gun, key, true).Fire = { round(offset.X), round(offset.Y), round(offset.Z) }
	else
		local profile = MeshProfiles.get(gun, key, false)
		if profile then profile.Fire = nil end
		MeshProfiles.tidy(gun, key)
	end
end

-- What a piece shows, in its own space: size and center. A mesh inside it (the FAL's blocks and wedges, the
-- Taser's and the M700's files) is scaled and moved by it, and a file mesh has a size of its own, whatever the
-- Part's: that one is known once the file is loaded. Returns the size, the center and the file still to load.
local function pieceShape(part)
	local mesh = part:FindFirstChildWhichIsA("DataModelMesh")
	if not mesh then return part.Size, Vector3.zero end
	local scale = Vector3.new(math.abs(mesh.Scale.X), math.abs(mesh.Scale.Y), math.abs(mesh.Scale.Z))
	if not (mesh:IsA("SpecialMesh") and mesh.MeshType == Enum.MeshType.FileMesh) then
		return part.Size * scale, mesh.Offset
	end
	local id = digitsOf(mesh.MeshId)
	local file = id and meshTemplates[id]
	if file then return file.MeshSize * scale, mesh.Offset end
	return part.Size, Vector3.zero, (id and file == nil) and id or nil
end

-- The box the gun's own pieces fill in the Handle's space (pieces hidden by us count as they were), together with
-- the grip (the Handle's center) and the Muzzle. Returns its center and size, and the files still to load.
local function gunBox(tool, handle)
	local low, high, pending = Vector3.zero, Vector3.zero, {}
	local function add(point)
		low, high = low:Min(point), high:Max(point)
	end
	local muzzle = tool:FindFirstChild("Muzzle")
	if muzzle and muzzle:IsA("BasePart") then add(handle.CFrame:PointToObjectSpace(muzzle.Position)) end
	for _, part in ipairs(tool:GetDescendants()) do
		if part:IsA("BasePart") and part ~= handle and part ~= muzzle and not OWN_MESHES[part.Name]
			and (part:GetAttribute(ORIGINAL_TRANSPARENCY) or part.Transparency) < 1 then
			local size, offset, missing = pieceShape(part)
			if missing then table.insert(pending, missing) end
			local relative = handle.CFrame:ToObjectSpace(part.CFrame) * CFrame.new(offset)
			for _, corner in ipairs(BOX_CORNERS) do add(relative * (size / 2 * corner)) end
		end
	end
	return (low + high) / 2, high - low, pending
end

-- The same box and where the Muzzle is (the Handle's space), measured on the game's copy of the gun
-- (ReplicatedStorage.Tools.Guns, what the game hands out). On the client a given tool lands empty and its parts come
-- after it (seen in Studio: 0 parts when it lands in the Backpack), so the tool itself can be measured half there;
-- that was a mesh sometimes coming back small after a respawn. Kept per gun once complete.
local gunShapes = {}
local function gunShape(tool, handle)
	local known = gunShapes[tool.Name]
	if known then return known.center, known.size, {}, known.muzzle end
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	local copy = guns and guns:FindFirstChild(tool.Name)
	local copyHandle = copy and copy:FindFirstChild("Handle")
	local source, sourceHandle = tool, handle
	if copyHandle then source, sourceHandle = copy, copyHandle end
	local center, size, pending = gunBox(source, sourceHandle)
	local muzzle = source:FindFirstChild("Muzzle")
	local muzzleAt = muzzle and muzzle:IsA("BasePart") and sourceHandle.CFrame:PointToObjectSpace(muzzle.Position) or nil
	if source == copy and #pending == 0 then gunShapes[tool.Name] = { center = center, size = size, muzzle = muzzleAt } end
	return center, size, pending, muzzleAt
end

-- Puts the Muzzle at a point of the Handle's space, through whatever holds it there: a weld's offset (Weld, Motor6D)
-- or nothing (anchored, as in a copy of the gun). A WeldConstraint is not used: one that came from the server keeps
-- the server's offset the first time the gun is equipped, whatever it was switched to in the Backpack (measured in
-- Studio: a new gun, the one you get after dying, went back to the game's place on the first equip). So it is
-- switched off on this client and our own Weld (CW_MuzzleWeld, an offset given outright) holds the Muzzle instead,
-- in the Backpack and in the hand alike. The Muzzle's first place is kept on it.
local MUZZLE_ORIGIN = "CW_MuzzleOrigin"
local MUZZLE_WELD = "CW_MuzzleWeld"
local function placeMuzzle(tool, handle, position)
	local muzzle = tool:FindFirstChild("Muzzle")
	if not (muzzle and muzzle:IsA("BasePart") and position) then return end
	local own = muzzle:FindFirstChild(MUZZLE_WELD)
	local holder = own and own:IsA("Weld") and own.Part0 == handle and own.Part1 == muzzle and own or nil
	local constraints = {}
	for _, joint in ipairs(tool:GetDescendants()) do
		local isConstraint, isJoint = joint:IsA("WeldConstraint"), joint:IsA("JointInstance")
		if (isConstraint or isJoint) and joint ~= holder and joint.Part0 and joint.Part1
			and (joint.Part0 == muzzle or joint.Part1 == muzzle) then
			if isConstraint then
				if joint.Enabled then table.insert(constraints, joint) end
			elseif not holder then
				holder = joint
			end
		end
	end
	-- A weld's offsets say where the Muzzle is before its CFrame catches up
	local current = muzzle.CFrame
	if holder then
		current = holder.Part1 == muzzle and holder.Part0.CFrame * holder.C0 * holder.C1:Inverse()
			or holder.Part1.CFrame * holder.C1 * holder.C0:Inverse()
	end
	local relative = handle.CFrame:ToObjectSpace(current)
	if muzzle:GetAttribute(MUZZLE_ORIGIN) == nil then muzzle:SetAttribute(MUZZLE_ORIGIN, relative.Position) end
	for _, constraint in ipairs(constraints) do
		constraint.Enabled = false
		-- the server switching it back on would have it pull against the weld that holds the Muzzle now: it goes
		-- off again (one watch each)
		if not constraint:GetAttribute(MUZZLE_WELD) then
			constraint:SetAttribute(MUZZLE_WELD, true)
			constraint:GetPropertyChangedSignal("Enabled"):Connect(function()
				if constraint.Enabled then constraint.Enabled = false end
			end)
		end
	end
	if #constraints > 0 and not holder then
		local weld = Instance.new("Weld")
		weld.Name = MUZZLE_WELD
		weld.Part0, weld.Part1 = handle, muzzle
		weld.C0 = relative
		weld.Parent = muzzle
		holder = weld
	end
	if (relative.Position - position).Magnitude < 1e-3 then return end
	local target = handle.CFrame * CFrame.new(position) * relative.Rotation
	if not holder then
		muzzle.CFrame = target
	elseif holder.Part1 == muzzle then
		holder.C0 = holder.Part0.CFrame:ToObjectSpace(target) * holder.C1
	else
		holder.C1 = holder.Part1.CFrame:ToObjectSpace(target) * holder.C0
	end
end

local function restoreMuzzle(tool, handle)
	local muzzle = tool:FindFirstChild("Muzzle")
	local origin = muzzle and muzzle:GetAttribute(MUZZLE_ORIGIN)
	if typeof(origin) ~= "Vector3" or not handle then return end
	placeMuzzle(tool, handle, origin)
	muzzle:SetAttribute(MUZZLE_ORIGIN, nil)
end

-- The turn that lays the mesh's longest side along the barrel (the Handle's -Z, toward the Muzzle), the middle one
-- upright and the shortest across, as the game's own gun meshes sit. Returns it and the longest side.
local function meshRotation(meshSize)
	local axes = { { Vector3.xAxis, meshSize.X }, { Vector3.yAxis, meshSize.Y }, { Vector3.zAxis, meshSize.Z } }
	table.sort(axes, function(a, b) return a[2] < b[2] end)
	local across, up, along = axes[1][1], axes[2][1], axes[3][1]
	local side = across:Cross(up):Dot(along) > 0 and -1 or 1 -- keeps it a turn, not a mirror
	return CFrame.fromMatrix(Vector3.zero, across * side, up, -along):Inverse(), axes[3][2]
end

local function hideAllPieces(tool, keep)
	for _, part in ipairs(tool:GetDescendants()) do
		if part:IsA("BasePart") and part ~= keep and part.Name ~= "Handle" and part.Name ~= "Muzzle"
			and part.Transparency < 1 then
			if part:GetAttribute(ORIGINAL_TRANSPARENCY) == nil then part:SetAttribute(ORIGINAL_TRANSPARENCY, part.Transparency) end
			part.Transparency = 1
		end
	end
end

local function removeCustomMesh(tool)
	local part = tool:FindFirstChild(MESH_PART)
	if not part then return end
	part:Destroy()
	showOriginalPieces(tool)
	restoreMuzzle(tool, tool:FindFirstChild("Handle"))
end

-- A custom mesh's Adjust values, every field filled in.
local function adjustOf(entry)
	local adjust = {}
	for field, limits in pairs(CW.MeshAdjust) do
		adjust[field] = entry and type(entry.Adjust) == "table" and tonumber(entry.Adjust[field]) or limits[3]
	end
	return adjust
end

-- Where a custom mesh goes in the Handle's space: the point its center is moved to, and its turn. The Handle's -Z
-- is forward; a positive Turn or Roll goes to the right, a positive Tilt raises the nose.
local function adjustPlacement(center, adjust)
	return center + Vector3.new(adjust.Right, adjust.Up, -adjust.Forward),
		CFrame.fromOrientation(math.rad(adjust.Tilt), math.rad(-adjust.Turn), math.rad(-adjust.Roll))
end

-- The fire point of a mesh in the Handle's space, from the gun's own Muzzle (origin), the box the mesh is fitted to
-- (center) and the mesh's offset (MeshProfiles): the same size, move and turn as the mesh. entry nil: the gun's own.
local function firePoint(origin, center, entry, offset)
	if not entry then return origin + offset end
	local adjust = adjustOf(entry)
	local moved, turned = adjustPlacement(center, adjust)
	return moved + turned:VectorToWorldSpace((origin - center + offset) * adjust.Size)
end

-- The game's copy of a gun (ReplicatedStorage.Tools.Guns), or nil.
local function gameGun(gun)
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	local copy = guns and guns:FindFirstChild(gun)
	return copy and copy:IsA("Tool") and copy or nil
end

-- For the fire point editor: the offset that puts the fire point of the gun's mesh in use at a point of the Handle's
-- space, saved in that mesh's profile. Returns false when the gun has no Muzzle to start from.
function CW.setFirePointAt(gun, point)
	local copy = gameGun(gun)
	local handle = copy and copy:FindFirstChild("Handle")
	if not (handle and typeof(point) == "Vector3") then return false end
	local center, _, _, origin = gunShape(copy, handle)
	if typeof(origin) ~= "Vector3" then return false end
	local key = MeshProfiles.keyOf(gun)
	local entry = key ~= DEFAULT_MESH and chosenMesh(gun) or nil
	local offset = point - origin
	if entry then
		local adjust = adjustOf(entry)
		local moved, turned = adjustPlacement(center, adjust)
		offset = turned:VectorToObjectSpace(point - moved) / math.max(adjust.Size, 1e-3) - (origin - center)
	end
	MeshProfiles.setFireOffset(gun, entry and key or DEFAULT_MESH, offset)
	return true
end

-- Returns false while the mesh cannot be shown: no Handle yet, the mesh (or a file the gun's size depends on) is
-- loading, or it could not be loaded.
local function applyCustomMesh(tool, entry)
	local handle = tool:FindFirstChild("Handle")
	if not handle then return false end
	local meshId = entry.Mesh or entry.Id
	local adjust = adjustOf(entry)
	local offset = MeshProfiles.fireOffset(tool.Name, CW.CustomIds.selectionOf(entry.Id))
	local key = string.format("%s|%.3f|%.3f|%.3f|%.3f|%.2f|%.2f|%.2f|%.4f|%.4f|%.4f", meshId, adjust.Size, adjust.Right,
		adjust.Up, adjust.Forward, adjust.Turn, adjust.Tilt, adjust.Roll, offset.X, offset.Y, offset.Z)
	local part = tool:FindFirstChild(MESH_PART)
	if part and part:GetAttribute("CW_MeshKey") ~= key then
		part:Destroy()
		part = nil
	end
	if not part then
		local template = meshTemplates[meshId]
		local center, box, pending, muzzleAt = gunShape(tool, handle)
		if template == nil then table.insert(pending, meshId) end
		requestMeshes(pending)
		if not template or #pending > 0 then return false end

		local cfg = CUSTOM_MESH_WEAPONS[tool.Name]
		local textureMesh = cfg and tool:FindFirstChild(cfg.meshName)
		if textureMesh then textureMesh:Destroy() end
		local rotation, longest = meshRotation(template.MeshSize)
		local moved, turned = adjustPlacement(center, adjust)
		part = template:Clone()
		part.Name = MESH_PART
		part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.Massless = false, false, false, false, true
		part.Size = template.MeshSize * (box.Z / math.max(longest, 1e-3)) * adjust.Size
		part.CFrame = handle.CFrame * CFrame.new(moved) * turned * rotation
		part:SetAttribute("CW_MeshKey", key)
		-- The Muzzle goes where the same size, move and turn take it (from the gun's own place for it, plus the
		-- mesh's fire point offset).
		local muzzle = tool:FindFirstChild("Muzzle")
		local origin = muzzle and muzzle:GetAttribute(MUZZLE_ORIGIN) or muzzleAt
		if typeof(origin) == "Vector3" then
			part:SetAttribute("CW_MuzzleAt", firePoint(origin, center, entry, offset))
		end
		part.Parent = tool
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1 = handle, part
		weld.Parent = part
	end
	local texture = CW.Assets.weaponTextures[tool.Name] or (entry.Texture and "rbxassetid://" .. entry.Texture) or ""
	if part.TextureID ~= texture then pcall(function() part.TextureID = texture end) end
	hideAllPieces(tool, part)
	placeMuzzle(tool, handle, part:GetAttribute("CW_MuzzleAt"))
	return true
end

-- Mesh first (when one is chosen and ready), otherwise the gun's own pieces with its texture. Returns false when
-- the tool is not complete yet (no Handle, or no MeshPart for its texture); watchTool puts it on as the parts come.
local function applyLook(tool)
	local entry = chosenMesh(tool.Name)
	if entry and applyCustomMesh(tool, entry) then return true end
	removeCustomMesh(tool)
	local textured = true
	if TEXTURABLE[tool.Name] then
		local cfg = CUSTOM_MESH_WEAPONS[tool.Name]
		if cfg then textured = applyCustomTexture(tool, cfg) else textured = applyRegularTexture(tool) end
	end
	-- The gun's own mesh: its fire point offset, if it has one (a custom mesh still loading keeps the game's).
	local handle = tool:FindFirstChild("Handle")
	local offset = entry == nil and MeshProfiles.fireOffset(tool.Name, DEFAULT_MESH) or Vector3.zero
	if handle and offset.Magnitude > 1e-4 then
		local muzzle = tool:FindFirstChild("Muzzle")
		local _, _, _, muzzleAt = gunShape(tool, handle)
		local origin = muzzle and muzzle:GetAttribute(MUZZLE_ORIGIN) or muzzleAt
		if typeof(origin) == "Vector3" then placeMuzzle(tool, handle, firePoint(origin, nil, nil, offset)) end
	elseif handle then
		restoreMuzzle(tool, handle)
	end
	return textured and (entry == nil or tool:FindFirstChild("Handle") ~= nil)
end

-- Every gun that can get a mesh or a texture: the texturable ones and every gun with a ToolProperties module.
local LOOK_WEAPONS = table.clone(TEXTURABLE)
for _, name in ipairs(SOUND_WEAPONS) do LOOK_WEAPONS[name] = true end

-- On the client a given tool lands empty and its parts come after it, so a tool we look after puts its look on
-- again whenever a part (or a weld) arrives in it, once per frame: late pieces get hidden or textured too.
-- Kept across re-runs (the handler looks the code up through CW), so a tool is never watched twice.
local watchedTools = CW.State.watchedTools or setmetatable({}, { __mode = "k" })
CW.State.watchedTools = watchedTools
local function watchTool(tool)
	if watchedTools[tool] then return end
	watchedTools[tool] = true
	local queued = false
	tool.DescendantAdded:Connect(function(added)
		if queued or not (added:IsA("BasePart") or added:IsA("JointInstance") or added:IsA("WeldConstraint")) then return end
		queued = true
		task.defer(function()
			queued = false
			local apply = CW.applyWeaponLook
			if apply and tool.Parent then apply(tool) end
		end)
	end)
end

local function applyToContainer(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("Tool") and LOOK_WEAPONS[child.Name] then
			watchTool(child)
			applyLook(child)
		end
	end
end

-- Looked up through CW at call time, so the latest run's code is the one that runs. Also used on a copy of the
-- gun for the Guns tab preview, so the preview shows exactly what the gun in your hand shows.
CW.applyWeaponLook = function(tool)
	if tool:IsA("Tool") and LOOK_WEAPONS[tool.Name] then return applyLook(tool) end
	return true
end
CW.applyWeaponTexture = CW.applyWeaponLook

-- Puts the current look on the guns you carry and hold, without loading the textures again: what a mesh
-- adjustment needs on every step of a slider.
function CW.reapplyLooks()
	local backpack = LocalPlayer:FindFirstChild("Backpack")
	if backpack then applyToContainer(backpack) end
	if LocalPlayer.Character then applyToContainer(LocalPlayer.Character) end
end

-- A copy of the gun as it looks in your hand (its mesh and its texture), for the preview in the Guns tab: a Model in
-- the Handle's space (the barrel along -Z) with only what shows, anchored. Also returns the box of the gun's own pieces
-- (center, size), which the preview frames, so a mesh made bigger or moved shows as such, and where the Muzzle is (it
-- moves with the mesh). A file mesh inside a piece (the Taser's) has its size known once the file has loaded; then
-- CW.onMeshLoaded redraws the preview. nil when the game has no such gun.
-- With a chosen mesh that is not on the copy, the last value says why: "loading" (no Model then: the gun's own pieces
-- would show for a moment and then change) or "failed" (the gun's own pieces, as on the guns, and no Muzzle point,
-- which would be the gun's and not the mesh's).
function CW.weaponPreview(gun)
	local tools = ReplicatedStorage:FindFirstChild("Tools")
	local guns = tools and tools:FindFirstChild("Guns")
	local source = guns and guns:FindFirstChild(gun)
	local tool = source and source:IsA("Tool") and source:Clone()
	local handle = tool and tool:FindFirstChild("Handle")
	if not handle then
		if tool then tool:Destroy() end
		return nil
	end
	pcall(applyLook, tool)
	local center, size, pending = gunShape(tool, handle)
	requestMeshes(pending)
	local entry = chosenMesh(gun)
	local meshState = nil
	if entry and not tool:FindFirstChild(MESH_PART) then
		meshState = meshTemplates[entry.Mesh or entry.Id] == false and "failed" or "loading"
	end
	if meshState == "loading" then
		tool:Destroy()
		return nil, nil, nil, nil, meshState
	end
	local muzzle = tool:FindFirstChild("Muzzle")
	local fireAt = meshState == nil and muzzle and muzzle:IsA("BasePart") and handle.CFrame:PointToObjectSpace(muzzle.Position) or nil

	local model = Instance.new("Model")
	model.Name = gun
	local shown = {}
	for _, part in ipairs(tool:GetDescendants()) do
		if part:IsA("BasePart") and part ~= handle and part.Transparency < 1 then
			table.insert(shown, { part, handle.CFrame:ToObjectSpace(part.CFrame) })
		end
	end
	for _, item in ipairs(shown) do item[1].Parent = model end
	for _, inner in ipairs(model:GetDescendants()) do
		if inner:IsA("JointInstance") or inner:IsA("WeldConstraint") or inner:IsA("Constraint")
			or inner:IsA("LuaSourceContainer") or (inner:IsA("BasePart") and inner.Transparency >= 1) then
			inner:Destroy()
		end
	end
	for _, item in ipairs(shown) do
		item[1].Anchored = true
		item[1].CFrame = item[2]
	end
	tool:Destroy()
	return model, center, size:Max(Vector3.one * 0.05), fireAt, meshState
end

-- The chosen meshes of every gun (and the FAL/M700 texture meshes in use) start loading at once, while the loading
-- screen is up, so the guns and the Guns tab have them from the start. CW.waitForMeshes(seconds) yields until they
-- have loaded or been given up, or the time is out (one still being tried again then keeps loading after it).
local preloading = {}
function CW.preloadMeshes()
	local ids = {}
	for gun in pairs(LOOK_WEAPONS) do
		local entry = chosenMesh(gun)
		if entry then table.insert(ids, entry.Mesh or entry.Id) end
		local copy = entry and gameGun(gun)
		local handle = copy and copy:FindFirstChild("Handle")
		if handle then
			local _, _, pending = gunShape(copy, handle) -- the file meshes of its pieces size the custom mesh
			for _, id in ipairs(pending) do table.insert(ids, id) end
		end
		local cfg = CUSTOM_MESH_WEAPONS[gun]
		if cfg and CW.Assets.weaponTextures and CW.Assets.weaponTextures[gun] then table.insert(ids, cfg.meshId) end
	end
	for _, id in ipairs(ids) do preloading[id] = true end
	requestMeshes(ids)
end
function CW.waitForMeshes(seconds)
	local deadline = os.clock() + (seconds or 8)
	while os.clock() < deadline do
		local waiting = false
		for id in pairs(preloading) do
			if meshTemplates[id] == nil then
				waiting = true
				break
			end
		end
		if not waiting then break end
		task.wait(0.1)
	end
	table.clear(preloading)
end

-- A tool may land before its parts: watchTool puts the look on again as they come.
local function monitor(container, key)
	CW.track(key, container.ChildAdded:Connect(function(child)
		if not (child:IsA("Tool") and LOOK_WEAPONS[child.Name]) then return end
		watchTool(child)
		local apply = CW.applyWeaponLook
		if apply then apply(child) end
	end))
	applyToContainer(container)
end

local function reloadTexturesAndApply()
	local loadedTextures = {}
	local toPreload = {}
	for _, weaponName in ipairs(WEAPON_LIST) do
		local filePath = CW.Library.selectedPath("Textures", weaponName)
		if filePath then
			local ok, asset
			if filePath:match("^rbxassetid://%d+$") then
				ok, asset = true, filePath -- a custom ID: already an engine asset
			else
				ok, asset = pcall(getcustomasset, filePath)
			end
			if ok and asset then
				loadedTextures[weaponName] = asset
				table.insert(toPreload, asset)
			else
				CW.Warn("Could not load selected texture for " .. weaponName)
			end
		end
	end
	CW.Assets.weaponTextures = loadedTextures

	if #toPreload > 0 then
		task.spawn(function()
			pcall(function() ContentProvider:PreloadAsync(toPreload) end)
		end)
	end

	CW.reapplyLooks()
end
CW.reloadTextures = reloadTexturesAndApply
reloadTexturesAndApply()
CW.preloadMeshes()

-- Monitors are (re)created on every run, so a re-run replaces the old ones. The Backpack is
-- recreated on every respawn, so the player is always watched for a new one.
do
	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then monitor(backpack, "textureBackpack") end
	CW.track("textureBackpackWait", LocalPlayer.ChildAdded:Connect(function(child)
		if child:IsA("Backpack") then monitor(child, "textureBackpack") end
	end))

	CW.track("textureCharacterAdded", LocalPlayer.CharacterAdded:Connect(function(character)
		monitor(character, "textureCharacter")
	end))

	if LocalPlayer.Character then
		monitor(LocalPlayer.Character, "textureCharacter")
	end
end
end)


runModule("Tracers", function()
-- Tracers.lua
local CW = getgenv().__CW_CORE_STATE

local Workspace         = game:GetService("Workspace")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = CW.LocalPlayer

-- (boolOr, numOr and _cfg come from the top of the script.)

local function colorOr(v, default)
	if typeof(v) == "Color3" then return v end
	return default
end

local function unitOr(v, default) -- a number from 0 to 1 (transparency)
	return math.clamp(numOr(v, default), 0, 1)
end

-- The Sniper (M700) and the Taser have a tracer of their own. Every other gun has one too (the
-- TRACER_GUN_* maps below). A kind's width, lifetime and transparency only apply while its ENABLED
-- setting is on; its colour also applies to the game's own tracer. The starting values are the
-- game's own (colour, width, how long the fade takes, starting transparency).
local KIND_DEFAULTS = {
	Sniper = { color = Color3.fromRGB(163, 162, 165), width = 0.17, lifetime = 2.8, transparency = 0.5 },
	Taser  = { color = Color3.fromRGB(4, 175, 236),   width = 0.2,  lifetime = 0.8, transparency = 0.5 },
}
local KINDS = {
	Sniper = { prefix = "TRACER_SNIPER_", original = "_originalCreateSniper" },
	Taser  = { prefix = "TRACER_TASER_",  original = "_originalCreateTaser", surfaceLight = true },
}
for kind, info in pairs(KINDS) do
	local defaults = KIND_DEFAULTS[kind]
	local prefix = info.prefix
	CW.Settings[prefix .. "ENABLED"]      = boolOr(_cfg[prefix .. "ENABLED"], false)
	CW.Settings[prefix .. "COLOR"]        = colorOr(_cfg[prefix .. "COLOR"], defaults.color)
	CW.Settings[prefix .. "WIDTH"]        = numOr(_cfg[prefix .. "WIDTH"], defaults.width, 0.01)
	CW.Settings[prefix .. "LIFETIME"]     = numOr(_cfg[prefix .. "LIFETIME"], defaults.lifetime, 0.01)
	CW.Settings[prefix .. "TRANSPARENCY"] = unitOr(_cfg[prefix .. "TRANSPARENCY"], defaults.transparency)
end

-- Per-gun tracers (every gun except the Sniper and the Taser, which have their own above). Each setting
-- is a map from the gun's name to a value, so it is saved as it is: ENABLED[gun] = true, COLOR[gun] and
-- GLOW[gun] = "rrggbb", WIDTH[gun], LIFETIME[gun], TRANSPARENCY[gun], LIGHT[gun] = true. A field that
-- was never set for a gun starts from CW.GunTracerDefaults. A gun without ENABLED keeps the game's tracer.
-- OTHERS[gun] = true (every gun, the M700 and the Taser included) also gives other players' shots with that gun
-- its tracer, on your screen only.
local function copyMap(source)
	local map = {}
	if type(source) == "table" then
		for key, value in pairs(source) do
			if type(key) == "string" then map[key] = value end
		end
	end
	return map
end
for _, field in ipairs({ "ENABLED", "COLOR", "GLOW", "WIDTH", "LIFETIME", "TRANSPARENCY", "LIGHT", "OTHERS" }) do
	CW.Settings["TRACER_GUN_" .. field] = copyMap(_cfg["TRACER_GUN_" .. field])
end

CW.Defaults = CW.Defaults or {}
for _, key in ipairs({
	"TRACER_SNIPER_ENABLED", "TRACER_SNIPER_COLOR", "TRACER_SNIPER_WIDTH", "TRACER_SNIPER_LIFETIME", "TRACER_SNIPER_TRANSPARENCY",
	"TRACER_TASER_ENABLED", "TRACER_TASER_COLOR", "TRACER_TASER_WIDTH", "TRACER_TASER_LIFETIME", "TRACER_TASER_TRANSPARENCY",
}) do
	CW.Defaults[key] = CW.Settings[key]
end

-- A tracer is yours when you are shooting AND it starts at your own muzzle. Checking only the
-- attribute would also claim the tracers of other players that arrive while you shoot.
-- Returns the Tool you fired it with (its name is the gun's name), or nil.
local function localShotTool(startPos)
	local char = LocalPlayer.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool or tool:GetAttribute("Local_IsShooting") ~= true then return nil end
	local muzzle = tool:FindFirstChild("Muzzle")
	if muzzle ~= nil and (muzzle.Position - startPos).Magnitude < 2 then return tool end
	return nil
end

local function isLocalPlayerShot(startPos)
	return localShotTool(startPos) ~= nil
end

-- Which gun made a tracer that is NOT yours. The game tells the client only where the tracer starts
-- and ends and which kind it is (Taser, Sniper or bullet), never who fired it. So: among the players
-- holding a gun of that kind, the one whose Muzzle or Head is nearest to the start. Nothing within
-- MATCH_RADIUS means no match, and the shared Bullet Tracers settings are used instead.
-- (The start is computed by the server; how close it lies to the shooter's Muzzle on this client
-- depends on lag and movement, hence the generous radius. Set CW_CONFIG.TRACER_DEBUG = true to print
-- every match and see how close they are.)
local MATCH_RADIUS = 14
local KIND_BY_NAME = { M700 = "Sniper", Taser = "Taser" } -- used when a tool has no Behavior attribute yet

local function toolKind(tool)
	local behavior = tool:GetAttribute("Behavior")
	if behavior == "Sniper" or behavior == "Taser" then return behavior end
	return KIND_BY_NAME[tool.Name] or "Bullet"
end

local lastMatch = { pos = nil, time = 0, tool = nil } -- the pellets of one shotgun shot share a start

local function findShooterTool(startPos, kind)
	local now = os.clock()
	if lastMatch.pos == startPos and now - lastMatch.time < 0.1 and lastMatch.tool and lastMatch.tool.Parent then
		return lastMatch.tool
	end

	local bestTool, bestPlayer, bestDistance, secondDistance
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local tool = character and character:FindFirstChildOfClass("Tool")
		local muzzle = tool and tool:FindFirstChild("Muzzle") -- only guns have one
		if muzzle and toolKind(tool) == kind then
			local distance = (muzzle.Position - startPos).Magnitude
			local head = character:FindFirstChild("Head")
			if head then distance = math.min(distance, (head.Position - startPos).Magnitude) end
			if bestDistance == nil or distance < bestDistance then
				secondDistance = bestDistance
				bestTool, bestPlayer, bestDistance = tool, player, distance
			elseif secondDistance == nil or distance < secondDistance then
				secondDistance = distance
			end
		end
	end

	local matched = bestTool ~= nil and bestDistance <= MATCH_RADIUS
	if _cfg.TRACER_DEBUG == true then
		print(string.format("[CW] tracer (%s) from %s: %s, nearest holder %s studs away, next %s",
			kind, tostring(startPos), matched and (bestTool.Name .. " held by " .. bestPlayer.Name) or "no match",
			bestDistance and string.format("%.1f", bestDistance) or "-",
			secondDistance and string.format("%.1f", secondDistance) or "-"))
	end

	if not matched then return nil end
	lastMatch.pos, lastMatch.time, lastMatch.tool = startPos, now, bestTool
	return bestTool
end

local gunColorCache = {}
local function gunColor(hex, fallback)
	if type(hex) ~= "string" then return fallback end
	local cached = gunColorCache[hex]
	if cached == nil then
		local ok, color = pcall(Color3.fromHex, hex)
		cached = ok and typeof(color) == "Color3" and color or false
		gunColorCache[hex] = cached
	end
	return cached or fallback
end

local function gunValue(field, weapon)
	local map = CW.Settings["TRACER_GUN_" .. field]
	if type(map) ~= "table" then return nil end
	return map[weapon]
end

-- Whether other players' shots with this gun get its tracer too (the gun's own "Apply To Other Players Locally").
local function othersFor(weapon)
	return gunValue("OTHERS", weapon) == true
end
local KIND_GUN = { Sniper = "M700", Taser = "Taser" }

local function hasGunTracers()
	local map = CW.Settings.TRACER_GUN_ENABLED
	if type(map) ~= "table" then return false end
	for _, enabled in pairs(map) do
		if enabled == true then return true end
	end
	return false
end

-- The look of one gun's tracer, or nil when that gun has no tracer of its own turned on.
local function gunStyle(weapon)
	if gunValue("ENABLED", weapon) ~= true then return nil end
	local D = CW.GunTracerDefaults
	return {
		color        = gunColor(gunValue("COLOR", weapon), D.color),
		glow         = gunColor(gunValue("GLOW", weapon), D.glow),
		width        = math.max(0.01, tonumber(gunValue("WIDTH", weapon)) or D.width),
		life         = math.max(0.01, tonumber(gunValue("LIFETIME", weapon)) or D.life),
		transparency = math.clamp(tonumber(gunValue("TRANSPARENCY", weapon)) or D.transparency, 0, 1),
		light        = gunValue("LIGHT", weapon) == true,
	}
end

-- The style for a bullet tracer that starts at startPos: the firing gun's own, or nil.
-- Your own shots read the gun straight from the Tool in your hand (exact). Another player's shot gets the style
-- of the gun it was matched to only when that gun's "apply to others" is on.
local function bulletShotStyle(startPos)
	local tool = localShotTool(startPos)
	if not tool then
		local others = CW.Settings.TRACER_GUN_OTHERS
		if type(others) ~= "table" or next(others) == nil then return nil end
		tool = findShooterTool(startPos, "Bullet")
		if not (tool and othersFor(tool.Name)) then return nil end
	end
	return gunStyle(tool.Name)
end

-- Part pool: tracer parts are reused instead of created and destroyed for every bullet
-- (shotgun pellets and automatic weapons make many per second). The PointLight is optional
-- (a gun's LIGHT setting, off by default): it is created once per pooled part and only switched
-- on or off afterwards, so enabling it never creates a new light per bullet.
local MAX_POOL = 48
local pool = CW.State.tracerPool
if not pool then
	pool = {}
	CW.State.tracerPool = pool
end

local function newTracerPart()
	local part = Instance.new("Part")
	part.Anchored   = true
	part.CanCollide = false
	part.CanQuery   = false
	part.CanTouch   = false
	part.CastShadow = false
	part.Material   = Enum.Material.Neon
	return part
end

local function acquirePart(parent)
	while #pool > 0 do
		local part = table.remove(pool)
		if pcall(function() part.Parent = parent end) then return part end
	end
	local part = newTracerPart()
	part.Parent = parent
	return part
end

-- A pooled part may still carry a light from a previous use: lights are switched off on every
-- acquire and only the tracer that needs one switches it back on.
local function resetLights(part)
	for _, name in ipairs({ "CW_Light", "CW_Surface" }) do
		local light = part:FindFirstChild(name)
		if light then light.Enabled = false end
	end
end

local function releasePart(part)
	pcall(function() part.Parent = nil end)
	if #pool < MAX_POOL then
		pool[#pool + 1] = part
	else
		pcall(function() part:Destroy() end)
	end
end

-- style: { color, glow, width, life, transparency, light } of one gun (see gunStyle).
local function createEnergyTracer(startPos, endPos, style)
	local camera = Workspace.CurrentCamera
	if not camera then error("no current camera", 0) end

	local color        = style.color
	local glowColor    = style.glow
	local width        = style.width
	local life         = style.life
	local transparency = style.transparency

	local distance = (startPos - endPos).Magnitude
	local midpoint = (startPos + endPos) / 2

	local core = acquirePart(camera)
	resetLights(core)
	core.Color        = color
	core.Size         = Vector3.new(width, width, distance)
	core.CFrame       = CFrame.new(midpoint, endPos)
	core.Transparency = transparency

	local light = core:FindFirstChild("CW_Light")
	if style.light then
		if not light then
			light = Instance.new("PointLight")
			light.Name       = "CW_Light"
			light.Range      = 8
			light.Brightness = 2
			light.Parent     = core
		end
		light.Color   = color
		light.Enabled = true
	elseif light then
		light.Enabled = false
	end

	local glow = acquirePart(camera)
	resetLights(glow)
	glow.Color        = glowColor
	glow.Size         = Vector3.new(width * 2, width * 2, distance)
	glow.CFrame       = core.CFrame
	-- The glow is always fainter than the core: at the default core transparency (0.1) it is 0.6.
	glow.Transparency = 1 - (1 - transparency) * (0.4 / 0.9)

	TweenService:Create(core, TweenInfo.new(life), { Transparency = 1 }):Play()
	TweenService:Create(glow, TweenInfo.new(life), { Transparency = 1 }):Play()

	-- Returned to the pool just after the fade ends.
	task.delay(life + 0.05, function()
		releasePart(core)
		releasePart(glow)
	end)
end

-- Sniper and taser tracers with their own settings. The game's own functions cannot be adjusted
-- after the fact (they start a transparency tween that cannot be stopped or lengthened), so the
-- tracer is drawn here instead, from the same ingredients: a neon part between the muzzle and the
-- hit that fades out with a Quad "In" tween, plus, for the taser, a SurfaceLight that fades with it.
local function createKindTracer(kind, startPos, endPos)
	local camera = Workspace.CurrentCamera
	if not camera then error("no current camera", 0) end

	local info = KINDS[kind]
	local color        = CW.Settings[info.prefix .. "COLOR"]
	local width        = CW.Settings[info.prefix .. "WIDTH"]
	local life         = CW.Settings[info.prefix .. "LIFETIME"]
	local transparency = CW.Settings[info.prefix .. "TRANSPARENCY"]

	local distance = (startPos - endPos).Magnitude
	local part = acquirePart(camera)
	resetLights(part)
	part.Color        = color
	part.Size         = Vector3.new(width, width, distance)
	part.CFrame       = CFrame.new((startPos + endPos) / 2, endPos)
	part.Transparency = transparency

	local fade = TweenInfo.new(life, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(part, fade, { Transparency = 1 }):Play()

	if info.surfaceLight then
		local light = part:FindFirstChild("CW_Surface")
		if not light then
			light = Instance.new("SurfaceLight")
			light.Name  = "CW_Surface"
			light.Range = 7
			light.Face  = Enum.NormalId.Bottom
			light.Angle = 180
			light.Parent = part
		end
		light.Color      = color
		light.Brightness = 5
		light.Enabled    = true
		TweenService:Create(light, fade, { Brightness = 0 }):Play()
	end

	-- Returned to the pool just after the fade ends.
	task.delay(life + 0.05, releasePart, part)
end

-- Without the kind's own tracer the taser and sniper keep the game's width, fade and lifetime and
-- only their color changes (to the kind's color setting, once it is not the game's own color).
-- The game's functions create one part named "RayPart" and parent it to the camera, so the new
-- tracer is the RayPart that was not there before the call.
local function snapshotRayParts()
	local seen = {}
	local camera = Workspace.CurrentCamera
	if camera then
		for _, child in ipairs(camera:GetChildren()) do
			if child.Name == "RayPart" then seen[child] = true end
		end
	end
	return seen
end

local function recolorNewRayParts(before, color)
	local camera = Workspace.CurrentCamera
	if not camera then return end
	for _, child in ipairs(camera:GetChildren()) do
		if child.Name == "RayPart" and not before[child] then
			child.Color = color
			local light = child:FindFirstChildOfClass("SurfaceLight") -- the taser has one
			if light then light.Color = color end
		end
	end
end

-- The colour to give the game's own tracer of this kind, or nil to leave it alone: the colour setting
-- is still the game's own, or the shot is another player's and that gun's "apply to others" is off.
local function kindRecolor(kind, startPos)
	local color, default = CW.Settings[KINDS[kind].prefix .. "COLOR"], KIND_DEFAULTS[kind].color
	if typeof(color) ~= "Color3" then return nil end
	if color.R == default.R and color.G == default.G and color.B == default.B then return nil end
	if othersFor(KIND_GUN[kind]) or isLocalPlayerShot(startPos) then return color end
	return nil
end

local function warnTracerFailure(err)
	if CW.State.tracerFailureWarned then return end
	CW.State.tracerFailureWarned = true
	CW.Warn("Custom tracer failed; using the game's tracer instead: " .. tostring(err))
end

-- The wrappers run on the game's own thread, so they must never throw into the game's gun
-- code: a failing custom tracer falls back to the game's own function. The game always calls
-- the three tracer functions with exactly two arguments (start, end).
-- Bullet guns: the firing gun's own tracer when it has one turned on, otherwise the game's tracer.
local function makeTracerWrapper(originalKey)
	return function(startPos, endPos)
		if hasGunTracers() then
			local okStyle, style = pcall(bulletShotStyle, startPos)
			if okStyle and style then
				local okDraw, err = pcall(createEnergyTracer, startPos, endPos, style)
				if okDraw then return end
				warnTracerFailure(err)
			end
		end

		local original = CW[originalKey]
		if original then return original(startPos, endPos) end
	end
end

-- Taser and sniper without their own tracer: the game's tracer, recolored afterwards when the color applies.
local function makeRecolorWrapper(kind)
	local originalKey = KINDS[kind].original
	return function(startPos, endPos)
		local okUse, color = pcall(kindRecolor, kind, startPos)
		local before
		if okUse and color then
			local okSnapshot, snapshot = pcall(snapshotRayParts)
			if okSnapshot then before = snapshot end
		end
		local original = CW[originalKey]
		if original then original(startPos, endPos) end
		if before then
			local ok, err = pcall(recolorNewRayParts, before, color)
			if not ok then warnTracerFailure(err) end
		end
	end
end

-- Taser and sniper: the kind's own tracer when its ENABLED setting is on (and the shot is yours, or
-- that gun's "apply to others" is on); otherwise the recolor behaviour above. Never throws into the game.
local function makeKindWrapper(kind)
	local info = KINDS[kind]
	local fallback = makeRecolorWrapper(kind)
	return function(startPos, endPos)
		if CW.Settings[info.prefix .. "ENABLED"] == true then
			local okOwn, own = pcall(function()
				return othersFor(KIND_GUN[kind]) or isLocalPlayerShot(startPos)
			end)
			if okOwn and own then
				local okDraw, err = pcall(createKindTracer, kind, startPos, endPos)
				if okDraw then return end
				warnTracerFailure(err)
			end
		end
		return fallback(startPos, endPos)
	end
end

-- Installs the wrappers; returns false (so we can retry) if the game module isn't ready yet.
-- The game's own functions are captured once and kept in CW, so installing again on a re-run
-- replaces our wrappers with the new ones instead of stacking them.
local function installTracers()
	if not CW.TracersModule then
		local shared = ReplicatedStorage:FindFirstChild("SharedModules")
		local moduleScript = shared and shared:FindFirstChild("GunTracers")
		if not moduleScript then return false end

		local ok, TracersModule = pcall(require, moduleScript)
		if not ok or type(TracersModule) ~= "table" then return false end

		CW.TracersModule          = TracersModule
		CW._originalCreateBullet  = TracersModule.createBullet
		CW._originalCreateTaser   = TracersModule.createTaser
		CW._originalCreateSniper  = TracersModule.createSniper
	end

	local TracersModule = CW.TracersModule
	if type(CW._originalCreateBullet) == "function" then
		TracersModule.createBullet = makeTracerWrapper("_originalCreateBullet")
	end
	if type(CW._originalCreateTaser) == "function" then
		TracersModule.createTaser = makeKindWrapper("Taser")
	end
	if type(CW._originalCreateSniper) == "function" then
		TracersModule.createSniper = makeKindWrapper("Sniper")
	end

	CW.Log("Tracer override installed.")
	return true
end

-- The module is shared with the game's own scripts, so it exists from the start; the waits only
-- matter if the script runs very early.
task.spawn(function()
	local shared = ReplicatedStorage:WaitForChild("SharedModules", 30)
	if not (shared and shared:WaitForChild("GunTracers", 30)) then
		CW.Warn("GunTracers module not found: custom tracers disabled.")
		return
	end
	if not installTracers() then
		CW.Warn("Could not load the GunTracers module: custom tracers disabled.")
	end
end)
end)


runModule("Hook", function()
-- Hook.lua
local CW = getgenv().__CW_CORE_STATE

local Players           = game:GetService("Players")
local TweenService      = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

-- How it works
--   The __namecall hook runs on the GAME's thread, which lacks the capabilities needed to
--   parent GUI into gethui() ("lacking capability Plugin"). So the hook does nothing but
--   copy the hit parts into a small queue (plain tables only, no Instance method calls).
--   A PreRender connection created from this script's own thread drains the queue and does
--   the real work (hit sound + hitmarker).

local MAX_QUEUE   = 32   -- shots waiting for the next frame (oldest dropped beyond this)
local MAX_BULLETS = 8    -- bullets copied per shot (the shotgun sends 5)
local MAX_AGE     = 1    -- seconds; older queued shots are discarded instead of drawn late

CW.State.shotQueue = CW.State.shotQueue or {}

-- Called from the game's thread: ONLY table work here. No :Method() calls on Instances.
function CW.onShot(bullets)
	if type(bullets) ~= "table" then return end

	local hits, n = {}, 0
	for _, bullet in pairs(bullets) do
		if n >= MAX_BULLETS then break end
		if type(bullet) == "table" then
			local hit = bullet[3]
			if hit ~= nil then
				n = n + 1
				hits[n] = hit
			end
		end
	end
	if n == 0 then return end

	local queue = CW.State.shotQueue
	if #queue >= MAX_QUEUE then table.remove(queue, 1) end
	queue[#queue + 1] = { hits = hits, time = os.clock() }
end

-- Runs on this script's thread (from the PreRender drain): the real shot logic.
function CW.processShot(hits)
	local shotHit = false
	for i = 1, #hits do
		local hit = hits[i]
		if typeof(hit) == "Instance" and hit:IsA("BasePart") and hit.Parent then
			local character = hit:FindFirstAncestorOfClass("Model") -- same lookup the game uses
			local player = character and Players:GetPlayerFromCharacter(character)
			if player and CW.isEnemy(player) then
				shotHit = true
				break
			end
		end
	end
	if not shotHit then return end
	-- The hit sound of the gun in hand (this runs at most a frame after the shot).
	local character = Players.LocalPlayer.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	CW.playHitSound(tool and tool.Name)
	if not CW.HMTemplate or not CW.IAPortable then return end

	-- Read the real mouse position now; mouseX/Y only update on MouseMovement.
	local loc = UserInputService:GetMouseLocation()
	CW.State.mouseX, CW.State.mouseY = loc.X, loc.Y

	local Clone = CW.HMTemplate:Clone()
	Clone.Size              = UDim2.new(0, CW.Settings.HITMARKER_SIZE, 0, CW.Settings.HITMARKER_SIZE)
	Clone.Position          = UDim2.fromOffset(CW.State.mouseX, CW.State.mouseY)
	Clone.Rotation          = CW.Settings.HITMARKER_RANDOM_ROTATION and math.random(0,90) or 0
	Clone.ImageTransparency = 0
	Clone.Parent            = CW.IAPortable

	if CW.Settings.HITMARKER_FOLLOW_MOUSE then
		CW.ActiveFollowClones[Clone] = true
	end

	local function finishClone()
		CW.ActiveFollowClones[Clone] = nil
		if Clone.Parent then Clone:Destroy() end
	end

	task.delay(CW.Settings.HITMARKER_VISIBLE_DURATION, function()
		if not Clone.Parent then return end

		if CW.Settings.HITMARKER_FADEOUT then
			local baseSize = Clone.Size
			local growSize = UDim2.new(
				0, baseSize.X.Offset * 1.35,
				0, baseSize.Y.Offset * 1.35
			)

			local ok = pcall(function()
				local tween = TweenService:Create(
					Clone,
					TweenInfo.new(
						CW.Settings.HITMARKER_FADEOUT_DURATION,
						Enum.EasingStyle.Quad,
						Enum.EasingDirection.Out
					),
					{ ImageTransparency = 1, Size = growSize }
				)
				tween.Completed:Connect(finishClone)
				tween:Play()
			end)
			if not ok then finishClone() end
		else
			finishClone()
		end
	end)
end

local function traceHandler(err)
	return debug.traceback(tostring(err), 2)
end

-- Empties the queue. Errors are caught per shot and printed with a traceback (first 5 only,
-- so a persistent failure cannot flood the console).
function CW.drainShots()
	local queue = CW.State.shotQueue
	if not queue or #queue == 0 then return end
	CW.State.shotQueue = {}

	local now = os.clock()
	for i = 1, #queue do
		local entry = queue[i]
		if now - entry.time <= MAX_AGE then
			local ok, err = xpcall(CW.processShot, traceHandler, entry.hits)
			if not ok then
				CW.State.shotErrors = (CW.State.shotErrors or 0) + 1
				if CW.State.shotErrors <= 5 then
					CW.Warn("Shot handler error: " .. tostring(err))
				end
			end
		end
	end
end

CW.track("shotDrain", RunService.PreRender:Connect(function()
	local drain = CW.drainShots
	if drain then drain() end
end))

-- The hook only forwards the call: it copies the hit parts into the queue and returns the
-- game's own result untouched, so it can never break or delay the game's FireServer.
local function installShootHook(shootEvent)
	if CW.State.shootHooked then return end
	CW.ShootEvent = shootEvent

	local isExecutorCall = type(checkcaller) == "function" and checkcaller or function() return false end
	local wrap = X.newcclosure or function(fn) return fn end

	local OldNameCall
	-- (__namecall runs for every method call in the game: the cheap check first)
	OldNameCall = X.hookmetamethod(shootEvent, "__namecall", wrap(function(self, ...)
		if self == CW.ShootEvent and getnamecallmethod() == "FireServer" and not isExecutorCall() then
			local enqueue = CW.onShot
			if enqueue then pcall(enqueue, (...)) end
		end
		return OldNameCall(self, ...)
	end))

	CW.State.shootHooked = true
	CW.Log("ShootEvent hook installed")
end

if not CW.Caps.hook then
	if not CW.State.hookCapabilityWarned then
		CW.State.hookCapabilityWarned = true
		CW.Warn("hookmetamethod/getnamecallmethod unavailable; hitmarker and hit sound detection is disabled")
	end
else
	-- GunRemotes.ShootEvent exists from the start of the game; the waits only matter if the
	-- script runs very early.
	task.spawn(function()
		local remotes = ReplicatedStorage:WaitForChild("GunRemotes", 30)
		local shootEvent = remotes and remotes:WaitForChild("ShootEvent", 30)
		if not shootEvent then
			CW.Warn("GunRemotes.ShootEvent not found; hitmarker detection unavailable")
			return
		end
		local ok, err = pcall(installShootHook, shootEvent)
		if not ok then CW.Warn("Could not install the ShootEvent hook: " .. tostring(err)) end
	end)
end
end)


runModule("Cleanup", function()
-- Cleanup.lua
local CW = getgenv().__CW_CORE_STATE

local UserInputService = game:GetService("UserInputService")

local LocalPlayer = CW.LocalPlayer

-- Runs when the player leaves the game. It is looked up through CW when it fires, so a
-- re-run's version is the one that runs.
function CW.cleanup()
	pcall(function() UserInputService.MouseIconEnabled=true end)
	pcall(function() UserInputService.MouseIcon="" end)
	pcall(function() CW.IAPortable:Destroy() end)
	pcall(function() if CW.UIWindow then CW.UIWindow:Destroy() end end)
	pcall(function() if CW.State.stopSprintToggle then CW.State.stopSprintToggle() end end)
	for _, key in ipairs({
		"enforcerConn", "enableConn", "sprintCharacterConn", "sprintStepConn", "chatToggleConn",
	}) do
		pcall(function()
			local connection = CW.State[key]
			if connection then connection:Disconnect() end
		end)
	end
	pcall(function() CW.Settings.AUTO_RELOAD_ENABLED = false end)
	pcall(function() if CW.State.stopWeaponShootSoundOverrides then CW.State.stopWeaponShootSoundOverrides() end end)
	pcall(function() if CW.State.destroyHitSoundPool then CW.State.destroyHitSoundPool() end end)
	pcall(function()
		local contextActions = game:GetService("ContextActionService")
		contextActions:UnbindAction("CycleWareSprintToggle")
		contextActions:UnbindAction("CycleWareProtectSprint")
	end)
	pcall(CW.untrackAll)
	CW.ActiveFollowClones = {}
end

CW.track("cleanup", LocalPlayer.AncestryChanged:Connect(function()
	if LocalPlayer:IsDescendantOf(game) then return end
	local cleanup = CW.cleanup
	if cleanup then pcall(cleanup) end
end))
end)


runModule("AntiAFK", function()
-- AntiAFK.lua
-- Roblox disconnects a player after 20 minutes without input. Player.Idled fires once the player has been idle
-- for 2 minutes; each time it does, a virtual right click (VirtualUser) counts as input and the 20 minutes start
-- over. Where the executor can't drive VirtualUser, a key no one uses (F15) is pressed through
-- VirtualInputManager instead. Prison Life has no idle handling of its own (no script of the game uses Idled).
local CW = getgenv().__CW_CORE_STATE

local LocalPlayer = CW.LocalPlayer
local SPARE_KEY = Enum.KeyCode.F15

local warned = false
local function nudge()
	local clicked = pcall(function()
		local virtualUser = game:GetService("VirtualUser")
		virtualUser:CaptureController()
		virtualUser:ClickButton2(Vector2.zero)
	end)
	if clicked then return end
	local pressed = pcall(function()
		local virtualInput = game:GetService("VirtualInputManager")
		virtualInput:SendKeyEvent(true, SPARE_KEY, false, game)
		task.wait(0.05)
		virtualInput:SendKeyEvent(false, SPARE_KEY, false, game)
	end)
	if not pressed and not warned then
		warned = true
		CW.Warn("Anti-AFK can't simulate input on this executor (VirtualUser and VirtualInputManager are blocked)")
	end
end

-- Registered with CW.track: a re-run replaces it, and leaving the game takes it away (CW.cleanup).
function CW.setAntiAFK(enabled)
	CW.Settings.ANTI_AFK_ENABLED = enabled == true
	if CW.Settings.ANTI_AFK_ENABLED then
		CW.track("antiAfk", LocalPlayer.Idled:Connect(function()
			if CW.Settings.ANTI_AFK_ENABLED then nudge() end
		end))
	else
		CW.untrack("antiAfk")
	end
end
CW.setAntiAFK(CW.Settings.ANTI_AFK_ENABLED)
end)


runModule("Sync", function()
-- Sync.lua
-- Runs independently of the UI: official assets are downloaded even if the UI fails to load,
-- and everything that consumes assets is reloaded as soon as the download finishes.
local CW = getgenv().__CW_CORE_STATE

-- Reloads what uses the library: the files in use (and their settings), then the hitmarker, the textures, the
-- hit sound and the cursor. onlyIfMoved: only when one of the three files in use changed. Returns whether one did.
function CW.reloadCoreAssets(onlyIfMoved)
	local cursor = CW.Library.selectedPath("Cursors")
	local hitmarker = CW.Library.selectedPath("Hitmarkers")
	local sound = CW.Library.selectedPath("HitSounds")
	local moved = cursor ~= CW.Paths.CURSOR_FILE or hitmarker ~= CW.Paths.HITMARKER_FILE or sound ~= CW.Paths.SOUND_FILE
	if onlyIfMoved and not moved then return false end
	CW.Paths.CURSOR_FILE, CW.Paths.HITMARKER_FILE, CW.Paths.SOUND_FILE = cursor, hitmarker, sound
	-- The sync (or an edited custom ID) can change which asset is in use: its own settings come with it.
	for category, path in pairs({ Cursors = CW.Paths.CURSOR_FILE, Hitmarkers = CW.Paths.HITMARKER_FILE, HitSounds = CW.Paths.SOUND_FILE }) do
		local relative = CW.Library.relative(path)
		if relative ~= CW.Profiles.current[category] then CW.Profiles.use(category, relative) end
	end

	-- The cursor goes last: generating it yields for a while (PNG codec), and it must not
	-- delay the textures and the hit sound.
	local reloaders = {
		{ "hitmarker", CW.reloadHitmarkerAsset },
		{ "textures", CW.reloadTextures },
		{ "sound", CW.reloadSoundAsset },
		{ "cursor", CW.reloadCursor },
	}
	for _, entry in ipairs(reloaders) do
		if type(entry[2]) == "function" then
			local ok, err = pcall(entry[2])
			if not ok then
				CW.Warn("Failed to reload " .. entry[1] .. ": " .. tostring(err))
			end
		end
	end
	return moved
end

CW.State.syncFinished = false
CW.State.syncChanged = nil
CW.State.syncCallbacks = {}

task.spawn(function()
	-- After the UI download (UI_CACHED_WAIT s at most): on an executor that runs one request at a time, the asset
	-- files would otherwise hold the interface back.
	local waitStart = os.clock()
	while not uiFetch.done and os.clock() - waitStart < UI_CACHED_WAIT do task.wait() end
	if not isCurrentRun() then return end
	local ok, result, changed = pcall(CW.Library.sync)
	if not ok then
		CW.Warn("Asset sync failed: " .. tostring(result))
	elseif not result then
		CW.Warn("Asset sync incomplete; continuing with available local files")
	end
	if not isCurrentRun() then return end

	-- Finished first: a chosen hitmarker or hit sound still missing now is gone, not downloading (selectedPath).
	CW.State.syncFinished = true
	local filesChanged = ok and changed == true
	local reloadOK, moved = pcall(CW.reloadCoreAssets, not filesChanged)
	if not reloadOK then
		CW.Warn("Core asset reload failed: " .. tostring(moved))
		moved = true
	end
	CW.State.syncChanged = filesChanged or moved == true
	local callbacks = CW.State.syncCallbacks
	CW.State.syncCallbacks = {}
	for _, callback in ipairs(callbacks) do
		pcall(callback, CW.State.syncChanged)
	end
end)
end)

-- The interface: the UI library (uiFetch), the window and every tab. The window goes in `interface`; without
-- one, the Finish step shows `interface.failure` on the loading screen. whenOpen: work that waits for the window
-- to be shown (each runs on a clean thread). showProblems: set once the window is open; it lists in the window
-- what failed, also what fails later (a gun page built after the start).
local interface = { window = nil, failure = nil, whenOpen = {}, showProblems = nil }
runModule("Interface", function()
-- UI.lua
local CW = getgenv().__CW_CORE_STATE
assert(CW, "CycleWare must be loaded before UI.lua")

for key, value in pairs(CW._SavedSettings or {}) do
	if key ~= "ASSET_SELECTIONS" and key ~= "SOUND_ID" and key ~= "AUTO_RELOAD_LABEL_PATH" then
		local current = CW.Settings[key]
		if current == nil or type(current) == type(value) then
			CW.Settings[key] = value
		end
	end
end

-- Switches that were one for every gun are one per gun now (map gun -> true). An old switch that was on turns on
-- every gun's own, once: the old one is dropped, so it is not saved again. Before the first save, an old key in
-- CW_CONFIG counts the same way.
local switchesMigrated = false
for _, keys in ipairs({
	{ "WEAPON_SOUND_OVERRIDE_ENABLED", "WEAPON_SHOOT_SOUND_ENABLED_GUNS" },
	{ "WEAPON_SOUND_OVERRIDE_APPLY_TO_OTHERS", "WEAPON_SHOOT_SOUND_OTHERS_GUNS" },
	{ "WEAPON_RELOAD_SOUND_OVERRIDE_ENABLED", "WEAPON_RELOAD_SOUND_ENABLED_GUNS" },
	{ "WEAPON_RELOAD_SOUND_OVERRIDE_APPLY_TO_OTHERS", "WEAPON_RELOAD_SOUND_OTHERS_GUNS" },
	{ "TRACER_APPLY_TO_OTHERS", "TRACER_GUN_OTHERS", "applyToOthers" },
}) do
	local oldKey, newKey, legacyKey = keys[1], keys[2], keys[3]
	local old
	if CW._SavedSettings then
		old = CW._SavedSettings[oldKey]
		if old ~= nil then switchesMigrated = true end
	else
		old = _cfg[oldKey]
		if old == nil and legacyKey then old = _cfg[legacyKey] end
	end
	if type(CW.Settings[newKey]) ~= "table" then CW.Settings[newKey] = {} end
	if old == true and next(CW.Settings[newKey]) == nil then
		for _, gun in ipairs(CW.SoundWeaponList or {}) do CW.Settings[newKey][gun] = true end
	end
	CW.Settings[oldKey] = nil
end

local HttpService = game:GetService("HttpService")

-- Runs one UI section in isolation so a failure in one tab doesn't take the others down. A section whose thread
-- lost its permissions runs on a new clean thread (runClean). A failure is listed by the window (Finish step).
local function guarded(name, fn)
	local ok, err = runClean("the " .. name .. " section", fn)
	if not ok then
		startupProblems[name] = tostring(err)
		CW.Warn("UI section '" .. name .. "' failed: " .. tostring(err))
		if interface.showProblems then pcall(interface.showProblems) end
	end
	return ok
end

-- Autosave (debounced): every control callback schedules a save 1 s after the last change. Assigned with the
-- settings file functions below, before any tab, so saving works even if a tab fails to build.
local scheduleSave = function() end

--// Settings file
-- Strings, numbers, booleans and tables of them (nested: ASSET_PROFILES is category -> asset -> setting).
local function serializableValue(value, depth)
	local valueType = type(value)
	if valueType == "string" or valueType == "number" or valueType == "boolean" then
		return value
	end
	if valueType ~= "table" or (depth or 0) > 4 then return nil end

	local result = {}
	for key, entry in pairs(value) do
		local keyType = type(key)
		if keyType == "string" or keyType == "number" then
			local serialized = serializableValue(entry, (depth or 0) + 1)
			if serialized ~= nil and not (type(serialized) == "table" and next(serialized) == nil) then
				result[key] = serialized
			end
		end
	end
	return result
end

-- A setting is saved only when the player changed it: its value differs from the default.
-- Switching a setting back to its default removes it from the file.
local function isDefaultValue(key, value)
	if type(value) == "table" then return next(value) == nil end
	local default = CW.Defaults[key]
	if default == nil and type(value) == "boolean" then default = false end
	if type(value) == "number" and type(default) == "number" then return math.abs(value - default) < 1e-6 end
	return value == default
end

-- The settings file's contents: the settings that differ from the defaults, and the asset choices.
local function encodeSettings()
	local savedSettings = {}
	for key, value in pairs(CW.Settings) do
		if key ~= "ASSET_SELECTIONS" and key ~= "SOUND_ID" and key ~= "AUTO_RELOAD_LABEL_PATH"
			and not CW.Profiles.isKey[key] then
			local serialized = serializableValue(value)
			if serialized ~= nil and not isDefaultValue(key, serialized) then
				savedSettings[key] = serialized
			end
		end
	end

	-- Tracer colors are Color3 (not serialisable): store them as hex, only when different from the default.
	local function saveColor(settingKey, hexKey)
		local color, default = CW.Settings[settingKey], CW.Defaults[settingKey]
		if typeof(color) == "Color3" and (typeof(default) ~= "Color3" or color:ToHex() ~= default:ToHex()) then
			savedSettings[hexKey] = color:ToHex()
		end
	end
	saveColor("TRACER_SNIPER_COLOR", "TRACER_SNIPER_COLOR_HEX")
	saveColor("TRACER_TASER_COLOR", "TRACER_TASER_COLOR_HEX")

	local out = {
		schemaVersion = 3,
		Settings = savedSettings,
		AssetSelections = CW.Settings.ASSET_SELECTIONS,
	}

	local ok, encoded = pcall(HttpService.JSONEncode, HttpService, out)
	if not ok then
		CW.Warn("Failed to encode settings")
		return nil
	end
	return encoded
end

-- After a settings slot is loaded into the settings file, this run must not write over it (savesStopped).
local savesStopped = false
local function saveSettings()
	if savesStopped then return end
	local encoded = encodeSettings()
	if not encoded then return end
	local saved, err = pcall(writefile, CW.Paths.SETTINGS_FILE, encoded)
	if not saved then CW.Warn("Could not save settings: " .. tostring(err)) end
end

-- Debounced autosave (scheduleSave, declared above).
local saveThread
scheduleSave = function()
	if saveThread then task.cancel(saveThread) end
	saveThread = task.delay(1, function()
		saveThread = nil
		saveSettings()
	end)
end
local function stopSaving()
	savesStopped = true
	if saveThread then task.cancel(saveThread) end
	saveThread = nil
end

--// The UI library (downloaded since the start: uiFetch)
loadingScreen.step("Downloading the interface", 0.4)
local uiSource, uiOrigin
do
	local cached
	local okCache, cachedText = pcall(readfile, CW.Paths.UI_CACHE_FILE)
	if okCache and isUISource(cachedText) then cached = cachedText end
	local limit = cached and UI_CACHED_WAIT or UI_DOWNLOAD_WAIT
	local waitStart = os.clock()
	while not uiFetch.done and os.clock() - waitStart < limit do task.wait() end
	if uiFetch.source then
		uiSource, uiOrigin = uiFetch.source, uiFetch.fromFile and ("the local file " .. uiFetch.fromFile) or "GitHub"
	elseif cached then
		uiSource, uiOrigin = cached, "the last saved copy"
		CW.Warn("The UI download " .. (uiFetch.done and ("failed (" .. tostring(uiFetch.error) .. ")") or "is slow")
			.. "; using the last saved copy")
	end
end
if not isCurrentRun() then return end
if not uiSource then
	interface.failure = "The interface could not be downloaded. Your saved settings are still on."
	error("Could not download CWUI.lua: " .. tostring(uiFetch.error or ("no answer in " .. UI_DOWNLOAD_WAIT .. " s")), 0)
end
CW.Log("UI library from " .. uiOrigin)

if not X.loadstring then
	interface.failure = "This executor can't run the interface (it has no loadstring)."
	error("loadstring is unavailable", 0)
end
local compiled, loadUI, compileError = pcall(X.loadstring, uiSource)
if not compiled or type(loadUI) ~= "function" then
	interface.failure = "The interface file is damaged. Run CycleWare again."
	error("Could not compile CWUI.lua: " .. tostring(compileError or loadUI), 0)
end
-- CWUI gets this file's executor functions, so its own calls also run on threads of their own.
local loadedUI, CWUI = pcall(loadUI, {
	gethui = X.gethui, cloneref = X.cloneref, setclipboard = X.setclipboard, protectGui = X.protectGui,
	getcustomasset = CAPS.customAsset and getcustomasset or nil,
	isfile = CAPS.files and isfile or nil, isfolder = CAPS.files and isfolder or nil,
	listfiles = CAPS.files and listfiles or nil,
})
if not loadedUI or type(CWUI) ~= "table" or type(CWUI.CreateWindow) ~= "function" then
	interface.failure = "The interface could not be built. Run CycleWare again."
	error("Invalid CWUI library: " .. tostring(CWUI), 0)
end

if CW.UIWindow and type(CW.UIWindow.Destroy) == "function" then
	pcall(function() CW.UIWindow:Destroy() end)
end
-- Ícones opcionais (caminho no workspace ou ID do Roblox). Exemplo, antes de executar o script:
--   getgenv().CW_CONFIG = { UI_ICONS = { Logo = "CW/logo.png", Discord = 456, Info = 789, Settings = 123,
--                                         Cursors = 111, Guns = 222, Utilities = 444 },
--                           DISCORD_URL = "https://discord.gg/xxxx" }
-- (Settings vale para o botão do rodapé e para a aba Settings; as outras abas usam o próprio nome.
--  Effects e Visuals, os nomes antigos, ainda valem para as abas Cursors e Guns.)
local uiIcons = type(_cfg.UI_ICONS) == "table" and _cfg.UI_ICONS or {}

-- The saved look (CW.Settings.UI_THEME) as CWUI.SetTheme arguments: hex strings become colors.
-- Applied before the window is built, so it opens with the player's colors already.
local THEME_COLOR_KEYS = { "Accent", "Selector", "Text", "Background", "Sidebar", "Panel" }
local function savedThemeChanges()
	local look, changes = CW.Settings.UI_THEME, {}
	for _, key in ipairs(THEME_COLOR_KEYS) do
		local ok, color = pcall(Color3.fromHex, type(look[key]) == "string" and look[key] or "")
		if ok and typeof(color) == "Color3" then changes[key] = color end
	end
	for _, key in ipairs({ "BackgroundTransparency", "PanelTransparency", "SelectorTransparency" }) do
		changes[key] = tonumber(look[key])
	end
	if type(look.Corners) == "boolean" then changes.Corners = look.Corners end
	return changes
end
local canTheme = type(CWUI.SetTheme) == "function"
if canTheme then CWUI.SetTheme(savedThemeChanges()) end

loadingScreen.step("Building the interface", 0.7)
local syncDoneBeforeUI = CW.State.syncFinished == true -- the lists made below are already the synced ones
local created, Window = pcall(CWUI.CreateWindow, CWUI, {
	Title = "CW",
	ToggleKey = false,
	Logo = uiIcons.Logo,
	Icons = { Settings = uiIcons.Settings, Discord = uiIcons.Discord, Info = uiIcons.Info },
	Discord = type(_cfg.DISCORD_URL) == "string" and _cfg.DISCORD_URL or nil,
	SettingsButton = true,
})
if not created or type(Window) ~= "table" then
	interface.failure = "The interface could not be built. Run CycleWare again."
	error("CreateWindow failed: " .. tostring(Window), 0)
end
CW.UIWindow = Window
interface.window = Window
if Window.SetVisible then Window:SetVisible(false) end -- shown as the loading screen goes
-- RightShift opens and closes the window only once the loading screen is gone (Ready, set at the end of this file):
-- before that the UI is still being built, and opening it would show it half made over the loading screen.
Window.Ready = false
function Window:ToggleVisibility()
	if self.Ready then self:Toggle() end
end

-- Background layers and parallax. The single background image of the previous version becomes layer 1.
local canLayers = type(Window.SetBackgroundLayers) == "function"
local PARALLAX_DEFAULT = 0.03
local backgroundLayers = {}

-- Saved layers keep the fill as hex; CWUI wants a Color3.
local function windowLayers(list)
	local out = {}
	for i, layer in ipairs(list) do
		local copy = table.clone(layer)
		local ok, color = pcall(Color3.fromHex, type(layer.Fill) == "string" and layer.Fill or "")
		copy.Fill = ok and color or nil
		out[i] = copy
	end
	return out
end

if canLayers then
	local look = CW.Settings.UI_THEME
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, CW.Settings.UI_LAYERS)
	if ok and type(decoded) == "table" then backgroundLayers = decoded end
	if #backgroundLayers == 0 and type(look.Image) == "string" then
		backgroundLayers[1] = {
			Image = look.Image, X = 0, Y = 0, W = 1, H = 1, Depth = 5, Transparency = tonumber(look.ImageTransparency) or 0.5,
		}
		look.Image, look.ImageTransparency = nil, nil
		CW.Settings.UI_LAYERS = HttpService:JSONEncode(backgroundLayers)
	end
	Window:SetParallax(look.Parallax == true, tonumber(look.ParallaxStrength) or PARALLAX_DEFAULT, look.ParallaxHoverOnly == true)
	Window:SetBackgroundLayers(windowLayers(backgroundLayers))
end

local function mapControlOptions(options)
	options = options or {}
	return {
		Name = options.Title or options.Name,
		Default = options.Default,
		Min = options.Min,
		Max = options.Max,
		Increment = options.Increment or (options.Decimal and 10 ^ -options.Decimal),
		Suffix = options.Suffix,
		Placeholder = options.Placeholder,
		Options = options.Options,
		MaxHeight = options.MaxHeight,
		Callback = options.Callback,
	}
end

local function withSave(callback)
	return function(...)
		if callback then callback(...) end
		scheduleSave()
	end
end

local function wrapSection(section)
	local adapter = { Instance = section.Instance } -- CWUI 3+: hide or show the whole section
	function adapter:Toggle(control)
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddToggle(o)
	end
	function adapter:Slider(control)
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddSlider(o)
	end
	function adapter:Dropdown(control)
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddDropdown(o)
	end
	-- Color picker (CWUI 2.2+). Returns nil when the loaded CWUI has no picker, so the caller can
	-- fall back to something else (an old copy of CWUI.lua may still be cached on disk).
	function adapter:Colorpicker(control)
		if type(section.AddColorpicker) ~= "function" then return nil end
		local o = mapControlOptions(control)
		o.Callback = withSave(o.Callback)
		return section:AddColorpicker(o)
	end
	function adapter:Gallery(control)
		local o = {}
		for key, value in pairs(control) do o[key] = value end
		o.Callback = withSave(control.Callback)
		return section:AddGallery(o)
	end
	function adapter:Button(control) return section:AddButton(mapControlOptions(control)) end
	-- Text input; its value is not part of the saved settings (no autosave).
	function adapter:Textbox(control)
		if type(section.AddTextbox) ~= "function" then return nil end
		return section:AddTextbox(mapControlOptions(control))
	end
	-- Slot board (CWUI 2.3+); nil when the loaded CWUI has no AddSlotBoard.
	function adapter:SlotBoard(control)
		if type(section.AddSlotBoard) ~= "function" then return nil end
		local o = {}
		for key, value in pairs(control) do o[key] = value end
		o.Callback = withSave(control.Callback)
		return section:AddSlotBoard(o)
	end
	-- Text boxes side by side with buttons (CWUI 2.3+); nil when the loaded CWUI has no AddInputRow.
	function adapter:InputRow(control)
		if type(section.AddInputRow) ~= "function" then return nil end
		return section:AddInputRow(control)
	end
	-- Visual editor of the background layers (CWUI 3+); nil when the loaded CWUI has no AddLayerCanvas.
	function adapter:LayerCanvas(control)
		if type(section.AddLayerCanvas) ~= "function" then return nil end
		return section:AddLayerCanvas(control)
	end
	function adapter:AddLabel(text) return section:AddLabel(text) end
	-- A fixed inset panel inside the section that keeps one thing's controls together (CWUI 3.1+); on an older
	-- CWUI the controls just go into the section.
	function adapter:Group(caption)
		if type(section.AddGroup) ~= "function" then return adapter end
		local group = section:AddGroup({ Name = caption })
		local wrapped = wrapSection(group)
		function wrapped:SetCaption(text) group:SetName(text) end
		return wrapped
	end
	function adapter:AddSubSection(name, open)
		-- Subsections are collapsed unless the caller explicitly asks for them open.
		return wrapSection(section:AddSubSection({ Name = name, Open = open == true }))
	end
	return adapter
end

local function createCompatTab(options)
	options = options or {}
	local tabName = options.Title or options.Name or "Settings"
	local tab = Window:AddTab({ Name = tabName, Icon = options.Icon or uiIcons[tabName], Footer = options.Footer })
	-- CWUI 3+: the tab takes the controls itself, so it does not open on one closed section named like the tab.
	if type(tab.AddToggle) == "function" then return wrapSection(tab) end
	return wrapSection(tab:AddSection({ Name = tabName, Open = false }))
end

Window.Tab = function(_, options) return createCompatTab(options) end

-- Gallery items come from CW.Library.items (library files, then custom IDs) so paths are
-- normalised the same way everywhere. A custom ID's Path is its rbxassetid, which CWUI shows as is.
local function galleryItems(category, weapon)
	local items = {}
	for _, item in ipairs(CW.Library.items(category, weapon)) do
		table.insert(items, { Name = item.Name, Image = item.Path })
	end
	return items
end

local HitmarkerGallery, CursorGallery
local hitSoundDrawers = {} -- { gun, entries, dropdown, volume } per gun
local textureGalleries = {}
local meshControls = {} -- one refresh function per gun page (its Mesh list and Adjust Mesh)
local refreshGunPreview -- (gun or nil, keepCamera): the Guns tab redraws the preview of the gun shown
local refreshUIFromLibrary -- defined after the tabs; the custom ID controls call it

-- Label of a custom ID in the sound dropdowns: just the name the player gave it (or its ID when it was
-- added without a name). Names are unique within a list; the ID is only added when the name would collide
-- with a label already in that dropdown.
local function customIdLabel(item, taken)
	local label = item.Name
	if (taken and taken[label]) or label == "Default" or label == "None" then
		label = label .. " (" .. item.CustomId .. ")"
	end
	return label
end

------------------------------------------------------------------------------
-- Hit sound catalog / weapon sound override logic (no UI here)
------------------------------------------------------------------------------
-- One gun's hit sound list: the files of the HitSounds folder, then that gun's custom IDs.
-- Returns the labels and the entries { label, relative } to translate between them.
local function hitSoundCatalog(gun)
	local options, entries, taken = {}, {}, {}
	for _, item in ipairs(CW.Library.items("HitSounds", gun)) do
		local label = item.CustomId and customIdLabel(item, taken) or item.Relative:gsub("^HitSounds/", "")
		taken[label] = true
		table.insert(options, label)
		table.insert(entries, { label = label, relative = item.Relative })
	end
	return options, entries
end

local function hitSoundLabel(entries, relative)
	for _, entry in ipairs(entries) do
		if entry.relative == relative then return entry.label end
	end
	return nil
end

local function hitSoundRelative(entries, label)
	for _, entry in ipairs(entries) do
		if entry.label == label then return entry.relative end
	end
	return nil
end

------------------------------------------------------------------------------
-- Weapon sound changers: one factory, one instance per action (shoot, reload).
--
-- How the game plays a gun sound: the Handle of the Tool holds one Sound per action (named
-- ShootSound, ReloadSound). Every time the action happens the game CLONES that Sound into the
-- same Handle, plays the clone and removes it a few seconds later; for other players the server
-- sends the Sound instance and their client clones and plays it the same way. So replacing the
-- SoundId of the original replaces it for every clone made afterwards, mine and the others'.
-- The weapon is the Tool the Sound lives in: Sound.Parent = Handle, Handle.Parent = Tool, and the
-- Tool's name is the weapon's name.
------------------------------------------------------------------------------
local WEAPON_SOUND_DEFAULT = "Default"

-- A previous run (even of an older version) keeps watching until it is told to stop.
if CW.State.stopWeaponShootSoundOverrides then
	pcall(CW.State.stopWeaponShootSoundOverrides)
end

local function disconnectList(connections)
	for _, connection in ipairs(connections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(connections)
end

local function findSoundTool(sound)
	local ancestor = sound.Parent
	while ancestor do
		if ancestor:IsA("Tool") then return ancestor end
		ancestor = ancestor.Parent
	end
	return nil
end

-- Guns that have sounds to replace (set up by the Texture module; includes the Taser).
local function soundWeaponNames()
	return CW.SoundWeaponList or CW.WeaponList or {}
end

-- spec = {
--   Category    = "WeaponSounds" | "ReloadSounds"   library folder: <Category>/<Weapon>/<file>
--   SoundName   = "ShootSound" | "ReloadSound"      the Sound instance the game plays
--   OverridesKey, VolumeKey                         saved settings (names unchanged for the shoot sounds);
--                                                   VolumeKey holds { ["<gun>|<sound>"] = volume multiplier }
--   EnabledKey, OthersKey                           saved per gun, { [gun] = true }: the gun's sound applies at all,
--                                                   and also to other players' shots with that gun (locally)
--   ConfigKey                                       optional CW_CONFIG table: { ["AK-47"] = "WeaponSounds/AK-47/x.mp3" }
--   BaseVolume(originalId, player)                  optional: volume the game itself plays this sound at
-- }
local function createSoundChanger(spec)
	local settings = CW.Settings
	local configured = settings[spec.OverridesKey] or _cfg[spec.ConfigKey]
	settings[spec.OverridesKey] = type(configured) == "table" and configured or {}
	-- Off by default: nothing changes in the game until the player turns a gun on.
	for _, key in ipairs({ spec.EnabledKey, spec.OthersKey }) do
		if type(settings[key]) ~= "table" then settings[key] = {} end
	end
	local function enabledFor(weapon) return settings[spec.EnabledKey][weapon] == true end
	local function othersFor(weapon) return settings[spec.OthersKey][weapon] == true end
	-- Volume multiplier per gun AND per sound, relative to the game's own volume (1 = untouched): each sound a
	-- gun can use keeps its own volume, so switching the sound brings back the volume it had. Stored as
	-- { ["AK-47|Default"] = 0.5, ["AK-47|WeaponSounds/AK-47/x.mp3"] = 1.2 }, only when different from 1.
	-- Older saves kept one volume per gun ({ ["AK-47"] = 0.5 }) or one for every gun (a number): that value
	-- becomes the volume of the sound each gun uses now.
	local function volumeKey(weapon, relative)
		return weapon .. "|" .. (relative or WEAPON_SOUND_DEFAULT)
	end
	local volumes = {}
	local migratedVolume = false
	do
		local saved = settings[spec.VolumeKey]
		local choices = settings[spec.OverridesKey]
		local function keep(key, value)
			local number = tonumber(value)
			if number and math.abs(math.clamp(number, 0, 2) - 1) > 1e-6 then volumes[key] = math.clamp(number, 0, 2) end
		end
		if type(saved) == "number" then
			for _, weapon in ipairs(soundWeaponNames()) do keep(volumeKey(weapon, choices[weapon]), saved) end
			migratedVolume = true
		elseif type(saved) == "table" then
			for key, value in pairs(saved) do
				if type(key) == "string" then
					if key:find("|", 1, true) then
						keep(key, value)
					else
						keep(volumeKey(key, choices[key]), value)
						migratedVolume = true
					end
				end
			end
		end
		settings[spec.VolumeKey] = volumes
	end

	local overrides = settings[spec.OverridesKey]
	local changer = { spec = spec, overrides = overrides, volumes = volumes, catalog = {}, dropdowns = {}, migrated = migratedVolume }
	local active = setmetatable({}, { __mode = "k" })     -- Sound -> data about what was changed
	local watched = setmetatable({}, { __mode = "k" })    -- container -> { player, connections }
	local playerConnections, globalConnections = {}, {}
	local refreshScheduled, generation = false, 0
	local assetIds = {} -- relative path -> getcustomasset id; rebuilt with every refresh

	--// library catalog ---------------------------------------------------------------
	-- "<Category>/<weapon>/rest" -> "rest" (nil when the path is not inside that weapon's folder).
	local function tailOf(weapon, relative)
		if type(weapon) ~= "string" or type(relative) ~= "string" then return nil end
		if relative:find("..", 1, true) or relative:find("\\", 1, true) then return nil end
		local prefix = spec.Category .. "/" .. weapon .. "/"
		if relative:sub(1, #prefix) ~= prefix or #relative == #prefix then return nil end
		return relative:sub(#prefix + 1)
	end

	-- A custom ID choice ("id:<number>"): valid for every weapon.
	local function isCustomId(relative)
		return type(relative) == "string" and relative:match("^id:%d+$") ~= nil
	end

	function changer.refreshCatalog()
		table.clear(changer.catalog)
		for _, weapon in ipairs(soundWeaponNames()) do
			local entry = { options = { WEAPON_SOUND_DEFAULT }, byLabel = {}, available = {} }
			for _, item in ipairs(CW.Library.items(spec.Category, weapon)) do
				local tail = tailOf(weapon, item.Relative)
				if item.CustomId then
					local label = customIdLabel(item, entry.byLabel)
					entry.byLabel[label] = item.Relative
					entry.available[item.Relative] = true
					table.insert(entry.options, label)
				elseif tail then
					local label = tail:gsub("^_Official/", "")
					if entry.byLabel[label] then label = tail end -- a user file with the same name as an official one
					entry.byLabel[label] = item.Relative
					entry.available[item.Relative] = true
					table.insert(entry.options, label)
				end
			end
			changer.catalog[weapon] = entry
		end
	end

	-- Text shown in a weapon's dropdown for a saved override (also when the file is not on disk yet).
	function changer.label(weapon, relative)
		local tail = tailOf(weapon, relative)
		if isCustomId(relative) then
			local entry = changer.catalog[weapon]
			for label, savedRelative in pairs(entry and entry.byLabel or {}) do
				if savedRelative == relative then return label end
			end
			return "[ID] " .. relative:sub(4)
		end
		if not tail then return WEAPON_SOUND_DEFAULT end
		local entry = changer.catalog[weapon]
		if entry then
			for label, savedRelative in pairs(entry.byLabel) do
				if savedRelative == relative then return label end
			end
		end
		return (tail:gsub("^_Official/", ""))
	end

	-- A saved selection that does not point inside its own weapon's folder (the shoot sounds used
	-- to share the HitSounds library) is dropped once, with a warning.
	do
		local dropped = {}
		for weapon, path in pairs(overrides) do
			if type(path) ~= "string" or not (tailOf(weapon, path) or isCustomId(path)) then
				overrides[weapon] = nil
				if type(path) == "string" then table.insert(dropped, tostring(weapon)) end
			end
		end
		if #dropped > 0 then
			table.sort(dropped)
			changer.migrated = true
			CW.Warn("A saved " .. spec.Label .. " sound selection did not point at the " .. spec.Category
				.. " library and was removed for: " .. table.concat(dropped, ", ") .. ". Choose a new sound for them in the Guns tab.")
		end
	end
	changer.refreshCatalog()

	--// volume ---------------------------------------------------------------------------
	-- Volume of the sound the gun uses now.
	local function volumeOf(weapon)
		local value = tonumber(volumes[volumeKey(weapon, overrides[weapon])])
		if not value then return 1 end
		return math.clamp(value, 0, 2)
	end
	changer.volumeOf = volumeOf

	-- baseVolume is the game's own volume for that sound; the sound plays at baseVolume * the gun's volume.
	-- If the game itself changes the volume later (distance, per-shot values), that new value becomes
	-- the base, so the setting always scales the game's value.
	local function setScaledVolume(sound, data)
		local volume = data.tool and volumeOf(data.tool.Name) or 1
		local target = math.clamp(data.baseVolume * volume, 0, 10)
		data.lastVolume = target
		if sound.Volume ~= target then
			pcall(function() sound.Volume = target end)
		end
	end

	local function restoreSound(sound)
		local data = active[sound]
		if not data then return end
		active[sound] = nil
		if data.connection then
			pcall(function() data.connection:Disconnect() end)
		end
		if data.volumeConnection then
			pcall(function() data.volumeConnection:Disconnect() end)
		end
		if sound.Parent then
			pcall(function()
				sound.SoundId = data.originalId
				sound.Volume = data.originalVolume
			end)
		end
	end

	function changer.stop()
		generation = generation + 1
		refreshScheduled = false
		table.clear(assetIds)
		disconnectList(globalConnections)
		for _, connections in pairs(playerConnections) do
			disconnectList(connections)
		end
		table.clear(playerConnections)
		for container, data in pairs(watched) do
			disconnectList(data.connections)
			watched[container] = nil
		end
		for sound in pairs(active) do
			restoreSound(sound)
		end
	end

	--// applying ---------------------------------------------------------------------------
	-- targetId is the replacement file's asset id, or nil to keep the game's own sound and only scale its volume.
	local function applySound(sound, targetId, tool, player, container)
		local data = active[sound]
		-- A sound that was set up for a replacement file and now only needs its volume (or the other way
		-- round) is set up again from scratch.
		if data and (data.targetId == nil) ~= (targetId == nil) then
			restoreSound(sound)
			data = nil
		end
		if not data then
			local originalId, originalVolume = sound.SoundId, sound.Volume
			local baseVolume = originalVolume

			-- The game plays a CLONE of the Sound. The clone of a sound that was already handled arrives
			-- with the replacement id (when there is one) and the already scaled volume, so its original
			-- values (and the base the volume setting scales) come from the sound it was cloned from: a
			-- sibling in the same Handle. Without this the volume would be applied twice (0.5x would play at
			-- 0.25x). A clone whose volume the game set itself on the way in keeps that volume as its base.
			local sibling
			if targetId == nil or sound.SoundId == targetId then
				for other, otherData in pairs(active) do
					if other ~= sound and other.Parent == sound.Parent and other.Name == sound.Name
						and otherData.targetId == targetId then
						sibling = otherData
						break
					end
				end
			end
			if sibling then
				if targetId ~= nil then originalId = sibling.originalId end
				if math.abs(sound.Volume - sibling.lastVolume) <= 0.0001 then
					originalVolume, baseVolume = sibling.originalVolume, sibling.baseVolume
				end
			elseif spec.BaseVolume then
				baseVolume = spec.BaseVolume(sound.SoundId, player) or baseVolume
			end

			data = {
				originalId = originalId,
				originalVolume = originalVolume,
				baseVolume = baseVolume,
				lastVolume = baseVolume,
				tool = tool,
				player = player,
				container = container,
				targetId = targetId,
			}
			active[sound] = data
			if targetId ~= nil then
				local ok, connection = pcall(function()
					return sound:GetPropertyChangedSignal("SoundId"):Connect(function()
						local current = active[sound]
						if current and sound.Parent and sound.SoundId ~= current.targetId then
							pcall(function() sound.SoundId = current.targetId end)
						end
					end)
				end)
				if ok then data.connection = connection end
			end

			local okVolume, volumeConnection = pcall(function()
				return sound:GetPropertyChangedSignal("Volume"):Connect(function()
					local current = active[sound]
					if not current or not sound.Parent then return end
					if math.abs(sound.Volume - current.lastVolume) > 0.0001 then
						current.baseVolume = sound.Volume -- the game changed it: scale the new value
						setScaledVolume(sound, current)
					end
				end)
			end)
			if okVolume then data.volumeConnection = volumeConnection end
		else
			data.tool = tool
			data.player = player
			data.container = container
		end

		if targetId ~= nil and sound.SoundId ~= targetId then
			pcall(function() sound.SoundId = targetId end)
		end
		setScaledVolume(sound, data)
	end

	-- Engine asset id of an override file (cached in assetIds), or nil when the file is missing
	-- or cannot be loaded. Shared by the tool hook and the background pre-load below.
	local function resolveAsset(relativePath)
		local customAsset = CW.CustomIds.assetOf(relativePath)
		if customAsset then return customAsset end -- a custom ID: nothing to load from disk
		local cached = assetIds[relativePath]
		if cached then return cached end
		local filePath = CW.Paths.LIBRARY_ROOT .. "/" .. relativePath
		local okFile, exists = pcall(isfile, filePath)
		if not (okFile and exists) then return nil end
		local loaded, assetId = pcall(CW.Library.audioAsset, filePath)
		if not loaded or type(assetId) ~= "string" then return nil end
		assetIds[relativePath] = assetId
		return assetId
	end

	-- onlySound: a sound that just arrived in the tool (each shot clones one); the others are set up already.
	local function applyToTool(tool, player, container, onlySound)
		if not tool:IsA("Tool") then return end
		-- The gun's switch is on, and the gun is yours (or its "apply to others" is on too).
		local applies = enabledFor(tool.Name) and (player == LocalPlayer or othersFor(tool.Name))
		local relativePath = applies and overrides[tool.Name] or nil
		local targetId = type(relativePath) == "string" and resolveAsset(relativePath) or nil
		if not applies or (not targetId and math.abs(volumeOf(tool.Name) - 1) < 1e-6) then
			-- Nothing to change for this gun (switched off, or no usable replacement file and the game's own
			-- volume): put back whatever was changed before.
			for sound, data in pairs(active) do
				if data.tool == tool then restoreSound(sound) end
			end
			return
		end
		if onlySound then
			applySound(onlySound, targetId, tool, player, container)
			return
		end
		for _, descendant in ipairs(tool:GetDescendants()) do
			if descendant:IsA("Sound") and descendant.Name == spec.SoundName then
				applySound(descendant, targetId, tool, player, container)
			end
		end
	end

	-- Applies the current volume of one gun (or of every gun) to the sounds already there, without a
	-- full refresh: the sliders call this on every step while they are dragged.
	function changer.updateVolumes(weapon)
		for container, data in pairs(watched) do
			for _, child in ipairs(container:GetChildren()) do
				if child:IsA("Tool") and (weapon == nil or child.Name == weapon) then
					applyToTool(child, data.player, container)
				end
			end
		end
	end

	-- Sets the volume of the sound the gun uses now (the other sounds of that gun keep theirs).
	function changer.setVolume(weapon, value)
		value = math.clamp(tonumber(value) or 1, 0, 2)
		local key = volumeKey(weapon, overrides[weapon])
		volumes[key] = math.abs(value - 1) > 1e-6 and value or nil
		changer.updateVolumes(weapon)
	end

	local function unwatchContainer(container)
		local data = watched[container]
		if not data then return end
		watched[container] = nil
		disconnectList(data.connections)
		for sound, soundData in pairs(active) do
			if soundData.container == container then
				restoreSound(sound)
			end
		end
	end

	local function watchContainer(container, player)
		if watched[container] then return end
		local data = { player = player, connections = {} }
		watched[container] = data

		for _, child in ipairs(container:GetChildren()) do
			if child:IsA("Tool") then
				applyToTool(child, player, container)
			end
		end

		table.insert(data.connections, container.DescendantAdded:Connect(function(descendant)
			if descendant:IsA("Tool") then
				task.defer(applyToTool, descendant, player, container)
			elseif descendant:IsA("Sound") and descendant.Name == spec.SoundName then
				local tool = findSoundTool(descendant)
				if tool then applyToTool(tool, player, container, descendant) end
			end
		end))

		table.insert(data.connections, container.DescendantRemoving:Connect(function(descendant)
			if descendant:IsA("Sound") then
				restoreSound(descendant)
			elseif descendant:IsA("Tool") then
				for sound, soundData in pairs(active) do
					if soundData.tool == descendant then restoreSound(sound) end
				end
			end
		end))
	end

	local function removePlayer(player)
		local connections = playerConnections[player]
		if connections then
			disconnectList(connections)
			playerConnections[player] = nil
		end
		for container, data in pairs(watched) do
			if data.player == player then unwatchContainer(container) end
		end
	end

	local function watchPlayer(player)
		if playerConnections[player] then return end
		local connections = {}
		playerConnections[player] = connections

		table.insert(connections, player.CharacterAdded:Connect(function(character)
			watchContainer(character, player)
		end))
		table.insert(connections, player.CharacterRemoving:Connect(unwatchContainer))
		if player.Character then
			watchContainer(player.Character, player)
		end

		if player == LocalPlayer then
			local backpack = player:FindFirstChildOfClass("Backpack")
			if backpack then watchContainer(backpack, player) end
			table.insert(connections, player.ChildAdded:Connect(function(child)
				if child:IsA("Backpack") then watchContainer(child, player) end
			end))
		end
	end

	local function anyEnabled() return next(settings[spec.EnabledKey]) ~= nil end

	function changer.refresh()
		changer.stop()
		if not anyEnabled() then return end
		local current = generation -- taken after the stop: a newer refresh cancels this one
		for _, player in ipairs(Players:GetPlayers()) do
			watchPlayer(player)
		end
		table.insert(globalConnections, Players.PlayerAdded:Connect(watchPlayer))
		table.insert(globalConnections, Players.PlayerRemoving:Connect(removePlayer))

		-- Resolve the chosen files in the background, so the first sound of a weapon that is not in
		-- hand yet already plays the replaced file.
		task.defer(function()
			-- Snapshot first: resolving can yield, and the player may change a dropdown meanwhile.
			local pending = {}
			for _, relative in pairs(overrides) do
				if type(relative) == "string" then table.insert(pending, relative) end
			end
			for _, relative in ipairs(pending) do
				if current ~= generation or not anyEnabled() then return end
				pcall(resolveAsset, relative)
			end
		end)
	end

	function changer.schedule()
		if refreshScheduled then return end
		refreshScheduled = true
		local current = generation
		task.defer(function()
			if current ~= generation then return end
			refreshScheduled = false
			changer.refresh()
		end)
	end

	-- Removes one gun's choice when it is that relative path (a custom ID that was deleted).
	function changer.clearChoice(weapon, relative)
		changer.replaceChoice(weapon, relative, nil)
	end
	-- Moves one gun's choice from one relative path to another (a custom ID that was edited), or clears it.
	function changer.replaceChoice(weapon, oldRelative, newRelative)
		if weapon ~= nil and overrides[weapon] == oldRelative then
			-- The volume goes with the sound (an edited ID keeps it; a removed one leaves nothing behind).
			local volume = volumes[volumeKey(weapon, oldRelative)]
			volumes[volumeKey(weapon, oldRelative)] = nil
			if newRelative then volumes[volumeKey(weapon, newRelative)] = volume end
			overrides[weapon] = newRelative
			changer.schedule()
		end
	end

	-- A gun's two switches: its sound applies at all, and also to other players' shots with that gun.
	changer.enabledFor, changer.othersFor = enabledFor, othersFor
	function changer.setEnabled(weapon, on)
		settings[spec.EnabledKey][weapon] = on == true or nil
		changer.schedule()
	end
	function changer.setOthers(weapon, on)
		settings[spec.OthersKey][weapon] = on == true or nil
		changer.schedule()
	end

	-- One gun's whole setup, for the mesh profiles: { Choice, Enabled, Others, Volumes = { [sound] = volume } }, only
	-- what differs from the game's own. importGun puts one back (nil or {}: the game's own sound, off).
	function changer.exportGun(weapon)
		local prefix = weapon .. "|"
		local gunVolumes = {}
		for key, value in pairs(volumes) do
			if key:sub(1, #prefix) == prefix then gunVolumes[key:sub(#prefix + 1)] = value end
		end
		return {
			Choice = overrides[weapon], Enabled = settings[spec.EnabledKey][weapon], Others = settings[spec.OthersKey][weapon],
			Volumes = next(gunVolumes) and gunVolumes or nil,
		}
	end
	function changer.importGun(weapon, data)
		data = type(data) == "table" and data or {}
		local choice = data.Choice
		overrides[weapon] = type(choice) == "string" and (tailOf(weapon, choice) or isCustomId(choice)) and choice or nil
		settings[spec.EnabledKey][weapon] = data.Enabled == true or nil
		settings[spec.OthersKey][weapon] = data.Others == true or nil
		local prefix = weapon .. "|"
		for key in pairs(volumes) do
			if key:sub(1, #prefix) == prefix then volumes[key] = nil end
		end
		for sound, value in pairs(type(data.Volumes) == "table" and data.Volumes or {}) do
			local number = tonumber(value)
			if type(sound) == "string" and number and math.abs(math.clamp(number, 0, 2) - 1) > 1e-6 then
				volumes[prefix .. sound] = math.clamp(number, 0, 2)
			end
		end
		changer.schedule()
	end
	-- The same as replaceChoice, on a stored setup (a mesh that is not in use).
	function changer.replaceInExport(data, oldRelative, newRelative)
		if type(data) ~= "table" or data.Choice ~= oldRelative then return end
		data.Choice = newRelative
		local stored = type(data.Volumes) == "table" and data.Volumes or nil
		if stored then
			local volume = stored[oldRelative]
			stored[oldRelative] = nil
			if newRelative then stored[newRelative] = volume end
			if next(stored) == nil then data.Volumes = nil end
		end
	end

	-- value is what the weapon's dropdown shows: "Default" (the game's own sound) or a file label.
	function changer.set(weapon, value)
		if value == WEAPON_SOUND_DEFAULT then
			overrides[weapon] = nil
		else
			local entry = changer.catalog[weapon]
			local relative = entry and (entry.byLabel[value] or (entry.available[value] and value))
			if not relative then
				CW.Warn("Choose a sound file from the " .. spec.Category .. " library for " .. tostring(weapon))
				return
			end
			overrides[weapon] = relative
		end
		changer.schedule()
	end

	return changer
end

local shootSounds = createSoundChanger({
	Label = "shoot",
	Category = "WeaponSounds",
	SoundName = "ShootSound",
	OverridesKey = "WEAPON_SHOOT_SOUND_OVERRIDES",
	ConfigKey = "WEAPON_SHOOT_SOUNDS",
	EnabledKey = "WEAPON_SHOOT_SOUND_ENABLED_GUNS",
	OthersKey = "WEAPON_SHOOT_SOUND_OTHERS_GUNS",
	VolumeKey = "WEAPON_SOUND_VOLUME",
})

local reloadSounds = createSoundChanger({
	Label = "reload",
	Category = "ReloadSounds",
	SoundName = "ReloadSound",
	OverridesKey = "WEAPON_RELOAD_SOUND_OVERRIDES",
	ConfigKey = "WEAPON_RELOAD_SOUNDS",
	EnabledKey = "WEAPON_RELOAD_SOUND_ENABLED_GUNS",
	OthersKey = "WEAPON_RELOAD_SOUND_OTHERS_GUNS",
	VolumeKey = "WEAPON_RELOAD_SOUND_VOLUME",
	-- The game plays OTHER players' taser reload at 0.1 by checking for this exact SoundId. Once the id
	-- is replaced that check no longer matches, so the same level is applied here instead.
	BaseVolume = function(originalId, player)
		if originalId == "rbxassetid://82273261" and player ~= LocalPlayer then return 0.1 end
		return nil
	end,
})

local soundChangers = { shootSounds, reloadSounds }
CW.State.stopWeaponShootSoundOverrides = function()
	for _, changer in ipairs(soundChangers) do changer.stop() end
end

--// Per-mesh profiles: switching (storage and the fire point are in the Texture module) ------------------------
-- What a mesh keeps: Texture (ASSET_SELECTIONS.Textures), Shoot and Reload (the sound changers' setup of the gun)
-- and Effect (the gun's tracer: TRACER_GUN_<FIELD>[gun], or TRACER_SNIPER_* / TRACER_TASER_* for the M700 and the
-- Taser, plus TRACER_GUN_OTHERS[gun]). Only what differs from the game's own is kept.
local MeshProfiles = CW.MeshProfiles
local TRACER_FIELDS = { "ENABLED", "COLOR", "GLOW", "WIDTH", "LIFETIME", "TRANSPARENCY", "LIGHT" }
local TRACER_SPECIAL = { M700 = "TRACER_SNIPER_", Taser = "TRACER_TASER_" }
local SPECIAL_FIELDS = { ENABLED = true, COLOR = true, WIDTH = true, LIFETIME = true, TRANSPARENCY = true }

local function tracerMap(field)
	local key = "TRACER_GUN_" .. field
	if type(CW.Settings[key]) ~= "table" then CW.Settings[key] = {} end
	return CW.Settings[key]
end

local function exportEffect(gun)
	local out = {}
	local prefix = TRACER_SPECIAL[gun]
	for _, field in ipairs(TRACER_FIELDS) do
		local value
		if prefix then
			if SPECIAL_FIELDS[field] then
				value = CW.Settings[prefix .. field]
				local default = CW.Defaults[prefix .. field]
				if typeof(value) == "Color3" then value = value:ToHex() end
				if typeof(default) == "Color3" then default = default:ToHex() end
				if value == default or (type(value) == "number" and type(default) == "number"
					and math.abs(value - default) < 1e-6) then value = nil end
			end
		else
			value = tracerMap(field)[gun]
		end
		out[field] = value
	end
	out.OTHERS = tracerMap("OTHERS")[gun]
	return out
end

local function importEffect(gun, data)
	data = type(data) == "table" and data or {}
	local prefix = TRACER_SPECIAL[gun]
	for _, field in ipairs(TRACER_FIELDS) do
		local value = data[field]
		if prefix then
			if SPECIAL_FIELDS[field] then
				local default = CW.Defaults[prefix .. field]
				if typeof(default) == "Color3" then
					local ok, color = pcall(Color3.fromHex, type(value) == "string" and value or "")
					value = ok and typeof(color) == "Color3" and color or default
				elseif type(value) ~= type(default) then
					value = default
				end
				CW.Settings[prefix .. field] = value
			end
		else
			if field == "ENABLED" or field == "LIGHT" then
				value = value == true or nil
			elseif field == "COLOR" or field == "GLOW" then
				value = type(value) == "string" and value or nil
			else
				value = tonumber(value)
			end
			tracerMap(field)[gun] = value
		end
	end
	tracerMap("OTHERS")[gun] = data.OTHERS == true or nil
end

local function textureMap()
	local selections = CW.Settings.ASSET_SELECTIONS
	if type(selections.Textures) ~= "table" then selections.Textures = {} end
	return selections.Textures
end

-- Called with the gun after its mesh changed (or a removed mesh gave way to the gun's own): the Guns tab shows the
-- new values in that gun's controls.
MeshProfiles.listeners = {}
local function notifyProfile(gun)
	for _, listener in ipairs(MeshProfiles.listeners) do pcall(listener, gun) end
end

-- Puts a profile's values in place (nil: the game's own). The fire point stays in the profile.
local function loadProfile(gun, profile)
	profile = type(profile) == "table" and profile or {}
	textureMap()[gun] = type(profile.Texture) == "string" and profile.Texture or nil
	shootSounds.importGun(gun, profile.Shoot)
	reloadSounds.importGun(gun, profile.Reload)
	importEffect(gun, profile.Effect)
end

-- The values in place become the profile of the mesh (its fire point kept).
local function storeProfile(gun, key)
	local profile = MeshProfiles.get(gun, key, true)
	profile.Texture = textureMap()[gun]
	profile.Shoot = shootSounds.exportGun(gun)
	profile.Reload = reloadSounds.exportGun(gun)
	profile.Effect = exportEffect(gun)
end

-- The profile of the mesh in use keeps only its fire point: its other values are the ones in place.
local function clearInUse(gun, key)
	local profile = MeshProfiles.get(gun, key, false)
	if profile then
		profile.Texture, profile.Shoot, profile.Reload, profile.Effect = nil, nil, nil, nil
	end
	MeshProfiles.tidy(gun, key)
end

-- Makes a mesh the one in use on a gun (selection: "id:123", or nil for the gun's own). Returns true when it changed.
function MeshProfiles.switch(gun, selection)
	local new = type(selection) == "string" and selection:match("^id:%d+$") and selection or MeshProfiles.DEFAULT
	local old = MeshProfiles.keyOf(gun)
	CW.Library.setSelection("Meshes", gun, new ~= MeshProfiles.DEFAULT and new or nil)
	if new == old then return false end
	storeProfile(gun, old)
	loadProfile(gun, MeshProfiles.get(gun, new, false))
	clearInUse(gun, new)
	notifyProfile(gun)
	return true
end

-- A custom ID of a gun was edited (old -> new) or removed (new nil): the profiles that use it follow. Called before
-- the selections change. Meshes: the mesh's own profile goes with it; when the mesh in use is removed, the gun's own
-- mesh comes back with its values.
function MeshProfiles.replaceChoice(category, gun, oldRelative, newRelative)
	if type(gun) ~= "string" or type(oldRelative) ~= "string" then return end
	local byMesh = MeshProfiles.ofGun(gun, false)
	if category == "Meshes" then
		local inUse = MeshProfiles.keyOf(gun) == oldRelative
		local profile = byMesh and byMesh[oldRelative]
		if byMesh then byMesh[oldRelative] = nil end
		if newRelative and profile then MeshProfiles.ofGun(gun, true)[newRelative] = profile end
		if inUse and not newRelative then
			CW.Library.setSelection("Meshes", gun, nil)
			loadProfile(gun, MeshProfiles.get(gun, MeshProfiles.DEFAULT, false))
			clearInUse(gun, MeshProfiles.DEFAULT)
			notifyProfile(gun)
		end
		MeshProfiles.tidy(gun, oldRelative)
		return
	end
	for key, profile in pairs(byMesh or {}) do
		if type(profile) == "table" then
			if category == "Textures" and profile.Texture == oldRelative then profile.Texture = newRelative end
			if category == shootSounds.spec.Category then shootSounds.replaceInExport(profile.Shoot, oldRelative, newRelative) end
			if category == reloadSounds.spec.Category then reloadSounds.replaceInExport(profile.Reload, oldRelative, newRelative) end
			MeshProfiles.tidy(gun, key)
		end
	end
end

------------------------------------------------------------------------------
-- Custom ID row: [Asset ID] [Name] [Add ID] [Remove], inside the category it belongs to.
-- Add ID puts the ID in that category's own list (the gallery or the sound dropdown; for the guns,
-- only the chosen gun's list). Remove deletes the ID typed in the box or, with the box empty, the
-- custom ID that is selected right now, and clears every choice that used it.
------------------------------------------------------------------------------
local ContentProvider = game:GetService("ContentProvider")

-- Checks in the background that Roblox can load the asset. An audio ID that is private (or not
-- shared with this experience) fails here. onResult(loaded, why, extra): extra is what a mesh ID turned out to be.
local function checkCustomAsset(assetId, kind, onResult)
	-- PreloadAsync with the id as a plain string answers Failure for every audio and image id, even the game's
	-- own (checked in Studio), so it can't tell anything. What works:
	--   * audio: a silent Sound in SoundService; a valid audio the experience may play reaches IsLoaded (a
	--     private audio not shared with the game, a deleted one or a non-audio id never does);
	--   * image: PreloadAsync of an ImageLabel, whose status is Success for an image and Failure otherwise;
	--   * mesh: the mesh is loaded for real (CW.resolveMeshAsset, which also opens accessories and models).
	task.spawn(function()
		if kind == "Mesh" then
			local ok, found, why = pcall(CW.resolveMeshAsset, assetId:match("%d+$"))
			if ok and found then
				onResult(true, nil, found)
			else
				onResult(false, ok and why or found)
			end
			return
		end
		if kind == "Audio" then
			local sound = Instance.new("Sound")
			sound.Volume = 0
			sound.SoundId = assetId
			local ok, err = pcall(function() sound.Parent = game:GetService("SoundService") end)
			if not ok then
				sound:Destroy()
				onResult(false, tostring(err))
				return
			end
			pcall(function() ContentProvider:PreloadAsync({ sound }) end)
			local deadline = os.clock() + 6
			while not sound.IsLoaded and os.clock() < deadline do task.wait(0.1) end
			local loaded = sound.IsLoaded
			sound:Destroy()
			if loaded then
				onResult(true)
			else
				onResult(false, "did not load in 6 s")
			end
			return
		end
		local image = Instance.new("ImageLabel")
		image.Image = assetId
		local status
		local ok, err = pcall(function()
			ContentProvider:PreloadAsync({ image }, function(_, fetchStatus) status = fetchStatus end)
		end)
		image:Destroy()
		if not ok then
			onResult(false, tostring(err))
		elseif status == Enum.AssetFetchStatus.Success then
			onResult(true)
		else
			onResult(false, status and status.Name or "no answer")
		end
	end)
end

-- The row itself: CWUI's AddInputRow, or two text boxes and two buttons when an older cached CWUI
-- has no AddInputRow. Both give :Get(key), :Clear() and :Flash(button, text, seconds).
-- changed: optional, called on every letter typed (CWUI 3.1+).
local function inputRow(section, fields, buttons, changed)
	local row = section:InputRow({ Fields = fields, Buttons = buttons, Changed = changed })
	if row then return row end

	local boxes, buttonObjs = {}, {}
	local shim = {}
	local function values()
		local result = {}
		for key, box in pairs(boxes) do result[key] = box and box:Get() or "" end
		return result
	end
	for _, field in ipairs(fields) do
		boxes[field.Key] = section:Textbox({ Title = field.Title, Placeholder = field.Placeholder })
	end
	for index, button in ipairs(buttons) do
		buttonObjs[index] = { text = button.Title, control = section:Button({
			Title = button.Title,
			Callback = function() button.Callback(values(), shim) end,
		}) }
	end
	function shim:Get(key)
		local box = boxes[key]
		return box and box:Get() or ""
	end
	function shim:Clear()
		for _, box in pairs(boxes) do
			if box then box:Set("") end
		end
	end
	function shim:Set(key, text)
		local box = boxes[key]
		if box then box:Set(text or "") end
	end
	function shim:SetButtonText(index, text)
		local entry = buttonObjs[index]
		if not entry then return end
		entry.text = tostring(text)
		if entry.control and entry.control.SetText then pcall(entry.control.SetText, entry.control, entry.text) end
	end
	function shim:Flash(index, text, seconds)
		local entry = buttonObjs[index]
		if not (entry and entry.control and entry.control.SetText) then return end
		entry.control:SetText(text)
		task.delay(seconds or 1.5, function() pcall(entry.control.SetText, entry.control, entry.text) end)
	end
	return shim
end

-- Custom ID controls follow what is selected (Edit and Remove only while it is a custom ID): in a gallery's
-- header (attachActions), or in a gun sound's own editor (addAssetEditor). One light loop keeps them in step.
local customIdActionUpdaters = {}
CW.track("customIdActions", game:GetService("RunService").Heartbeat:Connect((function()
	local elapsed = 0
	return function(dt)
		elapsed += dt
		if elapsed < 0.25 then return end
		elapsed = 0
		for _, update in ipairs(customIdActionUpdaters) do pcall(update) end
	end
end)()))

-- Puts Edit and Remove in the header of the controls while canEdit; with an older cached CWUI, plain buttons
-- under the list. Returns a function(canEdit); it only touches the header when that changes.
local function attachActions(section, controls, onEdit, onRemove)
	local attached = {}
	for _, control in ipairs(controls or {}) do
		if type(control) == "table" and type(control.SetActions) == "function" then table.insert(attached, control) end
	end
	if #attached == 0 then
		section:Button({ Title = "Edit Selected ID", Callback = onEdit })
		section:Button({ Title = "Remove Selected ID", Callback = onRemove })
		return function() end
	end
	for _, control in ipairs(attached) do
		pcall(control.SetActions, control, { { Text = "Edit", Callback = onEdit }, { Text = "Remove", Callback = onRemove } })
	end
	local shown
	local function update(canEdit)
		canEdit = canEdit == true
		if shown == canEdit then return end
		shown = canEdit
		for _, control in ipairs(attached) do pcall(control.ShowActions, control, canEdit) end
	end
	update(false)
	return update
end

-- What one list's custom IDs need, however they are shown: add, rename, replace and remove, each asset
-- checked before it is saved.
-- opts = {
--   category  = "Hitmarkers" | "Textures" | "HitSounds" | "WeaponSounds" | "ReloadSounds"
--   kind      = "Audio" | "Image" | "Texture"      (placeholder text)
--   weapon    = function() return gun name end     (per-gun categories)
--   selected  = function() return saved choice ("id:123" or a file) end
-- }
-- view = { flash = function(text, seconds) end, saved = function(text) end }   (saved: after an add or an edit)
local function customIdEditor(opts, view)
	local category = opts.category
	local editor = { editingId = nil } -- the custom ID being edited; nil while adding
	local attempt = 0 -- each save or cancel takes a new number; a check that ends under an old one is dropped

	function editor.weapon() return opts.weapon and opts.weapon() or nil end
	function editor.selectedId()
		local selected = opts.selected and opts.selected()
		return type(selected) == "string" and selected:match("^id:(%d+)$") or nil
	end
	function editor.entry(id)
		return id and CW.CustomIds.get(category, editor.weapon(), id) or nil
	end

	local function afterChange()
		if refreshUIFromLibrary then guarded("Library refresh", refreshUIFromLibrary) end
		scheduleSave()
	end

	-- Every saved choice of the old ID (this gun only, for the per-gun categories) moves to the new one,
	-- or is cleared when there is no new one.
	local function moveChoices(weapon, oldRelative, newRelative)
		if category == "HitSounds" then
			CW.HitSounds.replaceChoice(weapon, oldRelative, newRelative)
			return
		end
		-- The meshes that keep this ID in their profiles (and a removed mesh in use gives way to the gun's own).
		CW.MeshProfiles.replaceChoice(category, weapon, oldRelative, newRelative)
		if newRelative then
			CW.Library.replaceSelectionOf(category, weapon, oldRelative, newRelative)
		else
			CW.Library.clearSelectionOf(category, weapon, oldRelative)
		end
		for _, changer in ipairs(soundChangers) do
			if changer.spec.Category == category then changer.replaceChoice(weapon, oldRelative, newRelative) end
		end
	end

	-- Why an ID can't be used, in words.
	local function loadFailureText(id, why)
		if opts.kind == "Mesh" then
			return "Custom ID " .. id .. " not saved: no mesh could be loaded from it (" .. tostring(why)
				.. "). It may be private, deleted, or not a mesh, an accessory or a model."
		end
		local what = opts.kind == "Audio" and "audio" or "image"
		return "Custom ID " .. id .. " not saved: Roblox could not load it as " .. what .. " (" .. tostring(why)
			.. "). It may be private (not shared with this game), deleted, or not "
			.. (opts.kind == "Audio" and "an audio" or "an image (a Decal ID instead of its Image ID?)") .. "."
	end

	-- Saves an ID that is known to load (or a new name for one already saved). extra: what a mesh ID turned out to
	-- be; with no name typed, the item's own name is used.
	local function commit(values, weapon, newId, oldId, extra)
		if extra and extra.Name and not (type(values.name) == "string" and values.name:match("%S")) then
			values = { id = values.id, name = extra.Name }
		end
		if not oldId or newId == oldId then
			-- A new ID, or a new name for the same one.
			local entry, reason, problem = CW.CustomIds.add(category, weapon, newId, values.name, extra)
			if not entry then
				view.flash(problem == "name" and "Name used" or "Invalid", 2)
				CW.Warn("Custom ID not saved: " .. tostring(reason))
				return
			end
			editor.editingId = nil
			view.saved(oldId and "Saved" or "Added")
			afterChange()
			return
		end
		-- Another ID in place of the edited one: the old one goes, the new one takes its choices.
		local old = CW.CustomIds.get(category, weapon, oldId)
		CW.CustomIds.remove(category, weapon, oldId)
		local name = (type(values.name) == "string" and values.name:match("%S")) and values.name or (old and old.Name)
		local entry, reason, problem = CW.CustomIds.add(category, weapon, newId, name, extra)
		if not entry then
			if old then CW.CustomIds.add(category, weapon, old.Id, old.Name, old) end -- put the old one back
			view.flash(problem == "name" and "Name used" or "Invalid", 2)
			CW.Warn("Custom ID not saved: " .. tostring(reason))
			return
		end
		moveChoices(weapon, CW.CustomIds.selectionOf(oldId), CW.CustomIds.selectionOf(newId))
		editor.editingId = nil
		view.saved("Saved")
		pcall(CW.reloadCoreAssets)
		afterChange()
	end

	-- An ID is saved only once Roblox has loaded it (audio as audio, image as image); a new name for an ID
	-- that is already saved needs no check. Pressing again while a check runs starts over with what is typed.
	function editor.save(values)
		attempt += 1
		local mine = attempt
		local weapon = editor.weapon()
		local newId = CW.CustomIds.parse(values.id)
		if not newId then
			view.flash("Invalid")
			return
		end
		local oldId = editor.editingId
		local known = (oldId and newId == oldId) or (not oldId and CW.CustomIds.get(category, weapon, newId) ~= nil)
		if known then
			commit(values, weapon, newId, oldId)
			return
		end
		view.flash("Checking", 10)
		local kind = (opts.kind == "Audio" or opts.kind == "Mesh") and opts.kind or "Image"
		checkCustomAsset("rbxassetid://" .. newId, kind, function(loaded, why, extra)
			if mine ~= attempt then return end
			if not loaded then
				view.flash("Invalid", 2)
				CW.Warn(loadFailureText(newId, why))
				return
			end
			commit(values, weapon, newId, oldId, extra)
		end)
	end

	-- Drops a check that is still running: nothing it finds is saved.
	function editor.cancel()
		attempt += 1
	end

	-- Deletes one custom ID and clears every choice that used it. Returns true when it was deleted.
	function editor.remove(id)
		local weapon = editor.weapon()
		if not id or not CW.CustomIds.remove(category, weapon, id) then return false end
		moveChoices(weapon, CW.CustomIds.selectionOf(id), nil)
		if editor.editingId == id then editor.editingId = nil end
		pcall(CW.reloadCoreAssets)
		afterChange()
		return true
	end

	return editor
end

-- A gallery's custom IDs: the form always shown under the gallery, Edit and Remove in the gallery's header
-- while a custom ID is selected (see attachActions). opts: as customIdEditor, plus controls = { the gallery }.
local function addCustomIdRow(section, opts)
	local row, editor
	local function setEditing(id)
		editor.editingId = id
		row:SetButtonText(1, id and "Save" or "Add")
	end
	local function reset()
		editor.cancel()
		row:Clear()
		setEditing(nil)
	end
	editor = customIdEditor(opts, {
		flash = function(text, seconds) row:Flash(1, text, seconds) end,
		saved = function(text)
			reset()
			row:Flash(1, text)
		end,
	})

	row = inputRow(section, {
		{ Key = "id", Title = opts.kind .. " ID", Placeholder = opts.kind .. " ID or link", Weight = 0.55 },
		{ Key = "name", Title = "Name (optional)", Placeholder = "Name (optional)", Weight = 0.45 },
	}, {
		{ Text = "Add", Title = "Add ID", Callback = function(values) editor.save(values) end },
		{ Text = "Cancel", Title = "Cancel", Callback = reset },
	})

	local function edit()
		local entry = editor.entry(editor.selectedId())
		if not entry then return end
		row:Set("id", entry.Id)
		row:Set("name", entry.Name)
		setEditing(entry.Id)
	end
	local function remove()
		local id = editor.selectedId()
		local wasEditing = id ~= nil and editor.editingId == id
		if editor.remove(id) and wasEditing then reset() end
	end
	local showActions = attachActions(section, opts.controls, edit, remove)
	table.insert(customIdActionUpdaters, function() showActions(editor.selectedId() ~= nil) end)
	return row
end

-- A gun's sound IDs, always shown in its drawer, in a panel of their own:
--   [Audio ID or link] [Name (optional)]
--   [Add | Save] [Cancel] [Edit] [Remove]
-- Add puts a new ID in this gun's list. Edit loads the selected custom ID into the boxes, and Save keeps the
-- change. Cancel drops what was typed, or the edit, and nothing is applied. Remove deletes the selected custom
-- ID (the edited one while editing). A button is shown only while it can do something.
-- opts: as customIdEditor. Returns { refresh } (the drawer calls it when its sound changes).
local function addAssetEditor(section, opts)
	local CAPTION = opts.kind == "Mesh" and "Add a mesh by its ID" or "Add a sound by its ID"
	local group = section:Group(CAPTION)
	local fields, buttons, editor

	local function refresh()
		if not (fields and buttons) then return end
		local editing = editor.editingId ~= nil
		local selected = editor.selectedId()
		local typed = (fields:Get("id") or "") ~= "" or (fields:Get("name") or "") ~= ""
		buttons:SetButtonText(1, editing and "Save" or "Add")
		if buttons.SetButtonVisible then
			buttons:SetButtonVisible(2, editing or typed)                               -- Cancel
			buttons:SetButtonVisible(3, selected ~= nil and selected ~= editor.editingId) -- Edit
			buttons:SetButtonVisible(4, (editor.editingId or selected) ~= nil)          -- Remove
		end
		if group.SetCaption then
			local entry = editing and editor.entry(editor.editingId)
			group:SetCaption(entry and ("Editing " .. entry.Name) or CAPTION)
		end
	end
	local function reset()
		editor.cancel()
		fields:Clear()
		editor.editingId = nil
		refresh()
	end

	editor = customIdEditor(opts, {
		flash = function(text, seconds) buttons:Flash(1, text, seconds) end,
		saved = function(text)
			reset()
			buttons:Flash(1, text)
		end,
	})
	fields = inputRow(group, {
		{ Key = "id", Title = opts.kind .. " ID", Placeholder = opts.kind .. " ID or link", Weight = 0.55 },
		{ Key = "name", Title = "Name (optional)", Placeholder = "Name (optional)", Weight = 0.45 },
	}, {}, refresh)
	buttons = inputRow(group, {}, {
		{ Text = "Add", Title = "Add ID", Callback = function()
			editor.save({ id = fields:Get("id"), name = fields:Get("name") })
		end },
		{ Text = "Cancel", Title = "Cancel", Callback = reset },
		{ Text = "Edit", Title = "Edit Selected ID", Callback = function()
			local entry = editor.entry(editor.selectedId())
			if not entry then return end
			editor.editingId = entry.Id
			fields:Set("id", entry.Id)
			fields:Set("name", entry.Name)
			refresh()
		end },
		{ Text = "Remove", Title = "Remove Selected ID", Callback = function()
			if editor.remove(editor.editingId or editor.selectedId()) then reset() end
		end },
	})
	refresh()
	table.insert(customIdActionUpdaters, refresh) -- the sound can also change from elsewhere (a library refresh)
	return { refresh = refresh }
end

-- One gun's sound, laid out the same in Hit Sound, Shoot Sounds and Reload Sounds:
--   <title>                    the sound in use (a list)
--   [ panel: sound by ID ]     the editor of this gun's custom IDs
--   Volume                     right under it: each sound of the gun keeps its own volume
-- spec = { title, options, value, volume, volumeNow(), onChoose(label), onVolume(v), editor = customIdEditor opts }
-- Returns { dropdown, volume }.
local function buildSoundDrawer(drawer, spec)
	local volume, editor
	local dropdown = drawer:Dropdown({
		Title = spec.title,
		Options = spec.options,
		Default = spec.value,
		Callback = function(value)
			spec.onChoose(value)
			if volume then volume:Set(spec.volumeNow(), true) end
			if editor then editor.refresh() end
		end,
	})
	guarded(spec.title .. " IDs", function() editor = addAssetEditor(drawer, spec.editor) end)
	volume = drawer:Slider({
		Title = "Volume",
		Min = 0,
		Max = 2,
		Default = spec.volume,
		Decimal = 2,
		Suffix = "x",
		Callback = spec.onVolume,
	})
	return { dropdown = dropdown, volume = volume }
end

------------------------------------------------------------------------------
-- Cursor by ID. The cursor needs the image's pixels (the red and green copies are tinted from them),
-- so the image is downloaded into the Cursors folder as a real PNG and used like any other cursor file.
-- assetdelivery needs a login, so the image comes from Roblox's public thumbnail API instead; it
-- accepts an Image ID or a Decal ID. The thumbnail is padded to a square: the transparent margins are
-- cropped and the longest side is capped at 256 px (the largest cursor size).
------------------------------------------------------------------------------
local CURSOR_MAX_SIDE = 256
local CURSOR_THUMBNAIL_URL = "https://thumbnails.roblox.com/v1/assets?assetIds=%s"
	.. "&returnPolicy=PlaceHolder&size=420x420&format=Png&isCircular=false"

-- A name that is safe as a file name: letters, digits, space, _ - . ( ); at most 40 characters.
local function cursorFileName(rawName, id)
	local name = type(rawName) == "string" and rawName:match("^%s*(.-)%s*$") or ""
	if name == "" then name = id end
	name = name:gsub("[^%w _%-%.%(%)]", "_"):gsub("^[%s%.]+", "")
	name = name:sub(1, 40):match("^(.-)[%s%.]*$")
	if name == "" then name = id end
	return name
end

-- Yields. Returns the thumbnail PNG bytes, or nil and the reason.
local function fetchCursorThumbnail(id)
	local url = string.format(CURSOR_THUMBNAIL_URL, id)
	for _ = 1, 6 do
		local ok, body = pcall(CW.httpGet, url)
		if not ok then return nil, "thumbnail request failed: " .. tostring(body) end
		local okJson, data = pcall(HttpService.JSONDecode, HttpService, body)
		local item = okJson and type(data) == "table" and type(data.data) == "table" and data.data[1]
		if type(item) ~= "table" then return nil, "unexpected answer from the thumbnail API" end
		if item.state == "Completed" and type(item.imageUrl) == "string" then
			local okImage, png = pcall(CW.httpGet, item.imageUrl)
			if not okImage then return nil, "image download failed: " .. tostring(png) end
			return png
		elseif item.state == "Pending" then
			task.wait(1) -- Roblox is still rendering it
		else
			return nil, "Roblox has no image for this ID (" .. tostring(item.state) .. ")"
		end
	end
	return nil, "the image is still being generated; try again in a few seconds"
end

-- Yields. Thumbnail PNG -> the cursor file's bytes (cropped, at most 256 px), or nil and the reason.
local function buildCursorPng(png)
	if type(png) ~= "string" or png:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "the download is not a PNG" end
	local ok, px, w, h = pcall(CW.parsePNG, png)
	if not ok then return nil, "could not read the PNG: " .. tostring(px) end
	px, w, h = CW.trimTransparent(px, w, h)
	if not px then return nil, "the image is fully transparent" end
	local longest = math.max(w, h)
	if longest > CURSOR_MAX_SIDE then
		local scale = CURSOR_MAX_SIDE / longest
		px, w, h = CW.resizePixels(px, w, h,
			math.max(1, math.floor(w * scale + 0.5)), math.max(1, math.floor(h * scale + 0.5)))
	end
	return CW.encodePNG(px, w, h)
end

-- Downloads one cursor image by ID and returns the finished PNG bytes, or nil and the reason. Yields.
local function downloadCursorPng(id)
	local png, why = fetchCursorThumbnail(id)
	if not png then return nil, why end
	return buildCursorPng(png)
end

local function addCursorIdRow(section, controls)
	local attempt = 0 -- each save or cancel takes a new number; a download that ends under an old one is dropped
	local row
	local editing -- the entry being edited; nil while adding

	local function afterChange()
		CW.Library.invalidate()
		if refreshUIFromLibrary then guarded("Library refresh", refreshUIFromLibrary) end
		scheduleSave()
	end
	local function pathOf(relative) return CW.Paths.LIBRARY_ROOT .. "/" .. relative end
	local function deleteFile(relative)
		if not CAPS.delfile then
			CW.Warn("delfile is missing: " .. pathOf(relative) .. " stays in the Cursors folder")
			return
		end
		local ok, err = pcall(delfile, pathOf(relative))
		if not ok then CW.Warn("Could not delete " .. pathOf(relative) .. ": " .. tostring(err)) end
	end
	-- The cursor in use, when it was added by ID.
	local function selectedEntry()
		local selected = CW.Library.relative(CW.Paths.CURSOR_FILE)
		return selected and CW.CustomIds.byFile("Cursors", nil, selected) or nil
	end
	local function setEditing(entry)
		editing = entry
		row:SetButtonText(1, entry and "Save" or "Add")
	end
	local function reset()
		attempt += 1
		row:Clear()
		setEditing(nil)
	end
	-- After a save: the form empties and the result shows on the button for a moment.
	local function finish(text)
		reset()
		row:Flash(1, text)
	end
	-- After a rename or a new ID: the old file goes, the entry and every choice point at the new file.
	local function replaceEntry(old, id, name, relative)
		CW.CustomIds.remove("Cursors", nil, old.Id)
		CW.CustomIds.add("Cursors", nil, id, name, { File = relative })
		if old.File ~= relative then deleteFile(old.File) end
		CW.Library.replaceSelectionOf("Cursors", nil, old.File, relative)
	end

	-- Pressing again while a download runs starts over with what is typed.
	local function save(values)
		attempt += 1
		local mine = attempt
		if not CAPS.files then
			row:Flash(1, "No files", 2)
			CW.Warn("Cursor by ID needs the executor's file functions")
			return
		end
		local id = CW.CustomIds.parse(values.id)
		if not id then
			row:Flash(1, "Invalid")
			return
		end
		local old = editing
		if not old and CW.CustomIds.get("Cursors", nil, id) then
			row:Flash(1, "Exists", 2)
			CW.Warn("Cursor ID " .. id .. " was already added")
			return
		end
		local name = cursorFileName(values.name ~= "" and values.name or (old and old.Id == id and old.Name or nil), id)
		local relative = "Cursors/" .. name .. ".png"
		local path = pathOf(relative)
		local okExists, exists = pcall(isfile, path)
		local ownFile = old and old.File == relative
		local taken = CW.CustomIds.nameTaken("Cursors", nil, name, old and old.Id, old and old.File)
			or ((okExists and exists and not ownFile) and ("a file named " .. relative .. " already exists") or nil)
		if taken then
			row:Flash(1, "Name used", 2)
			CW.Warn("Cursor ID not saved: " .. taken)
			return
		end

		-- Same ID, only a new name: the file is copied under the new name, nothing is downloaded.
		if old and old.Id == id then
			if not ownFile then
				local okRead, data = pcall(readfile, pathOf(old.File))
				if not okRead or type(data) ~= "string" then
					row:Flash(1, "Failed", 3)
					CW.Warn("Could not read " .. pathOf(old.File) .. ": " .. tostring(data))
					return
				end
				writefile(path, data)
				replaceEntry(old, id, name, relative)
			end
			finish("Saved")
			afterChange()
			pcall(CW.reloadCoreAssets)
			return
		end

		if not (CAPS.httpGet or CAPS.request) then
			row:Flash(1, "No HTTP", 2)
			CW.Warn("Cursor by ID needs HttpGet or request in the executor")
			return
		end
		row:Flash(1, "Loading", 60)
		task.spawn(function()
			local downloaded, data, why = pcall(downloadCursorPng, id)
			if mine ~= attempt then return end
			local ok, err = pcall(function()
				if not downloaded then error(data, 0) end
				if not data then error(why, 0) end
				writefile(path, data)
				if old then
					replaceEntry(old, id, name, relative)
				else
					local entry, reason = CW.CustomIds.add("Cursors", nil, id, name, { File = relative })
					if not entry then
						if CAPS.delfile then pcall(delfile, path) end
						error(reason, 0)
					end
				end
			end)
			if ok then
				finish(old and "Saved" or "Added")
				CW.Log("Cursor ID " .. id .. " saved as " .. relative)
				afterChange()
				if old then pcall(CW.reloadCoreAssets) end
			else
				row:Flash(1, "Failed", 3)
				CW.Warn("Cursor ID " .. id .. " not saved: " .. tostring(err))
			end
		end)
	end

	row = inputRow(section, {
		{ Key = "id", Title = "Image or Decal ID", Placeholder = "Image/Decal ID or link", Weight = 0.55 },
		{ Key = "name", Title = "Name (optional)", Placeholder = "Name (optional)", Weight = 0.45 },
	}, {
		{ Text = "Add", Title = "Add ID", Callback = function(values) save(values) end },
		{ Text = "Cancel", Title = "Cancel", Callback = reset },
	})

	local function edit()
		local entry = selectedEntry()
		if not entry then return end
		row:Set("id", entry.Id)
		row:Set("name", entry.Name)
		setEditing(entry)
	end
	-- Removes the cursor in use (only cursors added by ID: the others never show the button).
	local function remove()
		local entry = selectedEntry()
		if not entry then return end
		CW.CustomIds.remove("Cursors", nil, entry.Id)
		deleteFile(entry.File)
		CW.Library.clearSelectionOf("Cursors", nil, entry.File)
		if editing and editing.Id == entry.Id then reset() end
		afterChange()
		pcall(CW.reloadCoreAssets)
	end
	local showActions = attachActions(section, controls, edit, remove)
	table.insert(customIdActionUpdaters, function() showActions(selectedEntry() ~= nil) end)
	return row
end

------------------------------------------------------------------------------
-- Cursors tab: Hit Sound, Cursors, Hitmarkers
------------------------------------------------------------------------------
guarded("Cursors", function()
	local CursorsTab = Window:AddTab({ Name = "Cursors", Icon = uiIcons.Cursors or uiIcons.Effects })
	-- Section order on the page is the creation order: Cursors first, then Hit Sound, then Hitmarkers.
	-- Every section starts collapsed.
	local CursorSection = wrapSection(CursorsTab:AddSection({ Name = "Cursors", Open = false }))
	local HitSoundSection = wrapSection(CursorsTab:AddSection({ Name = "Hit Sound", Open = false }))
	local HitmarkerSection = wrapSection(CursorsTab:AddSection({ Name = "Hitmarkers", Open = false }))

	-- Name shown for an asset: a custom ID's name, or the file name without folder and extension.
	local function assetName(category, relative)
		if type(relative) ~= "string" then return "none" end
		local id = relative:match("^id:(%d+)$")
		if id then
			local entry = CW.CustomIds.get(category, nil, id)
			return entry and entry.Name or id
		end
		return ((relative:match("([^/]+)$") or relative):gsub("%.%w+$", ""))
	end
	-- "Settings for <asset>": tells which asset the controls under it belong to.
	local function ownerLabel(section, noun)
		local label = section:AddLabel("")
		return function(category)
			label:Set("Settings for " .. assetName(category, CW.Profiles.current[category]) .. ". Each " .. noun .. " keeps its own.")
		end
	end

	-- Hit Sound: what the drawers are about, then one drawer per gun, laid out like the shoot and reload sounds.
	guarded("Hit Sound", function()
		HitSoundSection:AddLabel("Each gun keeps its own hit sound, custom IDs and volume. Changes save on their own.")
		for _, gunName in ipairs(soundWeaponNames()) do
			local gun = gunName
			local options, entries = hitSoundCatalog(gun)
			local drawer = { gun = gun, entries = entries }
			local controls = buildSoundDrawer(HitSoundSection:AddSubSection(gun, false), {
				title = "Hit Sound",
				options = options,
				value = hitSoundLabel(entries, CW.HitSounds.relative(gun)),
				volume = CW.HitSounds.volume(gun),
				volumeNow = function() return CW.HitSounds.volume(gun) end,
				onChoose = function(label)
					local relative = hitSoundRelative(drawer.entries, label)
					if relative then CW.HitSounds.set(gun, relative) end
				end,
				onVolume = function(v) CW.HitSounds.setVolume(gun, v) end,
				editor = {
					category = "HitSounds",
					kind = "Audio",
					weapon = function() return gun end,
					selected = function() return CW.HitSounds.relative(gun) end,
				},
			})
			drawer.dropdown, drawer.volume = controls.dropdown, controls.volume
			table.insert(hitSoundDrawers, drawer)
		end
	end)

	guarded("Cursor", function()
		-- Size and colors regenerate the cursor images, so that waits until the slider or picker settles.
		local reloadThread = nil
		local function scheduleCursorReload(delay)
			if reloadThread then task.cancel(reloadThread) end
			reloadThread = task.delay(delay, function()
				reloadThread = nil
				if CW.reloadCursor then CW.reloadCursor() end
			end)
		end

		-- Choosing a cursor brings its own settings (CW.Profiles), then the cursor is built with them.
		-- A cursor from the gallery, or nil when the chosen one is clicked again: the game's own cursor.
		local function applyCursorFile(value)
			if value ~= nil and (type(value) ~= "table" or type(value.Path) ~= "string") then return end
			local relative = value and CW.Library.relative(value.Path) or nil
			CW.Paths.CURSOR_FILE = value and value.Path or nil
			CW.Library.setSelection("Cursors", nil, relative)
			CW.Profiles.use("Cursors", relative)
			if reloadThread then task.cancel(reloadThread) reloadThread = nil end
			if CW.reloadCursor then CW.reloadCursor() end
		end

		-- Every control below changes the cursor in use and saves it in that cursor's profile.
		local function change(key, value, reloadDelay)
			CW.Settings[key] = value
			CW.Profiles.store("Cursors")
			if reloadDelay then scheduleCursorReload(reloadDelay) end
		end

		CursorSection:AddLabel("Pick a cursor to use it. Click the chosen one again to go back to the game's cursor.")
		CursorGallery = CursorSection:Gallery({
			Name = "Cursor Library",
			Items = galleryItems("Cursors"),
			Default = CW.Paths.CURSOR_FILE,
			AllowDeselect = true,
			LazyLoad = true,
			Columns = 4,
			MaxHeight = 260,
			Callback = applyCursorFile,
		})

		guarded("Cursor Custom IDs", function() addCursorIdRow(CursorSection, { CursorGallery }) end)

		local showOwner = ownerLabel(CursorSection, "cursor")
		local controls = {}
		controls.CURSOR_TARGET_SIZE = CursorSection:Slider({
			Title = "Cursor Size",
			Min = 16,
			Max = 256,
			Default = CW.Settings.CURSOR_TARGET_SIZE,
			Suffix = "px",
			Callback = function(v) change("CURSOR_TARGET_SIZE", v, 2) end,
		})
		controls.CURSOR_TEAM_CHECK = CursorSection:Toggle({
			Title = "Team Check",
			Default = CW.Settings.CURSOR_TEAM_CHECK,
			Callback = function(on)
				change("CURSOR_TEAM_CHECK", on)
				CW.State.lastTarget = nil -- the cursor loop re-checks what is under the mouse right away
			end,
		})

		-- The colors sit in their own drawer: they matter only while Team Check is on.
		local Colors = CursorSection:AddSubSection("Team Check Colors", false)
		Colors:AddLabel("Over another player, the cursor takes one of these colors.")
		for _, entry in ipairs({ { "Enemy Color", "CURSOR_ENEMY_COLOR" }, { "Teammate Color", "CURSOR_TEAM_COLOR" } }) do
			local key = entry[2]
			controls[key] = Colors:Colorpicker({ -- nil on an old CWUI: the colors keep their defaults
				Title = entry[1],
				Default = CW.Settings[key],
				Callback = function(color) change(key, color, 1) end,
			})
		end
		Colors:Button({
			Title = "Reset Team Check",
			Callback = function()
				for _, key in ipairs({ "CURSOR_TEAM_CHECK", "CURSOR_ENEMY_COLOR", "CURSOR_TEAM_COLOR" }) do
					CW.Settings[key] = CW.Defaults[key]
					if controls[key] then controls[key]:Set(CW.Defaults[key], true) end
				end
				CW.Profiles.store("Cursors")
				CW.State.lastTarget = nil
				scheduleCursorReload(0.1)
				scheduleSave()
			end,
		})

		CW.Profiles.listeners.Cursors = function()
			for key, control in pairs(controls) do control:Set(CW.Settings[key], true) end
			CW.State.lastTarget = nil
			showOwner("Cursors")
		end
		showOwner("Cursors")
	end)

	-- Hitmarkers: the library, whose hitmarker the settings below belong to, then the size, then two drawers.
	guarded("Hitmarker", function()
		local function applyHitmarkerFile(value)
			if type(value) ~= "table" or type(value.Path) ~= "string" then return end
			CW.Paths.HITMARKER_FILE = value.Path
			local relative = CW.Library.relative(value.Path)
			CW.Library.setSelection("Hitmarkers", nil, relative)
			CW.Profiles.use("Hitmarkers", relative)
			if CW.reloadHitmarkerAsset then CW.reloadHitmarkerAsset() end
		end

		local function applySize()
			local size = CW.Settings.HITMARKER_SIZE
			if CW.HMTemplate then CW.HMTemplate.Size = UDim2.new(0, size, 0, size) end
		end
		local function change(key, value)
			CW.Settings[key] = value
			CW.Profiles.store("Hitmarkers")
			if key == "HITMARKER_SIZE" then applySize() end
		end

		HitmarkerGallery = HitmarkerSection:Gallery({
			Name = "Hitmarker Library",
			Items = galleryItems("Hitmarkers"),
			Default = CW.Paths.HITMARKER_FILE,
			LazyLoad = true,
			Columns = 4,
			MaxHeight = 260,
			Callback = applyHitmarkerFile,
		})

		guarded("Hitmarker Custom IDs", function()
			addCustomIdRow(HitmarkerSection, {
				category = "Hitmarkers", kind = "Image", controls = { HitmarkerGallery },
				selected = function() return CW.Library.relative(CW.Paths.HITMARKER_FILE) end,
			})
		end)

		local showOwner = ownerLabel(HitmarkerSection, "hitmarker")
		local controls = {}
		controls.HITMARKER_SIZE = HitmarkerSection:Slider({
			Title = "Hitmarker Size", Min = 8, Max = 200, Default = CW.Settings.HITMARKER_SIZE, Suffix = "px",
			Callback = function(v) change("HITMARKER_SIZE", v) end,
		})

		local Behavior = HitmarkerSection:AddSubSection("Behavior", false)
		controls.HITMARKER_RANDOM_ROTATION = Behavior:Toggle({
			Title = "Random Rotation", Default = CW.Settings.HITMARKER_RANDOM_ROTATION,
			Callback = function(on) change("HITMARKER_RANDOM_ROTATION", on) end,
		})
		controls.HITMARKER_FOLLOW_MOUSE = Behavior:Toggle({
			Title = "Follow Mouse", Default = CW.Settings.HITMARKER_FOLLOW_MOUSE,
			Callback = function(on) change("HITMARKER_FOLLOW_MOUSE", on) end,
		})

		local Timing = HitmarkerSection:AddSubSection("Timing", false)
		controls.HITMARKER_VISIBLE_DURATION = Timing:Slider({
			Title = "Visible Duration", Min = 0, Max = 1, Decimal = 2, Suffix = "s",
			Default = CW.Settings.HITMARKER_VISIBLE_DURATION,
			Callback = function(v) change("HITMARKER_VISIBLE_DURATION", v) end,
		})
		controls.HITMARKER_FADEOUT = Timing:Toggle({
			Title = "Fadeout", Default = CW.Settings.HITMARKER_FADEOUT,
			Callback = function(on) change("HITMARKER_FADEOUT", on) end,
		})
		controls.HITMARKER_FADEOUT_DURATION = Timing:Slider({
			Title = "Fadeout Duration", Min = 0, Max = 1, Decimal = 2, Suffix = "s",
			Default = CW.Settings.HITMARKER_FADEOUT_DURATION,
			Callback = function(v) change("HITMARKER_FADEOUT_DURATION", v) end,
		})

		CW.Profiles.listeners.Hitmarkers = function()
			for key, control in pairs(controls) do control:Set(CW.Settings[key], true) end
			applySize()
			showOwner("Hitmarkers")
		end
		showOwner("Hitmarkers")
	end)
end)

------------------------------------------------------------------------------
-- Guns tab: one page per gun (on an older CWUI, one section per gun). A page starts with the gun's 3D preview, then
-- its Mesh (with Adjust Mesh for a custom one) and its Texture (always open: the preview shows them), then its Gun
-- Settings (Shoot Sound, Effect, Reload Sound). Everything on a page is that gun's own and is saved on its own. The
-- sound and tracer controls keep the saved settings they always had, so nothing already saved is lost.
------------------------------------------------------------------------------
guarded("Guns", function()
	local GunsTab = Window:AddTab({ Name = "Guns", Icon = uiIcons.Guns or uiIcons.Visuals })
	local guns = soundWeaponNames()
	local texturable = {}
	for _, name in ipairs(CW.WeaponList or {}) do texturable[name] = true end

	local pager
	local fireMoved -- (gun, point, done): the fire point was moved in the preview (set by the Mesh controls)
	local PREVIEW_HINT = "Drag to rotate, scroll to zoom"
	local EDIT_HINT = "Drag an arrow to move where shots start"
	local FAILED_HINT = "This mesh could not be loaded. Pick it again to try again"
	-- The preview shows the gun of the page in view as it looks in your hand, framed by the gun's own size. While
	-- Edit Gun Fire Point is on (CW.State.meshEdit, one switch for every page): a dot where the shots start (the
	-- Muzzle, which moves with the mesh), with the preview's arrows on it to move it along the gun's left/right,
	-- down/up and back/forward. keep: the camera stays as it is (also from one gun to the next).
	refreshGunPreview = function(gun, keep)
		if not pager then return end
		local _, shown = pager:Get()
		if not shown or (gun and gun ~= shown) then return end
		local editing = CW.State.meshEdit == true
		local ok, model, center, size, fireAt, meshState = pcall(CW.weaponPreview, shown)
		if type(pager.SetMessage) == "function" then
			pager:SetMessage(ok and meshState == "loading" and "Loading the mesh" or nil)
		end
		if not ok then
			pager:SetModel(nil)
			return
		end
		local dot
		if model and editing and fireAt then
			dot = Instance.new("Part")
			dot.Name = "FirePoint"
			dot.Shape = Enum.PartType.Ball
			dot.Material = Enum.Material.SmoothPlastic -- Neon blows the color out in a preview (the orange shows as yellow)
			dot.Color = CWUI.Theme and CWUI.Theme.Accent or Color3.fromRGB(255, 128, 32)
			dot.Size = Vector3.one * math.clamp(size.Z * 0.03, 0.06, 0.15)
			dot.Anchored, dot.CanCollide, dot.CanQuery, dot.CanTouch = true, false, false, false
			dot.CFrame = CFrame.new(fireAt)
			dot.Parent = model
		end
		pager:SetModel(model, keep, center, size)
		if type(pager.SetHandle) == "function" then
			pager:SetHandle(dot, dot and function(point, done)
				if fireMoved then fireMoved(shown, point, done) end
			end or nil)
			pager:SetHint(meshState == "failed" and FAILED_HINT or dot and EDIT_HINT or PREVIEW_HINT)
		end
	end
	local buildGunPage -- (index): builds a gun's page the first time it is shown (below)
	if type(GunsTab.AddPager) == "function" then
		pager = GunsTab:AddPager({
			Pages = guns,
			Hint = PREVIEW_HINT,
			Changed = function(index)
				if buildGunPage then buildGunPage(index) end
				refreshGunPreview(nil, true)
			end,
		})
	end
	-- A mesh that finished loading shows on the guns already (Texture module); the preview follows.
	CW.onMeshLoaded = function() refreshGunPreview(nil, true) end

	-- After the Mesh or the Texture of a gun changes: the gun in your hand, then the preview.
	local function lookChanged(gun)
		if CW.reloadTextures then CW.reloadTextures() end
		refreshGunPreview(gun, true)
	end

	-- Mesh: the gun's own (Default) or one of its custom mesh IDs, which are added right under the list.
	-- Adjust Mesh, under them while a custom mesh is chosen: its size, place and turn on this gun, saved with its ID
	-- (ranges and defaults in CW.MeshAdjust). Each slider's right end does what the end of its name says. While one
	-- moves, the look is only put on again (the textures are not loaded again) and the file is saved a second later.
	local ADJUST_SLIDERS = { -- field, title, decimals, suffix
		{ "Size", "Size", 2, "x" },
		{ "Right", "Left / Right", 2 }, { "Up", "Down / Up", 2 }, { "Forward", "Back / Forward", 2 },
		{ "Turn", "Turn Left / Right", 0, "°" }, { "Tilt", "Tilt Down / Up", 0, "°" }, { "Roll", "Roll Left / Right", 0, "°" },
	}
	local editToggles = {} -- "Edit Gun Fire Point" of every page: one switch for all of them (CW.State.meshEdit, not saved)
	local editControls = {} -- what shows only while it is on, on every page
	local pageRefreshers = {} -- gun -> functions that show the gun's values again (after its mesh changed)
	local function onPageRefresh(gun, fn)
		pageRefreshers[gun] = pageRefreshers[gun] or {}
		table.insert(pageRefreshers[gun], fn)
	end
	-- Another mesh brings its own texture, sounds and effect (CW.MeshProfiles): the page shows them.
	table.insert(CW.MeshProfiles.listeners, function(gun)
		for _, fn in ipairs(pageRefreshers[gun] or {}) do pcall(fn) end
		scheduleSave()
	end)
	local pendingLook = {}
	local function adjustChanged(gun)
		if pendingLook[gun] then return end
		pendingLook[gun] = true
		task.defer(function()
			pendingLook[gun] = nil
			if CW.reapplyLooks then CW.reapplyLooks() end
			refreshGunPreview(gun, true)
		end)
	end
	-- The dot moves along the arrow being dragged in the preview; its place is saved for the mesh in use as it goes,
	-- and the guns you carry (and the preview) take it once the arrow is let go.
	fireMoved = function(gun, point, done)
		if not CW.setFirePointAt(gun, point) then return end
		if done then
			adjustChanged(gun)
			scheduleSave()
		end
	end
	local function setEditing(on, gun)
		CW.State.meshEdit = on == true
		for _, toggle in ipairs(editToggles) do toggle:Set(on == true, true) end
		for _, control in ipairs(editControls) do
			if control.Instance then control.Instance.Visible = on == true end
		end
		refreshGunPreview(gun, true)
	end
	local function selectedMeshId(gun)
		local selections = CW.Settings.ASSET_SELECTIONS.Meshes
		local selected = type(selections) == "table" and selections[gun]
		return type(selected) == "string" and selected:match("^id:(%d+)$") or nil
	end
	local function meshCatalog(gun)
		local options, byLabel, taken = { "Default" }, {}, {}
		for _, item in ipairs(CW.Library.items("Meshes", gun)) do
			local label = customIdLabel(item, taken)
			taken[label] = true
			byLabel[label] = item.CustomId
			table.insert(options, label)
		end
		return options, byLabel
	end
	local function meshLabel(byLabel, id)
		for label, savedId in pairs(byLabel) do
			if savedId == id then return label end
		end
		return "Default"
	end

	local function buildMesh(page, gun)
		local options, byLabel = meshCatalog(gun)
		local list, adjust
		local sliders = {}
		local function chosen()
			local id = selectedMeshId(gun)
			return id and CW.CustomIds.get("Meshes", gun, id), id
		end
		-- Adjust Mesh shows only for a custom mesh, with that mesh's values.
		local function showAdjust()
			local entry = chosen()
			if adjust.Instance then adjust.Instance.Visible = entry ~= nil end
			if not entry then return end
			for field, slider in pairs(sliders) do
				slider:Set(entry.Adjust and entry.Adjust[field] or CW.MeshAdjust[field][3], true)
			end
		end
		list = page:Dropdown({
			Title = "Mesh",
			Options = options,
			Default = meshLabel(byLabel, selectedMeshId(gun)),
			Callback = function(label)
				local id = byLabel[label]
				local entry = id and CW.CustomIds.get("Meshes", gun, id)
				if entry then CW.retryMesh(entry.Mesh or entry.Id) end -- one that failed before is tried again
				-- The mesh left keeps its texture, sounds and effect; the new one brings its own.
				CW.MeshProfiles.switch(gun, id and CW.CustomIds.selectionOf(id) or nil)
				showAdjust()
				lookChanged(gun)
			end,
		})
		guarded(gun .. " Mesh IDs", function()
			addAssetEditor(page, {
				category = "Meshes", kind = "Mesh",
				weapon = function() return gun end,
				selected = function()
					local id = selectedMeshId(gun)
					return id and CW.CustomIds.selectionOf(id) or nil
				end,
			})
		end)
		-- Edit Gun Fire Point: the fire point in the preview, with arrows to move where the shots start (saved for the
		-- mesh in use). The preview is the only place it shows.
		if pager then
			table.insert(editToggles, page:Toggle({
				Title = "Edit Gun Fire Point",
				Default = CW.State.meshEdit == true,
				Callback = function(on) setEditing(on, gun) end,
			}))
			local resetFire = page:Button({
				Title = "Reset Fire Point",
				Callback = function()
					CW.MeshProfiles.setFireOffset(gun, nil, nil)
					adjustChanged(gun)
					scheduleSave()
				end,
			})
			if resetFire then
				table.insert(editControls, resetFire)
				if resetFire.Instance then resetFire.Instance.Visible = CW.State.meshEdit == true end
			end
		end
		adjust = page:AddSubSection("Adjust Mesh", true)
		for _, spec in ipairs(ADJUST_SLIDERS) do
			local field, limits = spec[1], CW.MeshAdjust[spec[1]]
			sliders[field] = adjust:Slider({
				Title = spec[2], Min = limits[1], Max = limits[2], Default = limits[3], Decimal = spec[3], Suffix = spec[4],
				Callback = function(value)
					local entry, id = chosen()
					if not entry then return end
					local values = entry.Adjust or {}
					values[field] = value
					CW.CustomIds.setAdjust(gun, id, values)
					adjustChanged(gun)
				end,
			})
		end
		adjust:Button({
			Title = "Reset Adjustments",
			Callback = function()
				local entry, id = chosen()
				if not entry then return end
				CW.CustomIds.setAdjust(gun, id, nil)
				showAdjust()
				adjustChanged(gun)
			end,
		})
		showAdjust()
		table.insert(meshControls, function()
			options, byLabel = meshCatalog(gun)
			list:Refresh(options)
			list:Set(meshLabel(byLabel, selectedMeshId(gun)), true)
			showAdjust()
		end)
	end

	local function buildTexture(page, gun)
		local gallery = page:Gallery({
			Name = "Texture",
			Items = galleryItems("Textures", gun),
			Default = CW.Library.selectedPath("Textures", gun),
			AllowDeselect = true,
			LazyLoad = true,
			Columns = 4,
			MaxHeight = 260,
			Callback = function(item)
				CW.Library.setSelection("Textures", gun, type(item) == "table" and CW.Library.relative(item.Path) or nil)
				lookChanged(gun)
			end,
		})
		table.insert(textureGalleries, { weapon = gun, gallery = gallery })
		-- The texture of the mesh now in use (as refreshUIFromLibrary does it: Set only when it has to change, since
		-- setting the entry already selected would deselect it).
		onPageRefresh(gun, function()
			local selectedFile = CW.Library.selectedPath("Textures", gun)
			local current = gallery:Get()
			if selectedFile then
				if not (current and current.Path == selectedFile) then gallery:Set(selectedFile, true) end
			elseif current then
				gallery:Clear()
			end
		end)
		-- Custom IDs for this gun only, right under its gallery.
		guarded(gun .. " Texture Custom IDs", function()
			addCustomIdRow(page, {
				category = "Textures", kind = "Texture", controls = { gallery },
				weapon = function() return gun end,
				selected = function()
					local textures = CW.Settings.ASSET_SELECTIONS.Textures
					return type(textures) == "table" and textures[gun] or nil
				end,
			})
		end)
	end

	-- Shoot Sound / Reload Sound: the gun's two switches, then its sound, its custom IDs and its volume
	-- (buildSoundDrawer). Nothing of it applies while "Apply Custom Sound" is off, so choosing a sound (other than
	-- Default) or a volume (other than 1x) turns it on, and the switch shows it.
	local function buildSound(holder, changer, label, gun)
		local drawer = holder:AddSubSection(label .. " Sound", false)
		local building = true -- the controls' callbacks while the drawer is built are not the player's
		local enabled = drawer:Toggle({
			Title = "Apply Custom Sound",
			Default = changer.enabledFor(gun),
			Callback = function(on) changer.setEnabled(gun, on) end,
		})
		local others = drawer:Toggle({
			Title = "Apply To Other Players Locally",
			Default = changer.othersFor(gun),
			Callback = function(on) changer.setOthers(gun, on) end,
		})
		local function ensureEnabled()
			if building or changer.enabledFor(gun) then return end
			changer.setEnabled(gun, true)
			if enabled and enabled.Set then pcall(enabled.Set, enabled, true, true) end
			CW.Log(gun .. " " .. label:lower() .. " sound turned on (a sound or a volume was chosen)")
			scheduleSave()
		end
		local entry = changer.catalog[gun]
		local controls = buildSoundDrawer(drawer, {
			title = "Sound",
			options = entry and entry.options or { WEAPON_SOUND_DEFAULT },
			value = changer.label(gun, changer.overrides[gun]),
			volume = changer.volumeOf(gun),
			volumeNow = function() return changer.volumeOf(gun) end,
			onChoose = function(value)
				if value ~= WEAPON_SOUND_DEFAULT then ensureEnabled() end
				changer.set(gun, value)
			end,
			onVolume = function(v)
				if math.abs((tonumber(v) or 1) - 1) > 1e-6 then ensureEnabled() end
				changer.setVolume(gun, v)
			end,
			editor = {
				category = changer.spec.Category,
				kind = "Audio",
				weapon = function() return gun end,
				selected = function() return changer.overrides[gun] end,
			},
		})
		table.insert(changer.dropdowns, { weapon = gun, control = controls.dropdown, volume = controls.volume })
		-- The sound of the mesh now in use, with its switches and its volume.
		onPageRefresh(gun, function()
			if enabled and enabled.Set then enabled:Set(changer.enabledFor(gun), true) end
			if others and others.Set then others:Set(changer.othersFor(gun), true) end
			if controls.dropdown then controls.dropdown:Set(changer.label(gun, changer.overrides[gun]), true) end
			if controls.volume then controls.volume:Set(changer.volumeOf(gun), true) end
		end)
		task.defer(function() building = false end)
	end

	-- Effect: the gun's tracer. The switches come first, then the sliders, then the colors.
	local tracerPalette = {
		Violet = Color3.fromRGB(170, 0, 255),
		Lilac = Color3.fromRGB(200, 100, 255),
		Red = Color3.fromRGB(255, 64, 64),
		Green = Color3.fromRGB(64, 220, 96),
		Cyan = Color3.fromRGB(64, 210, 255),
		White = Color3.fromRGB(255, 255, 255),
	}

	-- Only used by the palette dropdown, which is the fallback when the loaded CWUI has no color picker.
	local function colorName(color)
		for name, paletteColor in pairs(tracerPalette) do
			if color == paletteColor then return name end
		end
		return "Violet"
	end

	-- Colors are userdata and can't be serialised: the Sniper and Taser colors are saved as hex strings
	-- (TRACER_SNIPER_COLOR_HEX, ...). The bullet guns store their colors as hex inside their own maps.
	local function colorFromHex(hex)
		if type(hex) ~= "string" then return nil end
		local ok, color = pcall(Color3.fromHex, hex)
		if ok and typeof(color) == "Color3" then return color end
		return nil
	end
	for _, entry in ipairs({
		{ "TRACER_SNIPER_COLOR", "TRACER_SNIPER_COLOR_HEX" },
		{ "TRACER_TASER_COLOR", "TRACER_TASER_COLOR_HEX" },
	}) do
		local settingKey, hexKey = entry[1], entry[2]
		CW.Settings[settingKey] = colorFromHex(CW.Settings[hexKey]) or CW.Settings[settingKey]
		-- The saved values are consumed here. If they stayed in CW.Settings, the generic save loop would
		-- write them back even after the player picks another color (or goes back to the default).
		CW.Settings[hexKey] = nil
	end

	-- A colour control. Returns a function that moves it to another colour without calling onChange,
	-- and the control itself.
	local function addColorControl(section, title, initial, onChange)
		local picker = section:Colorpicker({
			Title = title,
			Default = initial,
			Callback = onChange,
		})
		if picker then
			return function(color) picker:Set(color, true) end, picker
		end

		-- No color picker in the loaded CWUI: keep the old palette dropdown.
		local dropdown = section:Dropdown({
			Title = title,
			Options = { "Violet", "Lilac", "Red", "Green", "Cyan", "White" },
			Default = colorName(initial),
			Callback = function(name)
				onChange(tracerPalette[name])
			end,
		})
		return function(color) dropdown:Set(colorName(color), true) end, dropdown
	end

	-- The Sniper and the Taser keep their settings in TRACER_SNIPER_* / TRACER_TASER_*; every other gun
	-- keeps them in the TRACER_GUN_* maps (gun name -> value). OTHERS is a map for every gun.
	local SPECIAL = { M700 = "TRACER_SNIPER_", Taser = "TRACER_TASER_" }
	local KEYS = {
		enabled = "ENABLED", color = "COLOR", glow = "GLOW", width = "WIDTH",
		life = "LIFETIME", transparency = "TRANSPARENCY", light = "LIGHT", others = "OTHERS",
	}
	local D = CW.GunTracerDefaults

	local function gunMap(field) -- the settings map of one field (created again if a saved file replaced it)
		local key = "TRACER_GUN_" .. KEYS[field]
		if type(CW.Settings[key]) ~= "table" then CW.Settings[key] = {} end
		return CW.Settings[key]
	end

	-- The value of one field for one gun: its own, or the starting one.
	local function getFor(gun, field)
		local prefix = SPECIAL[gun]
		if prefix then
			local value = CW.Settings[prefix .. KEYS[field]]
			if field == "enabled" then return value == true end
			if field == "light" or field == "glow" then return nil end -- these two do not apply to them
			if value == nil then return D[field] end
			return value
		end
		local stored = gunMap(field)[gun]
		if field == "enabled" or field == "light" then return stored == true end
		if field == "color" or field == "glow" then return colorFromHex(stored) or D[field] end
		return tonumber(stored) or D[field]
	end

	local function setFor(gun, field, value)
		local prefix = SPECIAL[gun]
		if prefix then
			if field == "light" or field == "glow" then return end
			if field == "enabled" then value = value == true end
			CW.Settings[prefix .. KEYS[field]] = value
			return
		end
		if field == "enabled" or field == "light" then
			value = value and true or nil
		elseif field == "color" or field == "glow" then
			value = value:ToHex()
		end
		gunMap(field)[gun] = value
	end

	-- The Sniper and the Taser have no glow and no light, and a longer lifetime range (their tracer fades
	-- over seconds).
	local perGun = {} -- gun -> its controls, so "Apply To All Guns" can update the other pages

	-- Puts a gun's saved values back into its controls without saving anything.
	local function refreshGun(gun)
		local c = perGun[gun]
		if not c then return end
		c.enabled:Set(getFor(gun, "enabled"), true)
		if c.light then c.light:Set(getFor(gun, "light") == true, true) end
		c.width:Set(getFor(gun, "width"), true)
		c.life:Set(getFor(gun, "life"), true)
		c.transparency:Set(getFor(gun, "transparency"), true)
		c.setColor(getFor(gun, "color"))
		if c.setGlow then c.setGlow(getFor(gun, "glow") or D.glow) end
	end

	-- Copies one gun's tracer look to every gun. The Sniper and the Taser only get the color.
	local function applyToAll(sourceGun)
		local special = SPECIAL[sourceGun] ~= nil
		local look = {
			enabled = getFor(sourceGun, "enabled"),
			color = getFor(sourceGun, "color"),
			width = getFor(sourceGun, "width"),
			life = getFor(sourceGun, "life"),
			transparency = getFor(sourceGun, "transparency"),
		}
		if not special then
			look.glow = getFor(sourceGun, "glow")
			look.light = getFor(sourceGun, "light")
		end

		for _, name in ipairs(guns) do
			if name ~= sourceGun then
				setFor(name, "color", look.color)
				if not SPECIAL[name] then
					setFor(name, "enabled", look.enabled)
					setFor(name, "width", math.clamp(look.width, 0.01, 0.5))
					setFor(name, "life", math.clamp(look.life, 0.01, 1))
					setFor(name, "transparency", math.clamp(look.transparency, 0, 1))
					if look.glow ~= nil then setFor(name, "glow", look.glow) end
					if look.light ~= nil then setFor(name, "light", look.light) end
				end
				refreshGun(name)
			end
		end

		scheduleSave()
		CW.Log("Applied the " .. sourceGun .. " tracer to all guns (M700 and Taser: color only).")
	end

	local function buildEffect(holder, gun)
		local special = SPECIAL[gun] ~= nil
		local drawer = holder:AddSubSection("Effect", false)
		local c = {}

		-- switches
		c.enabled = drawer:Toggle({
			Title = "Apply Custom Tracer",
			Default = getFor(gun, "enabled"),
			Callback = function(on) setFor(gun, "enabled", on) end,
		})
		c.others = drawer:Toggle({
			Title = "Apply To Other Players Locally",
			Default = gunMap("others")[gun] == true,
			Callback = function(on) gunMap("others")[gun] = on == true or nil end,
		})
		if not special then
			c.light = drawer:Toggle({
				Title = "Tracer Light",
				Default = getFor(gun, "light") == true,
				Callback = function(on) setFor(gun, "light", on) end,
			})
		end

		-- sliders
		c.width = drawer:Slider({
			Title = "Tracer Width",
			Min = 0.01,
			Max = 0.5,
			Default = getFor(gun, "width"),
			Decimal = 2,
			Callback = function(v) setFor(gun, "width", v) end,
		})
		c.life = drawer:Slider({
			Title = "Tracer Lifetime",
			Min = 0.01,
			Max = special and 5 or 1,
			Default = getFor(gun, "life"),
			Decimal = 2,
			Suffix = "s",
			Callback = function(v) setFor(gun, "life", v) end,
		})
		c.transparency = drawer:Slider({
			Title = "Tracer Transparency",
			Min = 0,
			Max = 1,
			Default = getFor(gun, "transparency"),
			Decimal = 2,
			Callback = function(v) setFor(gun, "transparency", v) end,
		})

		-- colors
		c.setColor = addColorControl(drawer, "Tracer Color",
			getFor(gun, "color"), function(color) setFor(gun, "color", color) end)
		if not special then
			c.setGlow = addColorControl(drawer, "Glow Color",
				getFor(gun, "glow") or D.glow, function(color) setFor(gun, "glow", color) end)
		end

		drawer:Button({
			Title = "Apply to All Guns",
			Callback = function() applyToAll(gun) end,
		})

		perGun[gun] = c
		-- The effect of the mesh now in use.
		onPageRefresh(gun, function()
			refreshGun(gun)
			if c.others then c.others:Set(gunMap("others")[gun] == true, true) end
		end)
	end

	-- With the pager, each gun's page is built the first time it is shown; at the start only the page in view
	-- (all nine were most of the time the interface took to build). A page built later loses nothing: what it
	-- shows comes from the settings, and what the pages share works from the settings too (sound and tracer
	-- choices, Apply to All Guns, the Edit Gun Fire Point switch, the library lists).
	local builtPages = {}
	buildGunPage = function(index)
		local gun = guns[index]
		if not gun or builtPages[index] then return end
		builtPages[index] = true
		guarded(gun .. " page", function()
			local raw = pager and pager:Page(index) or GunsTab:AddSection({ Name = gun, Open = false })
			local page = wrapSection(raw)
			guarded(gun .. " Mesh", function() buildMesh(page, gun) end)
			if texturable[gun] then guarded(gun .. " Texture", function() buildTexture(page, gun) end) end
			local settings = pager and wrapSection(raw:AddSection({ Name = "Gun Settings", Open = false }))
				or page:AddSubSection("Gun Settings", false)
			guarded(gun .. " Shoot Sound", function() buildSound(settings, shootSounds, "Shoot", gun) end)
			guarded(gun .. " Effect", function() buildEffect(settings, gun) end)
			guarded(gun .. " Reload Sound", function() buildSound(settings, reloadSounds, "Reload", gun) end)
		end)
	end
	if pager then
		buildGunPage((pager:Get()) or 1)
		-- The other pages are built once the window is open, a few frames apart, so switching to one later is
		-- instant and the start does not wait for them.
		table.insert(interface.whenOpen, function()
			for index in ipairs(guns) do
				if not builtPages[index] then
					task.wait(0.15)
					if not isCurrentRun() or Window._destroyed then return end
					buildGunPage(index)
				end
			end
		end)
	else
		for index in ipairs(guns) do buildGunPage(index) end -- an old CWUI: one section per gun
	end
	refreshGunPreview(nil, false)
end)

------------------------------------------------------------------------------
-- Utilities tab
------------------------------------------------------------------------------
guarded("Utilities", function()
	local UtilityTab = Window:Tab({ Title = "Utilities" })

	local StarterGui = game:GetService("StarterGui")
	local ContextActionService = game:GetService("ContextActionService")
	local RunService = game:GetService("RunService")
	-- Kept in CW.State so a re-run still knows that the chat was hidden with Z.
	local chatHidden = CW.State.chatHidden == true
	-- >>> SPRINT TOGGLE BEGIN
	-- Toggle Sprint with Shift.
	--
	-- How the game handles sprint (ClientInputHandler, read from the decompiled place):
	--   Shift down -> t1.isRunning = true,  Humanoid.WalkSpeed = 24   (only when nothing else is active)
	--   Shift up   -> t1.isRunning = false, Humanoid.WalkSpeed = 16
	--   C          -> crouches only when no flag except isCrouching is set; isRunning counts, so the game
	--                 refuses to crouch while it believes Shift is held.
	-- isRunning lives in a local table of the game's script and is used for nothing else, so a sprint is
	-- really just "WalkSpeed 24".
	--
	-- The first versions of this toggle swallowed the Shift release to keep isRunning true, and that is
	-- exactly what made C useless. Now the release reaches the game untouched: it ends its own sprint
	-- (isRunning false), so C crouches natively, with no delay and no replayed keys. The toggle only puts
	-- WalkSpeed back to 24 on every frame while it is latched. No executor functions are needed.
	--
	-- Pausing: the game sets the "BackpackEnabled" attribute of the player to false while it crouches, is
	-- tased, arrested or in a camera, and back to true when that ends. A latched sprint pauses while it is
	-- false and resumes by itself afterwards, so standing up from a crouch keeps you running.
	local WALK_SPEED, SPRINT_SPEED = 16, 24

	local sprintLatched = false -- the toggle is holding a sprint
	local heldShiftKeys = {}
	local sprintStepConn        -- per-frame enforcement, connected only while latched
	local cachedHumanoid

	-- Leftovers of an older build of this script that may still be bound or connected.
	pcall(function() ContextActionService:UnbindAction("CycleWareCrouchFromSprint") end)
	if CW.State.sprintStepConn then
		pcall(function() CW.State.sprintStepConn:Disconnect() end)
		CW.State.sprintStepConn = nil
	end

	local function getHumanoid()
		local character = LocalPlayer.Character
		if character and cachedHumanoid and cachedHumanoid.Parent == character then
			return cachedHumanoid
		end
		cachedHumanoid = character and character:FindFirstChildOfClass("Humanoid") or nil
		return cachedHumanoid
	end

	-- True while the game has the player in a state where it would not let them sprint.
	local function sprintPaused(humanoid)
		local backpackEnabled = LocalPlayer:GetAttribute("BackpackEnabled")
		if backpackEnabled ~= nil then
			return backpackEnabled == false
		end
		-- Attribute missing (the game changed): fall back to the crouch camera offset.
		return humanoid.CameraOffset.Y < -1
	end

	local function stopSprintEnforcement()
		sprintLatched = false
		if sprintStepConn then
			sprintStepConn:Disconnect()
			sprintStepConn = nil
		end
		CW.State.sprintStepConn = nil
	end

	-- Runs before physics on every frame while the sprint is latched.
	local function enforceSprint()
		local humanoid = getHumanoid()
		if not humanoid or humanoid.Health <= 0 or not CW.Settings.SHIFT_TOGGLE_ENABLED then
			stopSprintEnforcement()
			return
		end

		local speed = humanoid.WalkSpeed
		if speed == 0 then
			-- Tased or arrested: the game ends its sprint there, so the toggle ends with it.
			stopSprintEnforcement()
		elseif sprintPaused(humanoid) then
			-- Crouching and similar. The game only slows a crouch down 0.2 s after it starts, so drop
			-- from sprint speed right away instead of sliding along at 24.
			if speed > WALK_SPEED then humanoid.WalkSpeed = WALK_SPEED end
		elseif speed == WALK_SPEED then
			humanoid.WalkSpeed = SPRINT_SPEED
		end
	end

	local function latchSprint()
		sprintLatched = true
		if not sprintStepConn then
			sprintStepConn = RunService.Stepped:Connect(enforceSprint)
			CW.State.sprintStepConn = sprintStepConn
		end
	end

	-- Ends a latched sprint now, the way the game does when Shift is released: walking speed, unless the
	-- game is holding the player in another state, or Shift is physically down (the game then ends the
	-- sprint itself when it is released).
	local function unlatchSprint()
		local wasLatched = sprintLatched
		stopSprintEnforcement()
		if not wasLatched then return end

		local humanoid = getHumanoid()
		if humanoid and humanoid.WalkSpeed == SPRINT_SPEED and not sprintPaused(humanoid)
			and not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			humanoid.WalkSpeed = WALK_SPEED
		end
	end

	local function onSprintShift(_, inputState, inputObject)
		local keyCode = inputObject and inputObject.KeyCode

		if inputState == Enum.UserInputState.Begin then
			if keyCode and heldShiftKeys[keyCode] then
				return Enum.ContextActionResult.Pass
			end

			local anotherShiftHeld = next(heldShiftKeys) ~= nil
			if keyCode then heldShiftKeys[keyCode] = true end
			if anotherShiftHeld or not CW.Settings.SHIFT_TOGGLE_ENABLED then
				return Enum.ContextActionResult.Pass
			end

			if sprintLatched then
				unlatchSprint() -- also while crouched: cancels the sprint that was waiting to resume
			else
				local humanoid = getHumanoid()
				-- Where the game ignores Shift, the toggle ignores it too.
				if humanoid and humanoid.Health > 0 and humanoid.SeatPart == nil and not sprintPaused(humanoid) then
					latchSprint()
				end
			end
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			if keyCode then heldShiftKeys[keyCode] = nil end
		end

		-- Never sunk: the game has to see every press and every release of Shift.
		return Enum.ContextActionResult.Pass
	end

	ContextActionService:UnbindAction("CycleWareSprintToggle")
	ContextActionService:BindActionAtPriority(
		"CycleWareSprintToggle",
		onSprintShift,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.LeftShift
	)

	local function onRightShiftAction(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			Window:ToggleVisibility()
		end
		-- Always sunk: the game reads RightShift as sprint, and opening the menu must not make
		-- the character run.
		return Enum.ContextActionResult.Sink
	end

	ContextActionService:UnbindAction("CycleWareProtectSprint")
	ContextActionService:BindActionAtPriority(
		"CycleWareProtectSprint",
		onRightShiftAction,
		false,
		Enum.ContextActionPriority.High.Value + 1,
		Enum.KeyCode.RightShift
	)

	if CW.State.sprintCharacterConn then
		CW.State.sprintCharacterConn:Disconnect()
	end
	CW.State.sprintCharacterConn = LocalPlayer.CharacterAdded:Connect(function()
		stopSprintEnforcement()
		table.clear(heldShiftKeys)
		cachedHumanoid = nil
	end)

	-- Used by the cleanup of the script: ends the sprint and drops the per-frame connection.
	CW.State.stopSprintToggle = unlatchSprint

	UtilityTab:Toggle({
		Title = "Toggle Sprint with Shift",
		Default = CW.Settings.SHIFT_TOGGLE_ENABLED == true,
		Callback = function(enabled)
			CW.Settings.SHIFT_TOGGLE_ENABLED = enabled == true
			-- Turning the toggle off also ends the sprint it was holding.
			if not CW.Settings.SHIFT_TOGGLE_ENABLED then
				unlatchSprint()
			end
		end,
	})
	-- <<< SPRINT TOGGLE END

	-- The chat is no longer forced on at load: it is only touched by the Z toggle below.
	local function setChatVisible(visible)
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, visible)
		end)
		pcall(function()
			StarterGui:SetCore("ChatActive", visible)
		end)
	end

	if CW.State.chatToggleConn then
		CW.State.chatToggleConn:Disconnect()
	end
	CW.State.chatToggleConn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or not CW.Settings.CHAT_TOGGLE_ENABLED then return end
		if input.KeyCode ~= Enum.KeyCode.Z then return end
		-- Z is also the sniper's zoom (GunController): with one in hand it is left to the game.
		local character = LocalPlayer.Character
		local held = character and character:FindFirstChildOfClass("Tool")
		if held and held:GetAttribute("Behavior") == "Sniper" then return end

		chatHidden = not chatHidden
		CW.State.chatHidden = chatHidden
		setChatVisible(not chatHidden)
	end)

	UtilityTab:Toggle({
		Title = "Toggle Chat with Z",
		Default = CW.Settings.CHAT_TOGGLE_ENABLED == true,
		Callback = function(enabled)
			CW.Settings.CHAT_TOGGLE_ENABLED = enabled == true
			if not CW.Settings.CHAT_TOGGLE_ENABLED then
				chatHidden = false
				CW.State.chatHidden = false
				setChatVisible(true)
			end
		end,
	})

	-- Anti-AFK (AntiAFK module): on by default.
	if CW.setAntiAFK then
		UtilityTab:Toggle({
			Title = "Anti-AFK",
			Default = CW.Settings.ANTI_AFK_ENABLED == true,
			Callback = function(enabled) CW.setAntiAFK(enabled == true) end,
		})
		UtilityTab:AddLabel("Anti-AFK keeps Roblox from disconnecting you after 20 minutes without input.")
	end

	-- >>> AUTO RELOAD BEGIN
	-- Auto reload (off by default).
	--
	-- How the game handles a reload (ReplicatedStorage.Scripts.ToolScripts.GunController):
	--   * Every gun keeps Local_CurrentAmmo (the client's count) and Local_ReloadSession (0 when idle, a
	--     timestamp while a reload counts down). reload() only checks that no reload is running. It does NOT
	--     check that the magazine is empty, so any call on a full gun starts a whole reload (animation, "..."
	--     label, a request to the server, the cooldown).
	--   * reload() is reached by the R key (InputBegan) and by GunFrame.TouchReloadButton.MouseButton1Down,
	--     whose handler is just "reload()". The button path needs no key event, so it runs in the same frame
	--     it is fired and is not subject to gameProcessed or to a focused chat box.
	--   * Equipping is done by Character.ChildAdded, and it overwrites Local_CurrentAmmo with the server's
	--     CurrentAmmo (synchronously, no yield before it). Until that handler has run, Local_CurrentAmmo still
	--     holds the value from the last time the gun was held, and the order of two handlers on the same event
	--     is not guaranteed.
	--   * Unequipping does not cancel a reload: the countdown goes on and refills the gun only if it is held
	--     again by the time it ends. The equip handler also writes the server's count into the label, which
	--     replaces the "..." the game itself wanted to show.
	--
	-- Speed: the reload is requested in the same frame the last bullet is fired. The change of
	-- Local_CurrentAmmo to 0 queues a check with task.defer (it runs right after the game's shooting code
	-- yields, so the game cannot overwrite the "..." label afterwards), and the check fires the game's own
	-- reload button signal. A per-frame check stays on as a safety net and handles retries.
	--
	-- Safety: the first versions pressed R from an event handler and sometimes read the stale 0 left in
	-- Local_CurrentAmmo from the previous time the gun was held, before the game's equip handler had refreshed
	-- it (an extra reload after unequip/equip). Now every check is deferred until the game's handlers have run,
	-- and a 0 that was only found by looking (not one the gun just changed to) is trusted once the count matches
	-- the server's (the game copies it at equip) or after a short settle time. A 0 that arrives as a change
	-- while the gun is being watched is a real shot and needs no wait. Everything is read again right before
	-- the request.
	--
	-- Executors: the button signal is fired with firesignal (or getconnections). If neither exists, the startup
	-- report says so and the R key is used. If they exist but fail, that error is kept, warned once, and the
	-- R key is used instead.
	local VirtualInputManager
	pcall(function()
		VirtualInputManager = game:GetService("VirtualInputManager")
	end)
	local autoReloadWarned = false

	local function pressReloadKey()
		if VirtualInputManager then
			local pressed = pcall(function()
				VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.R, false, game)
			end)
			if pressed then
				task.wait(0.02)
				local released, releaseError = pcall(function()
					VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.R, false, game)
				end)
				if released then return true end
				if not autoReloadWarned then
					autoReloadWarned = true
					CW.Warn("Auto Reload could not release the R key: " .. tostring(releaseError))
				end
				return false
			end
		end

		if X.keypress and X.keyrelease then
			local pressed = pcall(X.keypress, 0x52)
			if pressed then
				task.wait(0.02)
				local released, releaseError = pcall(X.keyrelease, 0x52)
				if released then return true end
				if not autoReloadWarned then
					autoReloadWarned = true
					CW.Warn("Auto Reload could not release the R key: " .. tostring(releaseError))
				end
				return false
			end
		end

		if type(keytap) == "function" then
			local ok = pcall(keytap, 0x52)
			if ok then return true end
		end
		if type(keystroke) == "function" then
			local ok = pcall(keystroke, 0x52)
			if ok then return true end
		end

		if not autoReloadWarned then
			autoReloadWarned = true
			CW.Warn("Auto Reload requires VirtualInputManager or an executor key input function.")
		end
		return false
	end

	if CW.Settings.AUTO_RELOAD_ENABLED == nil then
		CW.Settings.AUTO_RELOAD_ENABLED = _cfg.AUTO_RELOAD_ENABLED == true
	end

	local RELOAD_EQUIP_SETTLE = 0.15 -- longest wait to trust a 0 that was found by looking right after equipping
	local RELOAD_RETRY_DELAY = 0.1   -- seconds to wait for the game to start the reload we asked for
	local RELOAD_MAX_TRIES = 3       -- requests for one empty gun before backing off
	local RELOAD_BACKOFF = 2         -- seconds without requests after that

	-- True when the gun is empty, not already reloading, and the game would accept a reload
	-- (the sniper cannot reload without stored ammo).
	local function needsReload(tool)
		if not CW.Settings.AUTO_RELOAD_ENABLED then return false end
		if tool:GetAttribute("Local_CurrentAmmo") ~= 0 then return false end
		if tool:GetAttribute("Local_ReloadSession") ~= 0 then return false end
		if tool:GetAttribute("Behavior") == "Sniper" and (tool:GetAttribute("StoredAmmo") or 0) <= 0 then return false end
		return true
	end

	local function reloadStarted(tool)
		local session = tool:GetAttribute("Local_ReloadSession")
		return session ~= nil and session ~= 0
	end

	-- Elements of the game's gun HUD, found when first needed.
	local hudCache = {}
	local function gunHud(name)
		local cached = hudCache[name]
		if cached and cached.Parent then return cached end
		local node = LocalPlayer:FindFirstChild("PlayerGui")
		for _, step in ipairs({ "Home", "hud", "BottomRightFrame", "GunFrame", name }) do
			node = node and node:FindFirstChild(step)
		end
		hudCache[name] = node
		return node
	end

	-- The count after a quick re-equip. The equip handler copies the server's CurrentAmmo into
	-- Local_CurrentAmmo and the label, so a shot the server has not answered yet when the gun is taken out
	-- again counts twice: the label shows a bullet more, and a last bullet shows 1/6, so the gun never reloads.
	-- The server's count comes a moment later and the game does not read it again: while the gun is in hand
	-- and no reload has begun since it was taken out, a server count below the gun's own is taken, label
	-- included. Always on: it only corrects what the game shows.
	local function syncAmmo(tool)
		local character = LocalPlayer.Character
		if not (character and tool.Parent == character) or tool:GetAttribute("Local_ReloadSession") ~= 0 then return end
		local server, own = tool:GetAttribute("CurrentAmmo"), tool:GetAttribute("Local_CurrentAmmo")
		if type(server) ~= "number" or type(own) ~= "number" or server >= own then return end
		tool:SetAttribute("Local_CurrentAmmo", server)
		local label = gunHud("BulletsLabel")
		if label then
			label.Text = tool:GetAttribute("Behavior") == "Sniper"
				and server .. " | " .. tostring(tool:GetAttribute("StoredAmmo") or 0)
				or server .. "/" .. tostring(tool:GetAttribute("MaxAmmo") or "")
		end
	end

	local function watchGunAmmo(tool)
		if not (tool:IsA("Tool") and tool:GetAttribute("ToolType") == "Gun") then return end
		-- A reload (one still counting down from before counts too) refills the gun after its own count
		-- was sent: a server count that arrives after it may be from before it.
		local reloaded = tool:GetAttribute("Local_ReloadSession") ~= 0
		CW.track("ammoSyncReload", tool:GetAttributeChangedSignal("Local_ReloadSession"):Connect(function()
			if tool:GetAttribute("Local_ReloadSession") ~= 0 then reloaded = true end
		end))
		CW.track("ammoSyncServer", tool:GetAttributeChangedSignal("CurrentAmmo"):Connect(function()
			if not reloaded then syncAmmo(tool) end
		end))
	end

	local function watchCharacterAmmo(character)
		CW.track("ammoSyncEquip", character.ChildAdded:Connect(watchGunAmmo))
		local held = character:FindFirstChildOfClass("Tool")
		if held then watchGunAmmo(held) end
	end
	if LocalPlayer.Character then watchCharacterAmmo(LocalPlayer.Character) end
	CW.track("ammoSyncCharacter", LocalPlayer.CharacterAdded:Connect(watchCharacterAmmo))

	-- Runs the handlers connected to a signal of the game, each in its own thread (a handler such as
	-- reload() waits for the cooldown, so it must not run in ours).
	local function fireGameSignal(signal)
		if X.firesignal then
			X.firesignal(signal)
			return
		end
		local fired = false
		for _, entry in ipairs(connectionsOf(signal)) do
			local connection = entry.raw
			if entry.canFire then
				Exec.spawn("connection:Fire", function() connection:Fire() end)
				fired = true
			elseif type(entry.fn) == "function" then
				task.spawn(entry.fn)
				fired = true
			end
		end
		if fired then return end
		error("neither firesignal nor getconnections can run the game's reload button")
	end

	-- CW.Caps.signals is false when the executor has neither firesignal nor getconnections (reported once at
	-- startup); the R key is used then.
	local directReloadEnabled = CW.Caps.signals == true
	local directFailures = 0
	local directError

	-- Asks the game to reload this gun. Fastest first: the game's own reload button, which runs reload()
	-- right here; the R key when that is unavailable or has stopped working. Returns false when nothing
	-- could be sent (chat has focus, or the player is holding R), so the attempt is not counted.
	local function triggerReload(tool)
		if directReloadEnabled then
			local button = gunHud("TouchReloadButton")
			if button then
				local ok, err = pcall(fireGameSignal, button.MouseButton1Down)
				if ok then
					-- reload() sets Local_ReloadSession before its first yield, so a working executor
					-- shows it at once. Allow a couple of frames for one that runs the handlers later.
					local waited = 0
					while not reloadStarted(tool) and waited < 2 do
						RunService.Heartbeat:Wait()
						waited += 1
					end
					if reloadStarted(tool) then
						directFailures = 0
						return true
					end
					-- Put away (or dead) before the game could start it: not the button's fault.
					local character = LocalPlayer.Character
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if tool.Parent ~= character or not humanoid or humanoid.Health <= 0 then return false end
				else
					directError = tostring(err)
				end

				directFailures += 1
				if not ok or directFailures >= 4 then
					directReloadEnabled = false
					CW.Warn("Auto Reload: instant reload is off (" .. tostring(directError or "no effect four times in a row")
						.. "); using the R key instead.")
				end
			end
		end

		-- The key goes through the chat if it has focus, and does nothing while R is already down.
		if UserInputService:GetFocusedTextBox() or UserInputService:IsKeyDown(Enum.KeyCode.R) then return false end
		pressReloadKey()
		return true
	end

	-- A 0 found by looking at a gun that was just equipped is trusted once its count matches the server's
	-- (the game copied it at equip) or once the settle time has passed.
	local function gunReady(tool, seenAt, now)
		if now - seenAt >= RELOAD_EQUIP_SETTLE then return true end
		return tool:GetAttribute("Local_CurrentAmmo") == tool:GetAttribute("CurrentAmmo")
	end

	local reloadWatch = {
		character = nil, tool = nil, seenAt = 0, pressedAt = -math.huge, tries = 0, holdUntil = 0,
		labelFixed = false, busy = false, fresh = false,
	}
	local safeStep -- forward: the events below queue it

	local function autoReloadStep()
		local watch = reloadWatch
		local character = LocalPlayer.Character
		if character ~= watch.character then
			watch.character = character
			if character then
				-- Check in the same frame a gun is equipped (after the game's own equip handler).
				CW.track("autoReloadAdded", character.ChildAdded:Connect(function() task.defer(safeStep) end))
			else
				CW.untrack("autoReloadAdded")
			end
		end

		local tool = character and character:FindFirstChildWhichIsA("Tool")
		if tool and tool:GetAttribute("ToolType") ~= "Gun" then tool = nil end

		local now = os.clock()
		if tool ~= watch.tool then
			-- A gun was equipped, unequipped or swapped: start from scratch for it.
			watch.tool, watch.seenAt = tool, now
			watch.pressedAt, watch.tries, watch.holdUntil, watch.labelFixed, watch.fresh = -math.huge, 0, 0, false, false
			if tool then
				-- Check in the same frame the last bullet is fired. The change to 0 comes after the game's
				-- equip handler (which only ever writes the real count), so it needs no settle time.
				CW.track("autoReloadAmmo", tool:GetAttributeChangedSignal("Local_CurrentAmmo"):Connect(function()
					local empty = tool:GetAttribute("Local_CurrentAmmo") == 0
					reloadWatch.fresh = empty
					if empty then task.defer(safeStep) end
				end))
			else
				CW.untrack("autoReloadAmmo")
			end
		end
		if not tool or watch.busy then return end

		if reloadStarted(tool) then
			-- A reload is counting down, maybe one that began before this gun was equipped again. The game's
			-- equip handler wrote the server's ammo into the label, which says "loaded" while the gun still
			-- cannot fire; put its own "..." back until the reload ends (it writes the final count then).
			watch.tries = 0
			if not watch.labelFixed then
				watch.labelFixed = true
				local label = gunHud("BulletsLabel")
				if label then
					pcall(function()
						if label.Text ~= "..." then label.Text = "..." end
					end)
				end
			end
			return
		end

		if not needsReload(tool) then
			watch.tries = 0
			return
		end
		if not (watch.fresh or gunReady(tool, watch.seenAt, now)) then return end
		if now < watch.holdUntil or now - watch.pressedAt < RELOAD_RETRY_DELAY then return end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return end

		if watch.tries >= RELOAD_MAX_TRIES then
			watch.tries = 0
			watch.holdUntil = now + RELOAD_BACKOFF
			return
		end

		watch.tries += 1
		watch.pressedAt = now
		watch.busy = true
		task.spawn(function()
			local ok, result = pcall(triggerReload, tool)
			watch.busy = false
			if not ok then
				if not autoReloadWarned then
					autoReloadWarned = true
					CW.Warn("Auto Reload request failed: " .. tostring(result))
				end
			elseif result == false then
				watch.tries = math.max(0, watch.tries - 1) -- nothing was sent: try again without using up a try
			end
		end)
	end

	local autoReloadStepWarned = false
	safeStep = function()
		local ok, err = pcall(autoReloadStep)
		if not ok and not autoReloadStepWarned then
			autoReloadStepWarned = true
			CW.Warn("Auto Reload step failed: " .. tostring(err))
		end
	end

	local function setAutoReload(enabled)
		-- Connections of the previous implementations, in case an older build is still loaded.
		for _, key in ipairs({ "autoReloadRemoved", "autoReloadTool" }) do
			CW.untrack(key)
		end

		if enabled then
			local watch = reloadWatch
			watch.character, watch.tool, watch.tries, watch.holdUntil, watch.busy, watch.fresh = nil, nil, 0, 0, false, false
			CW.track("autoReloadCharacter", LocalPlayer.CharacterAdded:Connect(function() task.defer(safeStep) end))
			CW.track("autoReloadStep", RunService.Heartbeat:Connect(safeStep))
			safeStep() -- an empty gun that is already in hand
		else
			for _, key in ipairs({ "autoReloadStep", "autoReloadCharacter", "autoReloadAdded", "autoReloadAmmo" }) do
				CW.untrack(key)
			end
		end
	end

	UtilityTab:Toggle({
		Title = "Auto Reload at 0 Ammo",
		Default = CW.Settings.AUTO_RELOAD_ENABLED == true,
		Callback = function(enabled)
			CW.Settings.AUTO_RELOAD_ENABLED = enabled == true
			setAutoReload(CW.Settings.AUTO_RELOAD_ENABLED)
		end,
	})

	setAutoReload(CW.Settings.AUTO_RELOAD_ENABLED == true)
	-- <<< AUTO RELOAD END

	-- >>> AUTO SLOT BEGIN
	-- Auto Slot: every tool can be given a slot of the inventory bar (1-9 and 0), or be hidden from the
	-- inventory. There are two layouts: one for the police (Guards) and one for everybody else (Criminals,
	-- Inmates, Neutral); the one of the player's current team is used, and switches when the team changes.
	--
	-- The game's inventory (ReplicatedStorage.Scripts.BackpackClient, read from the decompiled place):
	--   * the bar is ONE list (t1) of { Tool, Button, Slot } with no gaps and at most 10 entries: the slot of a
	--     tool is its position in that list. updateToolbar() re-reads the list and moves the buttons.
	--   * onToolAdded (connected to Backpack.ChildAdded) appends a new tool; a tool whose parent leaves the
	--     Backpack/character is removed (AncestryChanged).
	--   The list and updateToolbar are reached through the upvalues of onToolAdded (getconnections +
	--   debug.getupvalue), each one recognised by what it captures:
	--     t1            the only table onToolAdded captures (besides the player)
	--     updateToolbar captures t1 and no function, no Color3 and no player
	--     equipTool     captures t1, the player and the two button Color3s
	--     Toolbar       the frame of the buttons (the button template it also captures has no parent)
	--   The game also fills its bar when the character spawns (onCharacterAdded, for the tools already in the
	--   Backpack) without any Backpack event, so the bar is laid out again after every button the game adds or
	--   removes (Toolbar.ChildAdded / ChildRemoved), whatever made it.
	--   The bar has no gaps: a tool goes to its slot when the bar is that long; a tool whose slot is past the
	--   end goes last, as near its slot as the bar allows; the other tools keep their order in the places left.
	--   With several tools in one slot the first one the player has wins.
	--
	-- Roblox's own backpack ("Use Old Backpack") is a CoreScript: its connections come from a foreign Luau
	-- state, and reading their upvalues crashed the game on some executors, so its internals are never
	-- touched. Its public behaviour is used instead: a tool that leaves the Backpack and the character frees
	-- its slot, and a tool that arrives takes the lowest empty slot. This script follows every arrival and
	-- departure the same way (its handlers are deferred like Roblox's, in the same order), so it knows where
	-- each tool is. To reorder, the tools are taken out of the Backpack locally (nothing replicates: the
	-- server still has them there), one frame is waited so that backpack frees the slots, and they are put
	-- back slot by slot; a slot that must stay empty is held meanwhile by a local placeholder tool. Unlike
	-- the game's own bar, Roblox's allows empty slots, so there each tool goes exactly to its slot. On every
	-- spawn Roblox's backpack clears its bar and fills it again in the Backpack's order, with no event for it,
	-- so after CharacterAdded the layout is done again from scratch. A tool that arrives while the tools are
	-- being put back is laid out by one more pass right after. Only the game's BackpackClient listens to the
	-- Backpack; the tool controllers (guns, shield, C4, snacks) listen to the character only.
	--
	-- Hiding: a hidden tool is taken out of the Backpack locally (parent nil), so neither bar shows it and
	-- it can't be equipped. The server still has it. It comes back when it is un-hidden, when Auto Slot is
	-- turned off, or when the server moves it. Kept in CW.State so a re-run can put the tools back.
	local PlayerSettings = ReplicatedStorage:FindFirstChild("PlayerSettings")
	local SLOT_COUNT = 10
	local autoSlotCaps = CW.Caps.upvalues == true

	-- True only for a Lua closure. C functions have no Luau upvalues, and asking for them can crash
	-- some executors.
	local function isLuaClosure(fn)
		if type(fn) ~= "function" then return false end
		if X.islclosure then
			local ok, result = pcall(X.islclosure, fn)
			return ok and result == true
		end
		if X.iscclosure then
			local ok, result = pcall(X.iscclosure, fn)
			return ok and result == false
		end
		local ok, source = pcall(function() return debug.info(fn, "s") end)
		return ok and source ~= "[C]"
	end

	local function upvaluesOf(fn)
		if not isLuaClosure(fn) then return {} end
		if X.getupvalues then
			local ok, values = pcall(X.getupvalues, fn)
			if ok and type(values) == "table" then return values end
		end
		-- One by one only when the executor tells how many there are: reading past the last one is not
		-- safe everywhere.
		local values = {}
		if X.getupvalue and X.getinfo then
			local okInfo, info = pcall(X.getinfo, fn)
			local count = okInfo and type(info) == "table" and tonumber(info.nups) or 0
			for i = 1, math.min(count, 64) do
				local ok, v = pcall(X.getupvalue, fn, i)
				if not ok then break end
				values[i] = v
			end
		end
		return values
	end

	local function usingOldBackpack()
		return PlayerSettings ~= nil and PlayerSettings:GetAttribute("UseOldBackpack") == true
	end

	-- A list entry made by the game's onToolAdded.
	local function isEntry(entry)
		return type(entry) == "table" and typeof(entry.Tool) == "Instance" and typeof(entry.Button) == "Instance"
	end

	local internals -- { list, update, equip }
	local barGuarded = false -- the game's updateToolbar closes its own gaps (guardBar, below)
	local function findInternals()
		if internals then
			local list = internals.list
			if #list == 0 or isEntry(list[1]) then return internals end
			internals = nil
		end
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not backpack then return nil end
		for _, connection in ipairs(connectionsOf(backpack.ChildAdded)) do
			local fn = connection.fn
			if isLuaClosure(fn) then
				local list, hasPlayer, functions, toolbar = nil, false, {}, nil
				for _, v in pairs(upvaluesOf(fn)) do
					if v == LocalPlayer then
						hasPlayer = true
					elseif type(v) == "table" then
						list = list == nil and v or false -- more than one table: not the game's onToolAdded
					elseif type(v) == "function" then
						-- (after a re-run the game's updateToolbar is behind the guard put in front of it, below)
						local guard = CW.State.barGuard
						table.insert(functions, (guard and v == guard.fn) and guard.update or v)
					elseif typeof(v) == "Instance" and v:IsA("GuiObject") and v.Parent ~= nil then
						toolbar = v
					end
				end
				if hasPlayer and type(list) == "table" and (#list == 0 or isEntry(list[1])) then
					local update, equip
					for _, f in ipairs(functions) do
						local hasList, hasColor, hasFunction, hasPlayerToo = false, false, false, false
						for _, v in pairs(upvaluesOf(f)) do
							if v == list then hasList = true
							elseif typeof(v) == "Color3" then hasColor = true
							elseif type(v) == "function" then hasFunction = true
							elseif v == LocalPlayer then hasPlayerToo = true end
						end
						if hasList and hasColor and hasPlayerToo then
							equip = f
						elseif hasList and not hasColor and not hasFunction and not hasPlayerToo then
							update = update or f
						end
					end
					if update and equip then
						-- fn = onToolAdded; toolbar = nil if the game changes how it keeps it (no bar events then)
						internals = { list = list, update = update, equip = equip, add = fn, toolbar = toolbar }
						return internals
					end
				end
			end
		end
		return nil
	end

	--// Layouts per team ----------------------------------------------------------------------------------
	-- "Police" = Guards; "Prisoner" = Criminals, Inmates and Neutral. The tools a team can't have are left
	-- out of its board: Handcuffs and Taser are guard equipment, and the Riot Shield comes from the guards'
	-- "Riot Police" gamepass. A guard who picks up a key card disposes of it (it never reaches the inventory), and
	-- the hammer and the crude knife are inmate weapons.
	local VARIANTS = {
		{ key = "PRISONER", label = "Criminal / Inmate", excluded = { Handcuffs = true, Taser = true, ["Riot Shield"] = true } },
		{ key = "POLICE", label = "Police", excluded = { ["Key card"] = true, Hammer = true, ["Crude Knife"] = true } },
	}
	local VARIANT_BY_KEY = {}
	for _, variant in ipairs(VARIANTS) do VARIANT_BY_KEY[variant.key] = variant end

	local function currentVariantKey()
		local team = LocalPlayer.Team
		return (team and team.Name == "Guards") and "POLICE" or "PRISONER"
	end

	-- Saved as AUTO_SLOT_LAYOUT_<KEY> = { S1 = "AK-47|M4A1", ..., H = "Key card|Soda" } (H = hidden).
	local HIDDEN_KEY = "hidden"
	local function readLayout(variantKey)
		local layout = {}
		local saved = CW.Settings["AUTO_SLOT_LAYOUT_" .. variantKey]
		local excluded = VARIANT_BY_KEY[variantKey].excluded
		local function parse(text)
			local names = {}
			if type(text) == "string" then
				for name in text:gmatch("[^|]+") do
					if not excluded[name] then table.insert(names, name) end
				end
			end
			return #names > 0 and names or nil
		end
		if type(saved) == "table" then
			for slot = 1, SLOT_COUNT do layout[slot] = parse(saved["S" .. slot]) end
			layout[HIDDEN_KEY] = parse(saved.H)
		end
		return layout
	end
	local function saveLayout(variantKey, layout)
		local saved = {}
		for slot, names in pairs(layout) do
			if #names > 0 then
				if slot == HIDDEN_KEY then
					saved.H = table.concat(names, "|")
				elseif type(slot) == "number" and slot >= 1 and slot <= SLOT_COUNT then
					saved["S" .. slot] = table.concat(names, "|")
				end
			end
		end
		CW.Settings["AUTO_SLOT_LAYOUT_" .. variantKey] = saved
	end

	-- The single layout of an older build becomes the starting layout of both teams (once).
	if type(CW.Settings.AUTO_SLOT_LAYOUT) == "table" then
		for _, variant in ipairs(VARIANTS) do
			local name = "AUTO_SLOT_LAYOUT_" .. variant.key
			if type(CW.Settings[name]) ~= "table" then CW.Settings[name] = table.clone(CW.Settings.AUTO_SLOT_LAYOUT) end
		end
		CW.Settings.AUTO_SLOT_LAYOUT = nil
	end
	-- An older build had keys 9 and 0 equip slots 9 and 0: a re-run removes that connection.
	CW.untrack("autoSlotKeys")
	CW.Settings.AUTO_SLOT_KEYS = nil

	local layouts = {}
	for _, variant in ipairs(VARIANTS) do layouts[variant.key] = readLayout(variant.key) end
	local layout = layouts[currentVariantKey()] -- the layout arrangeList uses
	local queueArrange -- set once arrange exists (below)

	-- Lays the game's bar out (see the top). Returns true when the bar changed.
	local function arrangeList(list)
		local count = #list
		local placed, inSlot, late = {}, {}, {}
		for slot = 1, SLOT_COUNT do
			for _, name in ipairs(layout[slot] or {}) do
				local found
				for _, entry in ipairs(list) do
					-- (a tool that was just hidden is still in the game's list until its own event runs)
					if not placed[entry] and isEntry(entry) and entry.Tool.Name == name and entry.Tool.Parent ~= nil then
						found = entry
						break
					end
				end
				if found then
					placed[found] = true
					if slot <= count then inSlot[slot] = found else table.insert(late, found) end
					break
				end
			end
		end
		local rest = {}
		for _, entry in ipairs(list) do
			if not placed[entry] then table.insert(rest, entry) end
		end
		for _, entry in ipairs(late) do table.insert(rest, entry) end
		local order, changed = {}, false
		for i = 1, count do
			order[i] = inSlot[i] or table.remove(rest, 1)
			if order[i] ~= list[i] then changed = true end
		end
		if changed then
			for i = 1, count do list[i] = order[i] end
		end
		return changed
	end
	CW.AutoSlotArrangeList = arrangeList -- used by the tests

	--// Hiding -----------------------------------------------------------------------------------------
	-- "Hidden" = out of the quick slots (1-9, 0), but still the player's:
	--   * Roblox's backpack: in its inventory area past the hotbar (open it with the backpack key).
	--   * the game's bar: it has nothing past its 10 slots, so the tool stays in the Backpack, without a button.
	-- Older builds took hidden tools out of the Backpack (parent nil): those are put back once, here.
	CW.State.autoSlotHidden = CW.State.autoSlotHidden or {}
	for tool, backpack in pairs(CW.State.autoSlotHidden) do
		CW.State.autoSlotHidden[tool] = nil
		if tool.Parent == nil and backpack.Parent == LocalPlayer then
			pcall(function() tool.Parent = backpack end)
		end
	end

	local function isHiddenName(name)
		if not CW.Settings.AUTO_SLOT_ENABLED then return false end
		for _, hiddenName in ipairs(layout[HIDDEN_KEY] or {}) do
			if hiddenName == name then return true end
		end
		return false
	end

	--// Roblox's own backpack (Use Old Backpack) ----------------------------------------------------------
	-- Where each tool is in Roblox's backpack, as it decided it: [1..10] = tool or false; oldInventory holds
	-- the tools this script sent to its inventory area (strong keys: emptied on every layout and every spawn).
	local oldSlots = {}
	local oldInventory = {}
	local oldKnown = false   -- false until this script has laid the bar out itself (after a spawn or a start)
	local rebuildingOld = false
	local arrangeAfterRebuild = false -- asked for while the tools were being put back

	local function oldIndex(tool)
		for i = 1, SLOT_COUNT do
			if oldSlots[i] == tool then return i end
		end
		return nil
	end
	-- The order the tools came in (this Backpack): the tools without a slot keep it, as Roblox's backpack does.
	local arrival, arrivals = {}, 0
	local function noteArrival(tool)
		if not arrival[tool] then
			arrivals += 1
			arrival[tool] = arrivals
		end
	end
	local function oldArrived(tool)
		-- (during a layout: placeholders and tools being put back; a new tool is noted by the next pass)
		if rebuildingOld then return end
		noteArrival(tool)
		-- Equipping or unequipping keeps the slot (or the inventory place) the tool already has.
		if oldIndex(tool) or oldInventory[tool] then return end
		for i = 1, SLOT_COUNT do
			if not oldSlots[i] then
				oldSlots[i] = tool
				return
			end
		end
		oldInventory[tool] = true -- a full hotbar sends it to the inventory area
	end
	local function oldLeft(tool, backpack)
		if rebuildingOld then return end
		local parent = tool.Parent
		if parent ~= backpack and parent ~= LocalPlayer.Character then
			local i = oldIndex(tool)
			if i then oldSlots[i] = false end
			oldInventory[tool] = nil
			arrival[tool] = nil
		end
	end

	-- Where every tool should be: desired[1..10] = tool or false, and the tools for the inventory area
	-- (hidden ones, and the ones past slot 10). A tool with a slot in the layout goes exactly there (Roblox's
	-- backpack allows empty slots); every other tool keeps its slot when that one is still free, else takes
	-- the lowest free one (tools = in the order they came in). fixed = { tool, slot } is a tool in hand that
	-- stays where it is.
	local function planOldSlots(current, tools, fixed)
		local desired, used, inventory = {}, {}, {}
		for slot = 1, SLOT_COUNT do desired[slot] = false end
		if fixed then
			desired[fixed.slot] = fixed.tool
			used[fixed.tool] = true
		end
		for _, tool in ipairs(tools) do
			if not used[tool] and isHiddenName(tool.Name) then
				table.insert(inventory, tool)
				used[tool] = true
			end
		end
		for slot = 1, SLOT_COUNT do
			local names = layout[slot]
			if names and not desired[slot] then
				for _, name in ipairs(names) do
					for _, tool in ipairs(tools) do
						if not used[tool] and tool.Name == name then
							desired[slot] = tool
							used[tool] = true
							break
						end
					end
					if desired[slot] then break end
				end
			end
		end
		local rest = {}
		for slot = 1, SLOT_COUNT do
			local tool = current[slot]
			if tool and not used[tool] and table.find(tools, tool) then
				if not desired[slot] then
					desired[slot] = tool
				else
					table.insert(rest, tool)
				end
				used[tool] = true
			end
		end
		for _, tool in ipairs(tools) do
			if not used[tool] then table.insert(rest, tool) end
		end
		for _, tool in ipairs(rest) do
			local placed = false
			for slot = 1, SLOT_COUNT do
				if not desired[slot] then
					desired[slot] = tool
					placed = true
					break
				end
			end
			if not placed then table.insert(inventory, tool) end
		end
		return desired, inventory
	end
	CW.AutoSlotPlanOld = planOldSlots -- used by the tests

	-- Takes the tools out and puts them back so that each lands in its planned place. Roblox's backpack fills
	-- the lowest empty hotbar slot, and the inventory area once the hotbar is full; so a slot that must stay
	-- empty is held for that moment by a local placeholder tool (never replicated), removed right after.
	-- fixedTool (a tool in hand) keeps its slot and is not touched. Yields for three frames.
	-- The game's own bar, hidden meanwhile, follows the Backpack too: a primary or secondary gun that comes back
	-- within a second gets the slot the last one left, past the end of its list here, and its updateToolbar
	-- fails. Unless that bar is guarded (guardBar), the guns go out and come back without their SlotType (a
	-- local change, undone right after), so that bar just appends them.
	local function rebuildOldBackpack(backpack, desired, inventory, fixedTool)
		rebuildingOld = true
		-- Only tools still in the Backpack are taken out, and only those are put back: one the server moves or
		-- removes meanwhile is left where the server put it, and its slot is held by a placeholder instead.
		local taken, slotTypes = {}, {}
		local function takeOut(tool)
			if tool ~= fixedTool and tool.Parent == backpack then
				local slotType = not barGuarded and tool:GetAttribute("SlotType")
				if slotType then
					slotTypes[tool] = slotType
					tool:SetAttribute("SlotType", nil)
				end
				if pcall(function() tool.Parent = nil end) then taken[tool] = true end
			end
		end
		local function putBack(tool)
			return taken[tool] == true and tool.Parent == nil and backpack.Parent == LocalPlayer
				and pcall(function() tool.Parent = backpack end)
		end
		for slot = 1, SLOT_COUNT do
			if desired[slot] then takeOut(desired[slot]) end
		end
		for _, tool in ipairs(inventory) do takeOut(tool) end
		task.wait() -- Roblox's backpack frees their slots now

		local last = 0
		for slot = 1, SLOT_COUNT do
			if desired[slot] then last = slot end
		end
		if #inventory > 0 then last = SLOT_COUNT end -- the whole hotbar is held, so the rest go past it
		local placeholders = {}
		table.clear(oldSlots)
		table.clear(oldInventory)
		for slot = 1, SLOT_COUNT do oldSlots[slot] = false end
		for slot = 1, last do
			local tool = desired[slot]
			if tool and tool == fixedTool then
				oldSlots[slot] = tool -- in hand: its slot is taken already
			elseif tool and putBack(tool) then
				oldSlots[slot] = tool
			else
				local placeholder = Instance.new("Tool")
				placeholder.Name = " "
				placeholder.RequiresHandle = false
				placeholder.CanBeDropped = false
				placeholder.Parent = backpack
				table.insert(placeholders, placeholder)
			end
		end
		for _, tool in ipairs(inventory) do
			if putBack(tool) then oldInventory[tool] = true end
		end
		task.wait() -- every tool now has its place
		for tool, slotType in pairs(slotTypes) do
			pcall(function()
				if tool:GetAttribute("SlotType") == nil then tool:SetAttribute("SlotType", slotType) end
			end)
		end
		for _, placeholder in ipairs(placeholders) do placeholder:Destroy() end
		task.wait() -- the placeholders' slots are empty again; these events are not taken as real tools
		oldKnown = true
		rebuildingOld = false
		if arrangeAfterRebuild then
			arrangeAfterRebuild = false
			queueArrange()
		end
	end

	local function sameOldLayout(current, desired, inventory)
		for slot = 1, SLOT_COUNT do
			if (desired[slot] or false) ~= (current[slot] or false) then return false end
		end
		for _, tool in ipairs(inventory) do
			if not oldInventory[tool] then return false end
		end
		return true
	end

	local function arrangeOldBackpack(backpack)
		if rebuildingOld then
			arrangeAfterRebuild = true
			return
		end
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local held = character and character:FindFirstChildOfClass("Tool")

		local tools = {}
		for _, child in ipairs(backpack:GetChildren()) do
			if child:IsA("Tool") then table.insert(tools, child) end
		end
		if held then table.insert(tools, held) end
		if #tools == 0 then return end
		for _, tool in ipairs(tools) do noteArrival(tool) end
		table.sort(tools, function(a, b) return arrival[a] < arrival[b] end)

		-- Where the tools are now. Before this script has laid the bar out (after a spawn or a start), Roblox
		-- filled it in the Backpack's order. When that is not known for sure, the layout is planned from scratch:
		-- the tools without a slot then take the lowest free slots, in the order they came in.
		local current = {}
		local known = oldKnown
		if known then
			for slot = 1, SLOT_COUNT do
				local tool = oldSlots[slot]
				current[slot] = (tool and (tool.Parent == backpack or tool == held)) and tool or false
			end
			for _, tool in ipairs(tools) do
				if not table.find(current, tool) and not oldInventory[tool] then known = false end -- arrived unseen
			end
		end
		if not known then
			for slot = 1, SLOT_COUNT do current[slot] = tools[slot] or false end
		end

		local heldSlot = held and table.find(current, held)
		-- A hidden tool in hand stays where it is until it is put away.
		local fixed = (held and heldSlot and isHiddenName(held.Name)) and { tool = held, slot = heldSlot } or nil
		local desired, inventory = planOldSlots(known and current or {}, tools, fixed)
		if known and sameOldLayout(current, desired, inventory) then return end

		if held and not fixed then
			if heldSlot and known and desired[heldSlot] == held then
				-- The tool in hand is already in its slot: the others are laid out around it.
				rebuildOldBackpack(backpack, desired, inventory, held)
				return
			end
			-- The tool in hand has to move: it is put away, the bar is laid out, and it is equipped again at once
			-- (what pressing its slot key twice does; both replicate like the game's own equipTool).
			if not humanoid then return end
			rebuildingOld = true -- from here on: another pass now would lay the bar out twice at once
			pcall(function() humanoid:UnequipTools() end)
			task.wait()
			rebuildOldBackpack(backpack, desired, inventory, nil)
			if held.Parent == backpack then pcall(function() humanoid:EquipTool(held) end) end
			return
		end
		rebuildOldBackpack(backpack, desired, inventory, fixed and fixed.tool or nil)
	end

	--// Arranging ------------------------------------------------------------------------------------------
	-- The character only while it is alive: after a death LocalPlayer.Character still points at the dead one
	-- (with the gun that was in hand) until the respawn.
	local function aliveCharacter()
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if character and character.Parent and humanoid and humanoid.Health > 0 then return character end
		return nil
	end

	-- The game's list must have no gaps: updateToolbar walks t1[1..#t1] and indexes .Button. onToolAdded puts a
	-- returning primary/secondary gun at the slot the previous one left (table.insert(t1, v6, entry)); when the
	-- list got shorter meanwhile (a team switch, a respawn) that slot is past the end, Luau's table.insert leaves
	-- a gap there, and updateToolbar fails ("attempt to index nil with 'Button'") with the buttons left stacked.
	-- This closes any gap, whatever made it. Returns true when it changed the list.
	local function closeGaps(list)
		local highest, count = 0, 0
		for key, value in pairs(list) do
			if type(key) == "number" and value ~= nil then
				count += 1
				if key > highest then highest = key end
			end
		end
		if highest == count then return false end
		local entries = {}
		for i = 1, highest do
			if list[i] ~= nil then table.insert(entries, list[i]) end
		end
		table.clear(list) -- the game's own table: same identity, filled again in order
		for i, entry in ipairs(entries) do list[i] = entry end
		return true
	end

	-- closeGaps runs after the game's handlers, but updateToolbar fails INSIDE them: onToolAdded and
	-- onToolRemoved stop there, the error shows in the console, and onToolRemoved leaves the tool's button on
	-- the bar. Laying out Roblox's backpack (below) takes the tools out and puts them back at once, and the
	-- game's bar, hidden meanwhile, follows all of it: a returning gun gets the slot the previous one left,
	-- past the end. Where the executor can write upvalues, the game's functions that call updateToolbar
	-- (onToolAdded, onToolRemoved, createDragger) get one that closes the gaps first. Kept in CW.State: a
	-- re-run finds the game's function behind it (findInternals).
	local function guardBar(found)
		local getUpvalue, setUpvalue = X.getupvalue, X.setupvalue
		if not (getUpvalue and setUpvalue) then return false end
		local guard = CW.State.barGuard
		if not (guard and guard.list == found.list and guard.update == found.update) then
			local list, update = found.list, found.update
			guard = { list = list, update = update }
			guard.fn = function(...)
				closeGaps(list)
				return update(...)
			end
			CW.State.barGuard = guard
		end
		if guard.installed then return (guard.patched or 0) > 0 end
		local callers = { found.add }
		for _, value in pairs(upvaluesOf(found.add)) do
			if type(value) == "function" and value ~= guard.update and value ~= guard.fn then table.insert(callers, value) end
		end
		local patched = 0
		for _, fn in ipairs(callers) do
			for index, value in pairs(upvaluesOf(fn)) do
				-- (the index is read back first: some executors' getupvalues skip the nil upvalues)
				if value == guard.update and type(index) == "number" then
					local ok, current = pcall(getUpvalue, fn, index)
					if ok and current == guard.update and pcall(setUpvalue, fn, index, guard.fn) then
						patched += 1
					end
				end
			end
		end
		guard.installed, guard.patched = true, patched
		CW.Log("Auto Slot: the game's inventory bar closes its own gaps (" .. patched .. " functions)")
		return patched > 0
	end

	-- The gaps closed, and the buttons left on the game's bar without an entry (an onToolRemoved that
	-- stopped at updateToolbar). Returns true when it changed something.
	local function repairBar(found)
		local changed = closeGaps(found.list)
		local toolbar = found.toolbar
		if toolbar and toolbar.Parent then
			local onBar = {}
			for _, entry in ipairs(found.list) do
				if isEntry(entry) then onBar[entry.Button] = true end
			end
			for _, child in ipairs(toolbar:GetChildren()) do
				if child:IsA("TextButton") and not onBar[child] then
					child:Destroy()
					changed = true
				end
			end
		end
		return changed
	end

	-- The game's bar: a hidden tool loses its button (it stays in the Backpack); when it is un-hidden, or Auto
	-- Slot is turned off, it gets the button back through the game's own onToolAdded. ONLY those tools: giving
	-- buttons to new tools is the game's job, and doing it for it raced with its own state (during a team
	-- switch the new primary went to the old primary's slot, past the end of the list).
	-- A button whose tool is neither in the Backpack nor in a living character's hand (a leftover) is taken
	-- off, but only 1.5 s later: the game removes its own buttons and, for a primary/secondary gun, remembers
	-- that slot for the next one (onToolRemoved). Returns true when the bar's list changed.
	local LEFTOVER_GRACE = 1.5
	local leftoverSince = setmetatable({}, { __mode = "k" })
	-- Tools whose button this script took off. Strong keys (a Roblox object's Lua handle can be collected while
	-- the object lives on); each one is dropped below once the tool is gone.
	local removedByUs = {}
	local leftoverCheckQueued = false
	local function syncBar(found, backpack, keepHidden)
		local list = found.list
		local changed = repairBar(found)
		local character = aliveCharacter()
		local now = os.clock()
		local pending = false
		for i = #list, 1, -1 do
			local entry = list[i]
			if isEntry(entry) then
				local parent = entry.Tool.Parent
				local owned = parent == backpack or (character ~= nil and parent == character)
				local hide = keepHidden and parent == backpack and isHiddenName(entry.Tool.Name)
				-- (a dead character's gun is left to the game until the respawn: it removes it itself)
				local leftover = not owned and not (parent ~= nil and parent == LocalPlayer.Character)
				if leftover then
					leftoverSince[entry] = leftoverSince[entry] or now
					if now - leftoverSince[entry] < LEFTOVER_GRACE then
						leftover = false
						pending = true
					end
				else
					leftoverSince[entry] = nil
				end
				if hide or leftover then
					table.remove(list, i)
					pcall(function() entry.Button:Destroy() end)
					if hide then removedByUs[entry.Tool] = true end
					changed = true
				end
			end
		end
		if pending and not leftoverCheckQueued then
			leftoverCheckQueued = true
			task.delay(LEFTOVER_GRACE + 0.1, function()
				leftoverCheckQueued = false
				queueArrange()
			end)
		end

		local onBar = {}
		for _, entry in ipairs(list) do
			if isEntry(entry) then onBar[entry.Tool] = true end
		end
		for tool in pairs(removedByUs) do
			local parent = tool.Parent
			local here = parent == backpack or (character ~= nil and parent == character)
			if not here and parent ~= LocalPlayer.Character then
				removedByUs[tool] = nil -- gone (dropped, removed, a respawn): nothing to give back
			elseif here and not onBar[tool] and #list < SLOT_COUNT and not (keepHidden and isHiddenName(tool.Name)) then
				removedByUs[tool] = nil
				pcall(found.add, tool) -- appends it and redraws the bar
				onBar[tool] = true
				if closeGaps(list) then changed = true end -- (onToolAdded may have put a returning gun past the end)
			end
		end
		return changed
	end

	local warnedMissing = false
	local swapInProgress = function() return false end -- set by the pickup swap below
	local watchedBar -- the game's bar frame whose buttons are watched
	-- A Backpack that comes in before its character (a respawn, a team switch from the menu): until that
	-- character is added, the current one is on its way out with whatever it holds, and nothing is laid out
	-- (2 s at most).
	local awaitingCharacter -- that Backpack
	local characterSince = -math.huge
	local function arrange()
		layout = layouts[currentVariantKey()]
		if not CW.Settings.AUTO_SLOT_ENABLED or swapInProgress() or awaitingCharacter then return end
		-- Only for a living character: when it dies the bar is about to be replaced, and CharacterAdded lays
		-- the new one out.
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or (humanoid and humanoid.Health <= 0) then return end
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if not backpack then return end

		local found = autoSlotCaps and findInternals() or nil
		barGuarded = found ~= nil and guardBar(found)
		if usingOldBackpack() then
			arrangeOldBackpack(backpack) -- needs no executor function
			-- The game's bar (hidden while Roblox's is in use) saw those tools go and come back.
			if found and repairBar(found) then pcall(found.update) end
			return
		end
		if not autoSlotCaps then return end
		if not found then
			if not warnedMissing then
				warnedMissing = true
				CW.Warn("Auto Slot could not find the game's inventory bar (BackpackClient); it will try again on the next tool")
			end
			return
		end
		warnedMissing = false
		if found.toolbar and found.toolbar ~= watchedBar then
			watchedBar = found.toolbar
			CW.track("autoSlotBarAdded", watchedBar.ChildAdded:Connect(queueArrange))
			CW.track("autoSlotBarRemoved", watchedBar.ChildRemoved:Connect(queueArrange))
		end
		local list = found.list
		-- Not while the player is dragging a button in the game's own move mode.
		for _, entry in ipairs(list) do
			local detector = isEntry(entry) and entry.Button:FindFirstChildOfClass("UIDragDetector")
			if detector and detector:GetAttribute("Dragging") then return end
		end
		local barChanged = syncBar(found, backpack, true)
		if arrangeList(list) or barChanged then
			local ok, err = pcall(found.update)
			if not ok then CW.Warn("Auto Slot could not refresh the inventory bar: " .. tostring(err)) end
		end
	end

	-- Runs after the game's own handlers of the same event (they add the tool to the list first).
	local arrangeQueued = false
	queueArrange = function()
		if arrangeQueued then return end
		arrangeQueued = true
		task.defer(function()
			arrangeQueued = false
			arrange()
		end)
	end

	local function watchBackpack(backpack)
		oldKnown = false -- a new Backpack (a spawn): Roblox's backpack fills its bar again
		table.clear(oldSlots)
		table.clear(oldInventory)
		table.clear(arrival)
		CW.track("autoSlotBackpackAdded", backpack.ChildAdded:Connect(function(child)
			if not child:IsA("Tool") then return end
			oldArrived(child)
			queueArrange()
		end))
		CW.track("autoSlotBackpackRemoved", backpack.ChildRemoved:Connect(function(child)
			if not child:IsA("Tool") then return end
			oldLeft(child, backpack)
			queueArrange()
		end))
		queueArrange()
	end
	local function watchCharacter(character)
		-- A spawn: both bars take the tools already in the Backpack in their own CharacterAdded handlers (which
		-- run before this one), so the layout is done again from scratch right after them.
		characterSince = os.clock()
		awaitingCharacter = nil
		oldKnown = false
		queueArrange()
		-- Equipping moves the tool into the character; a tool removed from the hand (a primary replaced by
		-- another one, a dropped gun) leaves from the character.
		CW.track("autoSlotEquip", character.ChildAdded:Connect(function(child)
			if not child:IsA("Tool") then return end
			oldArrived(child)
			queueArrange()
		end))
		CW.track("autoSlotUnequip", character.ChildRemoved:Connect(function(child)
			if not child:IsA("Tool") then return end
			oldLeft(child, LocalPlayer:FindFirstChildOfClass("Backpack"))
			queueArrange()
		end))
	end

	local function stopAutoSlot()
		for _, key in ipairs({ "autoSlotBackpackAdded", "autoSlotBackpackRemoved", "autoSlotEquip", "autoSlotUnequip",
			"autoSlotBackpackWait", "autoSlotCharacter", "autoSlotOldBackpack", "autoSlotTeam", "autoSlotBarAdded",
			"autoSlotBarRemoved" }) do
			CW.untrack(key)
		end
		watchedBar = nil
		awaitingCharacter = nil
		-- Auto Slot off: hidden tools get their button back on the game's bar. (In Roblox's backpack they stay
		-- in its inventory area, where the player can still reach them.)
		if not usingOldBackpack() and autoSlotCaps then
			local found = findInternals()
			local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
			if found and backpack then
				pcall(function()
					syncBar(found, backpack, false)
					found.update()
				end)
			end
		end
	end

	local function setAutoSlot(enabled)
		stopAutoSlot()
		if not enabled then return end
		if not autoSlotCaps then
			CW.Warn("Auto Slot needs getconnections and debug.getupvalue(s) for the game's inventory bar; "
				.. "it works only with \"Use Old Backpack\" on this executor")
		end
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if backpack then watchBackpack(backpack) end
		CW.track("autoSlotBackpackWait", LocalPlayer.ChildAdded:Connect(function(child)
			if not child:IsA("Backpack") then return end
			if os.clock() - characterSince > 1 then -- (one right after CharacterAdded is that character's own)
				awaitingCharacter = child
				task.delay(2, function()
					if awaitingCharacter == child then
						awaitingCharacter = nil
						queueArrange()
					end
				end)
			end
			watchBackpack(child)
		end))
		if LocalPlayer.Character then watchCharacter(LocalPlayer.Character) end
		CW.track("autoSlotCharacter", LocalPlayer.CharacterAdded:Connect(watchCharacter))
		CW.track("autoSlotTeam", LocalPlayer:GetPropertyChangedSignal("Team"):Connect(queueArrange))
		if PlayerSettings then
			CW.track("autoSlotOldBackpack", PlayerSettings:GetAttributeChangedSignal("UseOldBackpack"):Connect(function()
				oldKnown = false -- switching backpacks: lay the new one out from scratch
				queueArrange()
			end))
		end
	end

	--// Riot shield ------------------------------------------------------------------------------------------
	-- The shield goes on the arm when the player clicks while holding it (ShieldController, decompiled):
	-- Remotes.ShieldEquipped:FireServer(); the server then adds RiotShieldPart to the character. With Auto Slot
	-- on, that is done as soon as the shield is equipped (once: only while RiotShieldPart is not there yet).
	local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local function remote(name)
		return Remotes and Remotes:FindFirstChild(name)
	end
	-- An older build also picked items up and put armor on: a re-run removes that loop.
	CW.untrack("autoPickupStep")
	CW.Settings.AUTO_ARMOR_ENABLED, CW.Settings.AUTO_ARMOR_POLICE, CW.Settings.AUTO_ARMOR_CRIMINAL = nil, nil, nil

	--// Picking a gun: which one the server swaps ------------------------------------------------------------
	-- The game keeps a set number of primary/secondary guns, and taking another one swaps the gun IN HAND
	-- (the server decides; BackpackClient then puts the new gun in the slot the old one left). With Auto Slot a
	-- slot can hold several guns (e.g. slot 2 = M4A1 or M700). So when the player, holding another gun of the
	-- same kind (the Remington), takes a gun whose slot already holds one of theirs (the M700, for the M4A1):
	--   1. just before the click's request goes out, that slot's gun (the M4A1) is equipped instead,
	--   2. the request goes out, and the server swaps the M4A1 for the M700,
	--   3. the gun the player was holding (the Remington) is equipped again.
	-- The requests are the game's own (ClientItemHandler): Remotes.InteractWithItem:InvokeServer(part) for
	-- Prison_ITEMS givers and Remotes.GiverPressed:FireServer(model) for "Giver"/"TouchGiver" models. They are
	-- seen through a __namecall hook (installed once per session; CAPS.hook) and passed on unchanged.
	local SLOT_TYPES = {
		["AK-47"] = "Primary", FAL = "Primary", M4A1 = "Primary", MP5 = "Primary", ["Remington 870"] = "Primary",
		M700 = "Primary", M9 = "Secondary", Revolver = "Secondary",
	}
	local function slotTypeOf(tool)
		return tool:GetAttribute("SlotType") or SLOT_TYPES[tool.Name]
	end
	local swapping = false
	swapInProgress = function() return swapping end

	-- The tool a pickup request is for, or nil.
	local function requestedToolName(remoteObject, argument)
		if typeof(argument) ~= "Instance" then return nil end
		if remoteObject.Name == "GiverPressed" then
			local name = argument:GetAttribute("ToolName")
			return type(name) == "string" and name or nil
		end
		local model = argument.Parent
		local folder = model and model.Parent
		if folder and (folder.Name == "giver" or folder.Name == "single") then return model.Name end
		return nil
	end

	-- Decides whether this pickup should swap the slot's gun instead of the one in hand; when it should,
	-- equips that gun right away and returns what is needed to put things back.
	local function prepareSwap(remoteObject, argument)
		if swapping or not CW.Settings.AUTO_SLOT_ENABLED then return nil end
		local name = requestedToolName(remoteObject, argument)
		local kind = name and SLOT_TYPES[name]
		if not kind then return nil end
		layout = layouts[currentVariantKey()]
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		local held = character and character:FindFirstChildOfClass("Tool")
		if not (humanoid and backpack and held) or slotTypeOf(held) ~= kind then return nil end
		if backpack:FindFirstChild(name) or held.Name == name then return nil end -- already has it

		-- The slot this gun belongs to, and a gun of the player's already in that slot.
		local partner
		for slot = 1, SLOT_COUNT do
			local names = layout[slot]
			if names and table.find(names, name) then
				if table.find(names, held.Name) then return nil end -- the gun in hand belongs to that slot itself
				for _, other in ipairs(names) do
					local tool = other ~= name and backpack:FindFirstChild(other)
					if tool and tool:IsA("Tool") and slotTypeOf(tool) == kind then
						partner = tool
						break
					end
				end
				if partner then break end
			end
		end
		-- No gun of that slot to swap, or the gun in hand already belongs there: the game's own swap is right.
		if not partner then return nil end

		swapping = true
		pcall(function() humanoid:EquipTool(partner) end)
		return { name = name, held = held, partner = partner, humanoid = humanoid, backpack = backpack }
	end

	-- After the request: waits (2 s at most) for the server's swap, then equips the gun the player was holding.
	local function finishSwap(plan)
		task.spawn(function()
			local deadline = os.clock() + 2
			while os.clock() < deadline do
				local character = LocalPlayer.Character
				local arrived = plan.backpack:FindFirstChild(plan.name) or (character and character:FindFirstChild(plan.name))
				if arrived and plan.partner.Parent ~= plan.backpack and plan.partner.Parent ~= character then break end
				task.wait()
			end
			if plan.held.Parent == plan.backpack then
				pcall(function() plan.humanoid:EquipTool(plan.held) end)
			end
			task.wait()
			swapping = false
			queueArrange()
		end)
	end

	-- The first build of this hook (CW.State.pickupHooked) clobbered the game's call; with its dispatchers
	-- cleared it only passes calls on, so a re-run fixes the session without rejoining.
	CW.onPickupRequest, CW.onPickupDone = nil, nil
	CW.onPickupRequest2 = function(remoteObject, method, argument)
		if method ~= (remoteObject.Name == "GiverPressed" and "FireServer" or "InvokeServer") then return nil end
		local ok, plan = pcall(prepareSwap, remoteObject, argument)
		return ok and plan or nil
	end
	CW.onPickupDone2 = function(plan)
		if plan then finishSwap(plan) end
	end

	if CW.Caps.hook and not CW.State.pickupHooked2 then
		local remotes = ReplicatedStorage:FindFirstChild("Remotes")
		local interact = remotes and remotes:FindFirstChild("InteractWithItem")
		local giverPressed = remotes and remotes:FindFirstChild("GiverPressed")
		if interact and giverPressed then
			local isExecutorCall = type(checkcaller) == "function" and checkcaller or function() return false end
			local wrap = X.newcclosure or function(fn) return fn end
			local OldNameCall
			OldNameCall = X.hookmetamethod(game, "__namecall", wrap(function(self, ...)
				if (self == interact or self == giverPressed) and not isExecutorCall() then
					-- The method name is read FIRST: every method call made below (FindFirstChild, EquipTool...)
					-- replaces the one __namecall remembers, so the game's call is then made by its saved name
					-- (an indexed call, which doesn't come back through this hook).
					local method = getnamecallmethod()
					local plan
					if CW.onPickupRequest2 then
						local ok, result = pcall(CW.onPickupRequest2, self, method, (...))
						plan = ok and result or nil
					end
					-- The request goes out exactly as the game made it; only the gun in hand may have changed.
					local results = table.pack(self[method](self, ...))
					if plan and CW.onPickupDone2 then pcall(CW.onPickupDone2, plan) end
					return table.unpack(results, 1, results.n)
				end
				return OldNameCall(self, ...)
			end))
			CW.State.pickupHooked2 = true
		end
	end

	-- Riot shield: on the arm as soon as it is equipped (what a click while holding it does).
	-- ShieldController (decompiled) connects a click listener when the shield enters the character; each click
	-- fires ShieldEquipped and the server adds RiotShieldPart. Here the same request is sent in the very event
	-- the shield arrives in the hand (no wait: the equip and this request reach the server in that order), and
	-- only ONCE per equip: after that the shield is the player's again until it is put away and equipped again.
	-- If the server's shield never shows up (the equip reached it late) and the player didn't click meanwhile,
	-- the request is repeated one time.
	local function watchShield(character)
		CW.track("autoShield", character.ChildAdded:Connect(function(child)
			if not CW.Settings.AUTO_SLOT_ENABLED or not child:IsA("Tool") or child.Name ~= "Riot Shield" then return end
			local shieldEquipped = remote("ShieldEquipped")
			if not shieldEquipped or character:FindFirstChild("RiotShieldPart") then return end
			pcall(function() shieldEquipped:FireServer() end)

			local clicked = false
			local clickConnection = UserInputService.InputBegan:Connect(function(input, processed)
				if not processed and (input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch or input.KeyCode == Enum.KeyCode.ButtonR2) then
					clicked = true
				end
			end)
			task.delay(1, function()
				clickConnection:Disconnect()
				if not clicked and child.Parent == character and not character:FindFirstChild("RiotShieldPart") then
					pcall(function() shieldEquipped:FireServer() end)
				end
			end)
		end))
	end
	if LocalPlayer.Character then watchShield(LocalPlayer.Character) end
	CW.track("autoShieldCharacter", LocalPlayer.CharacterAdded:Connect(watchShield))

	-- Every tool of the game, grouped: guns, melee, the other tools, snacks. The EBR is in the Guns folder but
	-- has no ToolProperties (not in use), so it is left out.
	local HIDDEN_TOOLS = { EBR = true }
	local function gameToolNames()
		local names, seen = {}, table.clone(HIDDEN_TOOLS)
		local tools = ReplicatedStorage:FindFirstChild("Tools")
		local function addFrom(folder)
			if not folder then return end
			local group = {}
			for _, child in ipairs(folder:GetChildren()) do
				if child:IsA("Tool") and not seen[child.Name] then
					seen[child.Name] = true
					table.insert(group, child.Name)
				end
			end
			table.sort(group)
			for _, name in ipairs(group) do table.insert(names, name) end
		end
		if tools then
			addFrom(tools:FindFirstChild("Guns"))
			addFrom(tools:FindFirstChild("Melees"))
			addFrom(tools)
			addFrom(tools:FindFirstChild("Snacks"))
		end
		if #names == 0 then
			names = { "AK-47", "FAL", "M4A1", "M700", "M9", "MP5", "Remington 870", "Revolver", "Taser",
				"Crude Knife", "Hammer", "Breakfast", "C4 Explosive", "Dinner", "Handcuffs", "Key card", "Lunch",
				"Riot Shield", "Chips", "Chocolate", "Soda" }
		end
		return names
	end

	guarded("Auto Slot", function()
		local drawer = UtilityTab:AddSubSection("Auto Slot", false)

		drawer:Toggle({
			Title = "Enable Auto Slot",
			Default = CW.Settings.AUTO_SLOT_ENABLED == true,
			Callback = function(enabled)
				CW.Settings.AUTO_SLOT_ENABLED = enabled == true
				setAutoSlot(CW.Settings.AUTO_SLOT_ENABLED)
			end,
		})
		if not autoSlotCaps then
			drawer:AddLabel("Your executor has no getconnections or debug.getupvalue: Auto Slot works only with the game's \"Use Old Backpack\" setting.")
		end

		local allNames = gameToolNames()
		local boards = {}
		local labelToKey = {}
		local labels = {}
		for _, variant in ipairs(VARIANTS) do
			labelToKey[variant.label] = variant.key
			table.insert(labels, variant.label)
		end

		local function showBoard(variantKey)
			for key, board in pairs(boards) do
				if board.Instance then board.Instance.Visible = key == variantKey end
			end
		end

		-- Which team's layout the board edits (it opens on the current team's).
		local startKey = currentVariantKey()
		drawer:Dropdown({
			Title = "Layout For",
			Options = labels,
			Default = VARIANT_BY_KEY[startKey].label,
			Callback = function(label)
				local key = labelToKey[label]
				if key then showBoard(key) end
			end,
		})

		for _, variant in ipairs(VARIANTS) do
			local variantKey = variant.key
			local items = {}
			for _, name in ipairs(allNames) do
				if not variant.excluded[name] then table.insert(items, { Key = name, Text = name }) end
			end
			local board = drawer:SlotBoard({
				Slots = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
				Items = items,
				Value = layouts[variantKey],
				Extra = { Key = HIDDEN_KEY, Text = "Hidden", Badge = "H",
					Placeholder = "Drop a tool here to hide it from the inventory" },
				Hint = "Drag a tool onto a slot (several can share one: the first you have wins), or onto Hidden. "
					.. "Drag it out to clear it, or right-click. The riot shield goes on your arm as soon as you equip it.",
				Callback = function(newLayout)
					layouts[variantKey] = newLayout
					saveLayout(variantKey, newLayout)
					queueArrange()
				end,
			})
			if board then boards[variantKey] = board end
		end
		if next(boards) then
			showBoard(startKey)
		else
			drawer:AddLabel("Update CWUI.lua (the slot board is new) to edit the Auto Slot layouts.")
		end
	end)

	setAutoSlot(CW.Settings.AUTO_SLOT_ENABLED == true)
	-- <<< AUTO SLOT END
end)

------------------------------------------------------------------------------
-- Library <-> UI refresh
------------------------------------------------------------------------------
-- Rebuilds every library-backed control from disk. Core assets are reloaded separately
-- by CW.reloadCoreAssets (so this never touches the cursor/texture pipeline).
-- The gallery drops its own asset cache entries on every rebuild, so no extra cache clear is needed.
function refreshUIFromLibrary()
	for _, changer in ipairs(soundChangers) do changer.refreshCatalog() end

	local function syncGallery(gallery, category, weapon, selectedFile)
		if not gallery then return end
		gallery:SetItems(galleryItems(category, weapon))
		-- SetItems already restores the previous selection. Calling Set on an entry that is
		-- already selected would DESELECT it in galleries that allow deselecting (the weapon
		-- texture galleries), so Set is only used when the selection really has to change.
		local current = gallery:Get()
		if selectedFile then
			if not (current and current.Path == selectedFile) then gallery:Set(selectedFile, true) end
		elseif current then
			gallery:Clear()
		end
	end

	syncGallery(HitmarkerGallery, "Hitmarkers", nil, CW.Paths.HITMARKER_FILE)
	syncGallery(CursorGallery, "Cursors", nil, CW.Paths.CURSOR_FILE)
	for _, entry in ipairs(textureGalleries) do
		syncGallery(entry.gallery, "Textures", entry.weapon, CW.Library.selectedPath("Textures", entry.weapon))
	end
	for _, refreshMesh in ipairs(meshControls) do refreshMesh() end
	if refreshGunPreview then refreshGunPreview(nil, true) end

	for _, drawer in ipairs(hitSoundDrawers) do
		local options, entries = hitSoundCatalog(drawer.gun)
		drawer.entries = entries
		drawer.dropdown:Refresh(options)
		drawer.dropdown:Set(hitSoundLabel(entries, CW.HitSounds.relative(drawer.gun)) or "None", true)
		drawer.volume:Set(CW.HitSounds.volume(drawer.gun), true)
	end
	for _, changer in ipairs(soundChangers) do
		for _, entry in ipairs(changer.dropdowns) do
			local catalog = changer.catalog[entry.weapon]
			entry.control:Refresh(catalog and catalog.options or { WEAPON_SOUND_DEFAULT })
			entry.control:Set(changer.label(entry.weapon, changer.overrides[entry.weapon]), true)
			if entry.volume then entry.volume:Set(changer.volumeOf(entry.weapon), true) end
		end
		changer.refresh()
	end
end

------------------------------------------------------------------------------
-- Settings tab (created last so it is also the last tab)
------------------------------------------------------------------------------
guarded("Settings", function()
	-- Opened by the Settings button next to Discord (on an old CWUI it is a normal tab in the sidebar).
	local SettingsTab = createCompatTab({ Title = "Settings", Footer = "Settings" })

	local resetInterface -- set by the Interface block; the button sits in General

	-- Interface: colors, transparency, corners and the background image. Changes show at once and are saved.
	-- Three drawers so the page reads at a glance; one reset puts all of it back.
	guarded("Theme settings", function()
		if not canTheme then return end
		local look = CW.Settings.UI_THEME
		local current = CWUI.GetTheme()
		local resets = {} -- how each control goes back to the default look

		local Colors = SettingsTab:AddSubSection("Colors", true)
		local pickers = {}
		for _, entry in ipairs({
			{ "Highlight Color", "Accent" }, { "Tab Selector Color", "Selector" }, { "Text Color", "Text" },
			{ "Background Color", "Background" }, { "Sidebar Color", "Sidebar" }, { "Panel Color", "Panel" },
		}) do
			local key = entry[2]
			pickers[key] = Colors:Colorpicker({
				Title = entry[1],
				Default = current[key] or current.Accent, -- the selector follows the highlight until it is picked
				Callback = function(color)
					look[key] = color:ToHex()
					CWUI.SetTheme({ [key] = color })
					if key == "Accent" and not look.Selector and pickers.Selector then pickers.Selector:Set(color, true) end
				end,
			})
		end
		table.insert(resets, function(d)
			for key, picker in pairs(pickers) do picker:Set(d[key] or d.Accent, true) end
		end)

		local Surfaces = SettingsTab:AddSubSection("Transparency & Corners", false)
		for _, entry in ipairs({
			{ "Background Transparency", "BackgroundTransparency" }, { "Panel Transparency", "PanelTransparency" },
			{ "Tab Selector Transparency", "SelectorTransparency" },
		}) do
			local key = entry[2]
			local slider = Surfaces:Slider({
				Title = entry[1], Min = 0, Max = 1, Decimal = 2, Default = current[key],
				Callback = function(v)
					look[key] = v
					CWUI.SetTheme({ [key] = v })
				end,
			})
			table.insert(resets, function(d) slider:Set(d[key], true) end)
		end
		local cornersToggle = Surfaces:Toggle({
			Title = "Rounded Corners",
			Default = current.Corners,
			Callback = function(on)
				look.Corners = on
				CWUI.SetTheme({ Corners = on })
			end,
		})
		table.insert(resets, function(d) cornersToggle:Set(d.Corners, true) end)

		if canLayers then
			local Layers = SettingsTab:AddSubSection("Background Layers", false)
			local layers = backgroundLayers
			local selected = #layers > 0 and 1 or nil

			Layers:AddLabel("Up to " .. CWUI.MaxLayers .. " images, stacked. Click one in the preview to pick it, drag it to move it, drag the orange corner to resize it.")

			local canvas, picker, select, updateActions
			local controls = {} -- the selected layer's controls
			local layerDrawers = {} -- their drawers, hidden while there is no layer
			local function save()
				CW.Settings.UI_LAYERS = #layers > 0 and HttpService:JSONEncode(layers) or ""
				scheduleSave()
			end
			local function apply()
				Window:SetBackgroundLayers(windowLayers(layers))
				canvas:SetLayers(windowLayers(layers), selected)
			end
			local function refresh()
				local names = {}
				for i in ipairs(layers) do names[i] = "Layer " .. i end
				picker:Refresh(names)
				apply()
				select(selected)
			end

			canvas = Layers:LayerCanvas({
				OnSelect = function(index) select(index) end,
				Callback = function(index, rect)
					local layer = layers[index]
					layer.X, layer.Y, layer.W, layer.H = rect.X, rect.Y, rect.W, rect.H
					Window:SetBackgroundLayers(windowLayers(layers))
					save()
				end,
			})

			-- Add and Remove sit in the header of the layer list, like Add / Edit / Remove on every other list.
			picker = Layers:Dropdown({
				Title = "Layer", Options = {},
				Callback = function(name) select(tonumber(tostring(name):match("%d+"))) end,
			})
			local function addLayer()
				if #layers >= CWUI.MaxLayers then return end
				table.insert(layers, {
					X = 0, Y = 0, W = 1, H = 1, Depth = math.min(#layers + 1, 10),
					Transparency = 0, Scale = "Crop", FillTransparency = 1,
				})
				selected = #layers
				refresh()
				save()
			end
			local function removeLayer()
				if not selected then return end
				table.remove(layers, selected)
				selected = #layers > 0 and math.min(selected, #layers) or nil
				refresh()
				save()
			end
			local shownActions
			updateActions = function()
				local state = (#layers < CWUI.MaxLayers and "a" or "") .. (selected and "r" or "")
				if state == shownActions then return end
				shownActions = state
				local actions = {}
				if #layers < CWUI.MaxLayers then table.insert(actions, { Text = "Add", Callback = addLayer }) end
				if selected then table.insert(actions, { Text = "Remove", Callback = removeLayer }) end
				picker:SetActions(actions)
				picker:ShowActions(#actions > 0)
			end

			-- Every control below edits the selected layer, then redraws and saves.
			local function edit(change)
				local layer = selected and layers[selected]
				if not layer then return end
				change(layer)
				apply()
				save()
			end

			-- A Roblox image ID (or link) is checked before use; anything else is a file in the workspace.
			local function checkImage(source, row, onValid)
				local id = CW.CustomIds.parse(source)
				if id then
					row:Flash(1, "Checking", 6)
					checkCustomAsset("rbxassetid://" .. id, "Image", function(loaded)
						if loaded then
							onValid("rbxassetid://" .. id)
							row:Flash(1, "Applied")
						else
							row:Flash(1, "Invalid")
						end
					end)
					return
				end
				local found, exists = pcall(function() return isfile(source) end)
				if found and exists then
					onValid(source)
					row:Flash(1, "Applied")
				else
					row:Flash(1, "Not found")
				end
			end

			local Image = Layers:AddSubSection("Image", true)
			controls.image = Image:InputRow({
				Fields = { { Key = "image", Placeholder = "Image ID or workspace file" } },
				Buttons = {
					{ Text = "Apply", Callback = function(values, row)
						local source = (values.image or ""):match("^%s*(.-)%s*$")
						if source == "" then row:Flash(1, "Empty") return end
						checkImage(source, row, function(valid) edit(function(layer) layer.Image = valid end) end)
					end },
					{ Text = "Clear", Callback = function(_, row)
						row:Clear()
						edit(function(layer) layer.Image = nil end)
					end },
				},
			})
			controls.scale = Image:Dropdown({
				Title = "Scaling", Options = { "Crop", "Fit", "Stretch" }, Default = "Crop",
				Callback = function(v) edit(function(layer) layer.Scale = v end) end,
			})
			controls.transparency = Image:Slider({
				Title = "Transparency", Min = 0, Max = 1, Decimal = 2, Default = 0,
				Callback = function(v) edit(function(layer) layer.Transparency = v end) end,
			})

			local Placement = Layers:AddSubSection("Depth & Placement", false)
			Placement:AddLabel("Depth 0 stays still. A higher depth moves more with Parallax and is drawn on top.")
			controls.depth = Placement:Slider({
				Title = "Depth", Min = 0, Max = 10, Increment = 0.5, Default = 1,
				Callback = function(v) edit(function(layer) layer.Depth = v end) end,
			})
			controls.fit = Placement:Button({
				Title = "Fill the Whole Window",
				Callback = function() edit(function(layer) layer.X, layer.Y, layer.W, layer.H = 0, 0, 1, 1 end) end,
			})

			local Fill = Layers:AddSubSection("Fill Color", false)
			Fill:AddLabel("Tints this layer's image, or fills the layer when it has no image. Transparency 1 turns it off.")
			local fillTransparency -- the slider under the color
			controls.fill = Fill:Colorpicker({
				Title = "Color", Default = Color3.new(0, 0, 0),
				Callback = function(color)
					edit(function(layer)
						layer.Fill = color:ToHex()
						-- Picking a color on a fill that is turned off turns it on: otherwise nothing changes.
						if (layer.FillTransparency or 1) >= 1 then
							layer.FillTransparency = 0
							fillTransparency:Set(0, true)
						end
					end)
				end,
			})
			fillTransparency = Fill:Slider({
				Title = "Transparency", Min = 0, Max = 1, Decimal = 2, Default = 1,
				Callback = function(v) edit(function(layer) layer.FillTransparency = v end) end,
			})
			controls.fillTransparency = fillTransparency
			layerDrawers = { Image, Placement, Fill }

			-- Shows the chosen layer in every control (without saving), or hides them when there is none.
			select = function(index)
				selected = layers[index or 0] and index or nil
				local layer = selected and layers[selected]
				for _, drawer in ipairs(layerDrawers) do
					if typeof(drawer.Instance) == "Instance" then drawer.Instance.Visible = layer ~= nil end
				end
				canvas:Select(selected)
				picker:Set(layer and ("Layer " .. selected) or nil, true)
				updateActions()
				if not layer then return end
				controls.image:Set("image", layer.Image or "")
				controls.depth:Set(layer.Depth or 0, true)
				controls.transparency:Set(layer.Transparency or 0, true)
				controls.scale:Set(layer.Scale or "Crop", true)
				local ok, fill = pcall(Color3.fromHex, type(layer.Fill) == "string" and layer.Fill or "")
				controls.fill:Set(ok and fill or Color3.new(0, 0, 0), true)
				controls.fillTransparency:Set(layer.FillTransparency or 1, true)
			end

			refresh()

			-- Parallax: how all layers react to the mouse. Its own drawer, apart from editing one layer.
			local Parallax = SettingsTab:AddSubSection("Parallax", false)
			Parallax:AddLabel("The background layers drift against the mouse; each layer's depth sets how far.")
			local strength = tonumber(look.ParallaxStrength) or PARALLAX_DEFAULT
			local function applyParallax()
				Window:SetParallax(look.Parallax == true, strength, look.ParallaxHoverOnly == true)
			end
			local parallaxToggle = Parallax:Toggle({
				Title = "Parallax", Default = look.Parallax == true,
				Callback = function(on) look.Parallax = on applyParallax() end,
			})
			local strengthSlider = Parallax:Slider({
				Title = "Strength", Min = 1, Max = 10, Increment = 0.5, Suffix = "%", Default = strength * 100,
				Callback = function(v)
					strength = v / 100
					look.ParallaxStrength = strength
					applyParallax()
				end,
			})
			local hoverToggle = Parallax:Toggle({
				Title = "Only With the Mouse Over the Window", Default = look.ParallaxHoverOnly == true,
				Callback = function(on) look.ParallaxHoverOnly = on applyParallax() end,
			})

			table.insert(resets, function()
				table.clear(layers)
				selected = nil
				strength = PARALLAX_DEFAULT
				applyParallax()
				parallaxToggle:Set(false, true)
				strengthSlider:Set(strength * 100, true)
				hoverToggle:Set(false, true)
				refresh()
				CW.Settings.UI_LAYERS = ""
			end)
		end

		resetInterface = function()
			table.clear(look)
			CWUI.ResetTheme()
			local defaults = CWUI.GetTheme()
			for _, reset in ipairs(resets) do reset(defaults) end
			scheduleSave()
		end
	end)

	-- General: the asset library, saving, and putting the interface back to its defaults.
	local General = SettingsTab:AddSubSection("General", false)
	General:AddLabel("Every change is saved by itself about a second later.")
	General:Button({
		Title = "Refresh Asset Library",
		Callback = function()
			local syncOK, syncError = pcall(CW.Library.sync)
			if not syncOK then CW.Warn("Library sync failed: " .. tostring(syncError)) end
			CW.reloadCoreAssets()
			guarded("Library refresh", refreshUIFromLibrary)
			CW.Log("Asset library refreshed.")
		end,
	})


	General:Button({
		Title = "Save Now",
		Callback = function()
			saveSettings()
			CW.Log("Settings saved.")
		end,
	})
	if resetInterface then
		General:Button({ Title = "Reset Interface", Callback = function() resetInterface() end })
	end

	-- Settings slots: named copies of every setting, each a file in SETTINGS_SLOTS_FOLDER written like the settings
	-- file. Saving copies the settings in use into a slot. Loading makes a slot the settings in use and runs
	-- CycleWare again (CW.restart), so every module and control starts from it, as on a fresh start.
	guarded("Settings Slots", function()
		if not CAPS.files then return end
		local SLOTS = CW.Paths.SETTINGS_SLOTS_FOLDER
		local Slots = SettingsTab:AddSubSection("Settings Slots", false)
		local status = Slots:AddLabel("")
		local function showStatus(extra)
			local slot = CW.Settings.SETTINGS_SLOT
			local text = slot ~= "" and ("In use: " .. slot .. ". ") or ""
			status:Set(text .. (extra or "Save the settings you have now to a slot, or load one."))
		end

		local function slotPath(name) return SLOTS .. "/" .. name .. ".json" end
		local function slotNames()
			local names = {}
			local ok, files = pcall(listfiles, SLOTS)
			for _, path in ipairs(ok and type(files) == "table" and files or {}) do
				local name = tostring(path):match("([^/\\]+)%.json$")
				if name then table.insert(names, name) end
			end
			table.sort(names, function(a, b) return a:lower() < b:lower() end)
			return names
		end
		-- A slot name is also a file name: letters, digits, spaces, - and _, at most 32.
		local function cleanName(text)
			local name = tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
			if name == "" or #name > 32 or name:find("[^%w%s%-_]") then return nil end
			return name
		end

		-- The settings in use, written into a slot. The slot keeps its own name, and the settings in use now say they
		-- are that slot's (kept only when the slot was written).
		local function writeSlot(name)
			local previous = CW.Settings.SETTINGS_SLOT
			CW.Settings.SETTINGS_SLOT = name
			local encoded = encodeSettings()
			if not isfolder(SLOTS) then pcall(makefolder, SLOTS) end
			local ok, err = false, "the settings could not be encoded"
			if encoded then ok, err = pcall(writefile, slotPath(name), encoded) end
			if not ok then
				CW.Settings.SETTINGS_SLOT = previous
				CW.Warn("Could not save the settings slot " .. name .. ": " .. tostring(err))
				return false
			end
			scheduleSave()
			return true
		end

		local picker -- the dropdown of slots
		-- Lists the slots again and selects `wanted`, else the slot in use, else the first.
		local function refreshPicker(wanted)
			local names = slotNames()
			local options = #names > 0 and names or { "None" }
			picker:Refresh(options)
			local chosen = (wanted and table.find(names, wanted) and wanted)
				or (table.find(names, CW.Settings.SETTINGS_SLOT) and CW.Settings.SETTINGS_SLOT) or options[1]
			picker:Set(chosen, true)
		end
		local function selectedSlot()
			local name = picker:Get()
			return name and table.find(slotNames(), name) and name or nil
		end

		-- Load and Delete throw away settings, so they ask for a second press within 3 seconds.
		local armed = {}
		local function confirmed(action, row, index)
			local now = os.clock()
			if armed[action] and now - armed[action] < 3 then
				armed[action] = nil
				return true
			end
			armed[action] = now
			if row and row.Flash then row:Flash(index, "Sure?", 3) end
			return false
		end

		local newRow = Slots:InputRow({
			Fields = { { Key = "name", Placeholder = "Slot name" } },
			Buttons = { { Text = "Save", Callback = function(values, row)
				local name = cleanName(values.name)
				if not name then
					row:Flash(1, "Invalid")
					return
				end
				local replaced = table.find(slotNames(), name) ~= nil
				if not writeSlot(name) then
					row:Flash(1, "Failed")
					return
				end
				row:Clear()
				row:Flash(1, replaced and "Replaced" or "Saved")
				refreshPicker(name)
				showStatus()
			end } },
		})
		if not newRow then -- an old CWUI without input rows
			Slots:AddLabel("Update CWUI.lua to name and save settings slots.")
			return
		end

		picker = Slots:Dropdown({ Title = "Slot", Options = { "None" }, Default = "None", Callback = function() end })

		local function load(row)
			local name = selectedSlot()
			if not name then
				row:Flash(1, "None")
				return
			end
			if not confirmed("load", row, 1) then return end
			local read, raw = pcall(readfile, slotPath(name))
			local parsed, slot = false, nil
			if read then parsed, slot = pcall(HttpService.JSONDecode, HttpService, raw) end
			if not (parsed and type(slot) == "table" and type(slot.Settings) == "table") then
				row:Flash(1, "Broken")
				return
			end
			-- The slot becomes the settings file; nothing this run still has may be saved over it.
			slot.Settings.SETTINGS_SLOT = name
			local encodedOK, encoded = pcall(HttpService.JSONEncode, HttpService, slot)
			stopSaving()
			local written = encodedOK and pcall(writefile, CW.Paths.SETTINGS_FILE, encoded)
			if not written then
				savesStopped = false
				row:Flash(1, "Failed")
				return
			end
			CW.Log("Loading the settings slot " .. name .. ": running CycleWare again")
			local restarted, why = CW.restart()
			if not restarted then
				CW.Warn("Could not run CycleWare again (" .. tostring(why) .. ")")
				showStatus("Loaded " .. name .. ". Run CycleWare again to use it; changes made until then are not saved.")
			end
		end

		local actions = Slots:InputRow({
			Buttons = {
				{ Text = "Load", Callback = function(_, row) load(row) end },
				{ Text = "Update", Callback = function(_, row)
					local name = selectedSlot()
					if not name then
						row:Flash(2, "None")
						return
					end
					row:Flash(2, writeSlot(name) and "Saved" or "Failed")
					showStatus()
				end },
				{ Text = "Delete", Callback = function(_, row)
					local name = selectedSlot()
					if not name then
						row:Flash(3, "None")
						return
					end
					if not confirmed("delete", row, 3) then return end
					if pcall(delfile, slotPath(name)) then
						if CW.Settings.SETTINGS_SLOT == name then
							CW.Settings.SETTINGS_SLOT = ""
							scheduleSave()
						end
						refreshPicker()
						showStatus()
					else
						row:Flash(3, "Failed")
					end
				end },
			},
		})
		if not CAPS.delfile then actions:SetButtonVisible(3, false) end
		refreshPicker()
		showStatus()
	end)
end)

local soundsMigrated = false
for _, changer in ipairs(soundChangers) do
	changer.schedule()
	if changer.migrated then soundsMigrated = true end
end
-- Write the cleaned-up overrides (so the warning shows only once) and the per-gun switches.
if soundsMigrated or switchesMigrated then scheduleSave() end
print("[CW] UI loaded.")

-- The asset sync runs on its own (Sync module). When it changed the library after the lists were made, they are
-- made again.
local function afterSync(changed)
	if changed then guarded("Library refresh", refreshUIFromLibrary) end
end
if not syncDoneBeforeUI then
	if CW.State.syncFinished then
		afterSync(CW.State.syncChanged)
	else
		table.insert(CW.State.syncCallbacks, afterSync)
	end
end
end)

--// Finish: open the window, or say why there is none --------------------------------------
-- Names for the window's list of what failed.
local STEP_NAMES = {
	Cache = "Cache folders", AssetLibrary = "Asset library", PNG = "Cursor images", Cursor = "Cursor",
	Hitmarker = "Hitmarker", Sound = "Hit sounds", Texture = "Gun looks", Tracers = "Tracers", Hook = "Hit detection",
	Cleanup = "Cleanup", Sync = "Library download", AntiAFK = "Anti-AFK", Interface = "Interface",
}
local MESH_WAIT = 2 -- seconds the chosen meshes get before the window opens (one still loading shows "Loading the mesh")
runModule("Finish", function()
	if not isCurrentRun() then return end
	local window = interface.window
	if not window then
		loadingScreen.finish("failed", interface.failure or "The interface could not start. Run CycleWare again.")
		return
	end
	if CW.waitForMeshes then
		loadingScreen.step("Loading meshes", 0.9)
		pcall(CW.waitForMeshes, MESH_WAIT)
	end
	if not isCurrentRun() then return end
	local function problemNames()
		local names = {}
		for name in pairs(startupProblems) do table.insert(names, STEP_NAMES[name] or name) end
		table.sort(names)
		return names
	end
	local problems = problemNames()
	local opened = false
	local function open()
		if opened or not isCurrentRun() then return end
		opened = true
		window.Ready = true
		interface.showProblems = function()
			local names = problemNames()
			if #names == 0 or type(window.SetNotice) ~= "function" or window._destroyed then return end
			-- Three names at most, so the line stays short; the console has them all.
			local list = table.concat(names, ", ", 1, math.min(#names, 3))
			if #names > 3 then list ..= " and " .. (#names - 3) .. " more" end
			window:SetNotice("Some parts did not load: " .. list .. ". The rest works. Details are in the console (F9).")
		end
		pcall(interface.showProblems)
		local shown, err = pcall(window.SetVisible, window, true)
		if not shown then warn("[CW] Could not show the window: " .. tostring(err)) end
		for _, fn in ipairs(interface.whenOpen) do
			task.spawn(cleanThread(function()
				local ok, failure = pcall(fn)
				if not ok then warn("[CW] " .. tostring(failure)) end
			end))
		end
	end
	if #problems > 0 then
		loadingScreen.finish("problems", "Loaded with " .. #problems .. (#problems == 1 and " problem" or " problems"), open)
	else
		loadingScreen.finish("ready", nil, open)
	end
	-- The loading screen opens it as it goes; should that not happen (its frame loop broke), the screen is taken
	-- away and the window opens anyway.
	task.delay(12, function()
		if opened or not isCurrentRun() then return end
		warn("[CW] The loading screen did not open the window; opening it now.")
		if CW.closeLoadingScreen then pcall(CW.closeLoadingScreen) end
		local ok, err = runClean("opening the window", open)
		if not ok then warn("[CW] The window could not be opened: " .. tostring(err)) end
	end)
end)

--=============================================================================
-- Startup
--   The steps recorded by runModule run in order, on a clean thread. A step that throws is reported (and
--   listed by the window) and the next one still runs. If the thread lost its permissions anyway (an executor
--   function this file does not wrap), the next step runs on a new clean thread. A re-run stops the steps of
--   the run before it (isCurrentRun).
--=============================================================================
local function runSteps(from)
	for index = from, #steps do
		if not isCurrentRun() then return end
		local step = steps[index]
		if not threadCanTouchGui() then
			warn("[CW] The startup thread lost its permissions before the " .. step.name .. " step; continuing on a new thread.")
			local thread = cleanThread(function() runSteps(index) end)
			CW.State.startupThread = thread
			loadingScreen.watch(thread)
			task.spawn(thread)
			return
		end
		local ok, err = xpcall(step.fn, function(message) return debug.traceback(tostring(message), 2) end)
		if not ok then
			startupProblems[step.name] = tostring(err)
			warn("[CW] Module '" .. step.name .. "' failed: " .. tostring(err))
		end
	end
end
do
	local thread = cleanThread(function() runSteps(1) end)
	CW.State.startupThread = thread
	loadingScreen.watch(thread)
	task.spawn(thread)
end
