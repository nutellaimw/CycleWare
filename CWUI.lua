--[[
    CW UI Library  v2.2

    IMAGENS
      Qualquer campo de imagem (Icon, Logo, Items...) aceita:
        • caminho na workspace do executor  -> "CW/icons/sounds.png"   (usa getcustomasset)
        • ID do Roblox                      -> 123456789  /  "123456789"  /  "rbxassetid://123456789"
      Se o campo for omitido, nada é desenhado.

    UNC usado (tudo opcional, com fallback):
        gethui, cloneref, protect_gui (syn), setclipboard,
        isfile, isfolder, listfiles, getcustomasset

    ESTRUTURA
        Window -> Tab -> Section -> SubSection (aninhável) -> elementos
        Elementos: Label, Button, Toggle, Slider, Textbox, Dropdown, Colorpicker, Gallery
]]

local CW = { Version = "2.2.0" }

--// Services ---------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local TweenService     = cloneref(game:GetService("TweenService"))
local UserInputService = cloneref(game:GetService("UserInputService"))
local CoreGui          = cloneref(game:GetService("CoreGui"))
local Players          = cloneref(game:GetService("Players"))

--// Tema ---------------------------------------------------------------------
local Theme = {
	Shell         = Color3.fromRGB(18, 19, 23),
	Sidebar       = Color3.fromRGB(63, 65, 70),   -- barra lateral (cinza liso, como no protótipo)
	Logo          = Color3.fromRGB(87, 89, 93),   -- faixa do logo
	Content       = Color3.fromRGB(28, 29, 34),   -- fundo da janela / área de conteúdo
	Selected      = Color3.fromRGB(22, 67, 114),
	TabHover      = Color3.fromRGB(88, 89, 95),
	Header        = Color3.fromRGB(56, 58, 62),
	HeaderHover   = Color3.fromRGB(68, 69, 75),
	Body          = Color3.fromRGB(38, 39, 44),
	SubBody       = Color3.fromRGB(31, 32, 37),
	Item          = Color3.fromRGB(52, 53, 59),
	ItemHover     = Color3.fromRGB(63, 64, 71),
	ItemSelected  = Color3.fromRGB(36, 52, 78),
	Track         = Color3.fromRGB(30, 31, 36),
	Accent        = Color3.fromRGB(31, 90, 166),
	Text          = Color3.fromRGB(255, 255, 255),
	SubText       = Color3.fromRGB(170, 171, 178),
	Divider       = Color3.fromRGB(86, 88, 92),
}
CW.Theme = Theme

--// Helpers ------------------------------------------------------------------
local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then parent = v else inst[k] = v end
	end
	for _, c in ipairs(children or {}) do c.Parent = inst end
	inst.Parent = parent
	return inst
end

local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function circle()  return new("UICorner", { CornerRadius = UDim.new(1, 0) }) end

local function tween(inst, props, t, style)
	local tw = TweenService:Create(inst, TweenInfo.new(t or 0.15, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function safeCall(fn, ...)
	if type(fn) ~= "function" then return end
	local args = table.pack(...)
	task.spawn(function()
		local ok, err = pcall(fn, table.unpack(args, 1, args.n))
		if not ok then warn("[CW] callback error: " .. tostring(err)) end
	end)
end

local function fmt(n) return tostring(math.floor(n * 1000 + 0.5) / 1000) end

local function isClick(i)
	return i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch
end

-- input.Position e AbsolutePosition usam o mesmo espaço de coordenadas.
local function insideGui(gui, pos)
	local p, s = gui.AbsolutePosition, gui.AbsoluteSize
	return pos.X >= p.X and pos.X <= p.X + s.X and pos.Y >= p.Y and pos.Y <= p.Y + s.Y
end

-- Casas decimais de um passo (0.01 -> 2). Usado para arredondar o valor do slider sem ruído de float.
local function decimalsOf(step)
	for d = 0, 6 do
		local m = 10 ^ d
		if math.abs(step * m - math.floor(step * m + 0.5)) < 1e-7 then return d end
	end
	return 6
end

--// Resolução de imagens: ID do Roblox ou arquivo da workspace ----------------
local assetCache, warned = {}, {}

local function warnOnce(msg)
	if not warned[msg] then warned[msg] = true warn("[CW] " .. msg) end
end

local function resolveAsset(src)
	if src == nil or src == "" then return nil end
	if type(src) == "number" then return "rbxassetid://" .. math.floor(src) end
	if type(src) ~= "string" then return nil end
	if src:match("^rbxasset") then return src end
	if tonumber(src) then return "rbxassetid://" .. src end

	local cached = assetCache[src]
	if cached then return cached end

	if not (getcustomasset and isfile) then
		warnOnce("getcustomasset/isfile indisponível: não foi possível carregar '" .. src .. "'")
		return nil
	end
	local ok, res = pcall(function()
		if isfile(src) then return getcustomasset(src) end
	end)
	if ok and res then
		assetCache[src] = res
		return res
	end
	warnOnce("imagem não encontrada na workspace: '" .. src .. "'")
	return nil
end

function CW.ClearAssetCache() table.clear(assetCache) end

local function makeIcon(parent, icon, size, pos)
	local holder = new("Frame", {
		Name = "Icon", BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5),
		Position = pos, Size = UDim2.fromOffset(size, size), Parent = parent,
	})
	local asset = resolveAsset(icon)
	if asset then
		new("ImageLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Image = asset,
			ScaleType = Enum.ScaleType.Fit, Parent = holder,
		})
	end
	return holder
end

-- Seta desenhada (não depende de imagem)
local function makeChevron(parent, pos, scale)
	scale = scale or 1
	local s = 20 * scale
	local holder = new("Frame", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = pos,
		Size = UDim2.fromOffset(s, s), Parent = parent,
	})
	local function arm(x, rot)
		new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x * scale, 9.5 * scale),
			Size = UDim2.fromOffset(11 * scale, 2.6 * scale), Rotation = rot,
			BackgroundColor3 = Theme.Text, BorderSizePixel = 0, Parent = holder,
		}, { corner(2) })
	end
	arm(6.5, 45)
	arm(13.5, -45)
	return holder
end

--// Fila de carregamento (evita travar ao carregar muitas imagens) -----------
local loadQueue, loading = {}, false
local function enqueueLoad(src, cb)
	table.insert(loadQueue, { src, cb })
	if loading then return end
	loading = true
	task.spawn(function()
		while #loadQueue > 0 do
			local job = table.remove(loadQueue, 1)
			local ok, asset = pcall(resolveAsset, job[1])
			pcall(job[2], ok and asset or nil)
			task.wait()
		end
		loading = false
	end)
end

--=============================================================================
-- Classes
--=============================================================================
local Window, Tab, Section = {}, {}, {}
Window.__index, Tab.__index, Section.__index = Window, Tab, Section

function Tab:_next() self._n += 1 return self._n end
function Section:_next() self._n += 1 return self._n end

--// Section: linha base -------------------------------------------------------
function Section:_row(height)
	return new("Frame", {
		BackgroundColor3 = Theme.Item, BorderSizePixel = 0, LayoutOrder = self:_next(),
		Size = UDim2.new(1, 0, 0, height or 36), Parent = self._body,
	}, { corner(6) })
end

local function rowLabel(row, text)
	return new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0.55, 0, 1, 0),
		Text = text, TextColor3 = Theme.Text, TextSize = 15, Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
	})
end

function Section:AddLabel(text)
	local lbl = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_next(), Text = text or "", TextColor3 = Theme.SubText, TextSize = 14,
		Font = Enum.Font.Gotham, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Parent = self._body,
	}, { new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2) }) })
	return { Set = function(_, t) lbl.Text = t end, Instance = lbl }
end

function Section:AddButton(o)
	o = type(o) == "string" and { Name = o } or o
	local btn = new("TextButton", {
		BackgroundColor3 = Theme.Item, BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = self:_next(),
		Size = UDim2.new(1, 0, 0, 36), Text = o.Name or "Button", TextColor3 = Theme.Text,
		TextSize = 15, Font = Enum.Font.GothamMedium, Parent = self._body,
	}, { corner(6) })
	btn.MouseEnter:Connect(function() tween(btn, { BackgroundColor3 = Theme.ItemHover }) end)
	btn.MouseLeave:Connect(function() tween(btn, { BackgroundColor3 = Theme.Item }) end)
	btn.MouseButton1Click:Connect(function() safeCall(o.Callback) end)
	return { Instance = btn, SetText = function(_, t) btn.Text = t end }
end

function Section:AddToggle(o)
	o = type(o) == "string" and { Name = o } or o
	local state = o.Default == true
	local row = self:_row(36)
	rowLabel(row, o.Name or "Toggle")

	local sw = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(40, 20),
		BackgroundColor3 = state and Theme.Accent or Theme.Track, BorderSizePixel = 0, Parent = row,
	}, { circle() })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = state and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(16, 16), BackgroundColor3 = Theme.Text, BorderSizePixel = 0, Parent = sw,
	}, { circle() })

	local obj = { Instance = row }
	function obj:Set(v, silent)
		state = v and true or false
		tween(sw, { BackgroundColor3 = state and Theme.Accent or Theme.Track })
		tween(knob, { Position = state and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0) })
		if not silent then safeCall(o.Callback, state) end
	end
	function obj:Get() return state end

	local hit = new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.fromScale(1, 1), Parent = row })
	hit.MouseButton1Click:Connect(function() obj:Set(not state) end)
	return obj
end

function Section:AddSlider(o)
	local min, max, inc = o.Min or 0, o.Max or 100, o.Increment or 1
	local scale = 10 ^ math.max(decimalsOf(inc), decimalsOf(min))
	local value = min
	local row = self:_row(50)
	local nameLbl = rowLabel(row, o.Name or "Slider")
	nameLbl.Size = UDim2.new(0.6, 0, 0, 30)

	local valLbl = new("TextLabel", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 0),
		Size = UDim2.new(0.4, 0, 0, 30), TextXAlignment = Enum.TextXAlignment.Right, Text = "",
		TextColor3 = Theme.SubText, TextSize = 14, Font = Enum.Font.GothamMedium, Parent = row,
	})
	local track = new("Frame", {
		Position = UDim2.new(0, 12, 1, -16), Size = UDim2.new(1, -24, 0, 6),
		BackgroundColor3 = Theme.Track, BorderSizePixel = 0, Parent = row,
	}, { corner(3) })
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Parent = track }, { corner(3) })
	local hit = new("TextButton", {
		BackgroundTransparency = 1, Text = "", AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 24), Parent = track,
	})

	local obj = { Instance = row }
	function obj:Set(v, silent)
		v = math.floor((v - min) / inc + 0.5) * inc + min
		v = math.clamp(math.floor(v * scale + 0.5) / scale, min, max) -- sem ruído (0.35 e não 0.35000000000000003)
		value = v
		fill.Size = UDim2.fromScale(max == min and 0 or (v - min) / (max - min), 1)
		valLbl.Text = fmt(v) .. (o.Suffix or "")
		if not silent then safeCall(o.Callback, v) end
	end
	function obj:Get() return value end

	local dragging = false
	local function update(x)
		local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		obj:Set(min + (max - min) * a)
	end
	hit.InputBegan:Connect(function(i)
		if isClick(i) then dragging = true self._window:_lockScroll(true) update(i.Position.X) end
	end)
	self._window:_connect(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			update(i.Position.X)
		end
	end)
	self._window:_connect(UserInputService.InputEnded, function(i)
		if isClick(i) and dragging then dragging = false self._window:_lockScroll(false) end
	end)

	obj:Set(o.Default or min, true)
	return obj
end

function Section:AddTextbox(o)
	o = type(o) == "string" and { Name = o } or o
	local row = self:_row(36)
	rowLabel(row, o.Name or "Textbox")
	local box = new("TextBox", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.new(0.4, 0, 0, 24),
		BackgroundColor3 = Theme.Track, BorderSizePixel = 0, ClearTextOnFocus = false,
		Text = o.Default or "", PlaceholderText = o.Placeholder or "...", PlaceholderColor3 = Theme.SubText,
		TextColor3 = Theme.Text, TextSize = 14, Font = Enum.Font.Gotham, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
	}, { corner(5), new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6) }) })
	box.FocusLost:Connect(function(enter) safeCall(o.Callback, box.Text, enter) end)
	return { Instance = row, Get = function() return box.Text end, Set = function(_, t) box.Text = t end }
end

function Section:AddDropdown(o)
	local options = o.Options or {}
	local selected = o.Default
	local open = false
	local row = self:_row(36)
	row.ClipsDescendants = true

	local head = new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.new(1, 0, 0, 36), Parent = row })
	rowLabel(head, o.Name or "Dropdown")
	local valLbl = new("TextLabel", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.new(0.4, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, Text = tostring(selected or "—"),
		TextColor3 = Theme.SubText, TextSize = 14, Font = Enum.Font.GothamMedium, Parent = head,
	})
	local maxList = o.MaxHeight or 168
	local list = new("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(6, 38),
		Size = UDim2.new(1, -12, 0, 0), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Divider,
		ScrollingDirection = Enum.ScrollingDirection.Y, Parent = row,
	}, { new("UIListLayout", { Padding = UDim.new(0, 2) }) })

	local obj = { Instance = row }
	local function listHeight() return math.min(#options * 28, maxList) end
	local function height() return 36 + 8 + listHeight() end
	local popup = { row = row, autoClose = true, isOpen = function() return open end }
	local function setOpen(v)
		if v and not open then self._window:_popupOpening(popup) end
		open = v
		list.Size = UDim2.new(1, -12, 0, listHeight())
		tween(row, { Size = UDim2.new(1, 0, 0, open and height() or 36) }, 0.2)
	end
	function obj:Set(v, silent)
		selected = v
		valLbl.Text = tostring(v)
		for _, b in ipairs(list:GetChildren()) do
			if b:IsA("TextButton") then b.TextColor3 = (b.Name == tostring(v)) and Theme.Text or Theme.SubText end
		end
		if not silent then safeCall(o.Callback, v) end
	end
	function obj:Get() return selected end
	function obj:Refresh(newOptions)
		options = newOptions or {}
		for _, b in ipairs(list:GetChildren()) do if b:IsA("TextButton") then b:Destroy() end end
		for _, opt in ipairs(options) do
			local b = new("TextButton", {
				Name = tostring(opt), BackgroundColor3 = Theme.ItemHover, BackgroundTransparency = 1, BorderSizePixel = 0,
				Size = UDim2.new(1, 0, 0, 26), Text = tostring(opt), TextSize = 14, Font = Enum.Font.GothamMedium,
				TextColor3 = (opt == selected) and Theme.Text or Theme.SubText, AutoButtonColor = false, Parent = list,
			}, { corner(5) })
			b.MouseEnter:Connect(function() tween(b, { BackgroundTransparency = 0.4 }) end)
			b.MouseLeave:Connect(function() tween(b, { BackgroundTransparency = 1 }) end)
			b.MouseButton1Click:Connect(function() obj:Set(opt) setOpen(false) end)
		end
		if open then setOpen(true) end
	end
	head.MouseButton1Click:Connect(function() setOpen(not open) end)
	popup.close = function() setOpen(false) end
	self._window:_registerPopup(popup)
	obj:Refresh(options)
	return obj
end

--=============================================================================
-- Colorpicker  (baseado no "Color Picker Module" do Studio, com o visual do CW)
--
--   Section:AddColorpicker({
--       Name     = "Cor",
--       Default  = Color3.fromRGB(170, 0, 255),
--       Callback = function(color) end,        -- Color3; chamado na hora, a cada mudança (arrastar ou digitar)
--       OnOpen   = function() end,             -- (opcional) painel aberto
--       OnClose  = function() end,             -- (opcional) painel fechado
--   })
--   Retorno: :Get() / :GetColor() -> Color3      :Set(color3, silent) / :SetColor(color3, silent)
--            :Start() / :SetOpen(bool)           :IsOpen()      :Destroy()
--
--   Sem botões: a cor é aplicada assim que muda. O painel abre e fecha clicando no cabeçalho (ou ao abrir outro).
--   Quadrado: matiz (esquerda -> direita) x saturação (em cima = 100%).  Barra: brilho (em cima = 100%).
--   Campos:   H 0-359 · S 0-255 · V 0-255 · R G B 0-255 · HEX (com ou sem #, 3 ou 6 dígitos) + amostra da cor.
--=============================================================================

function Section:AddColorpicker(o)
	o = type(o) == "string" and { Name = o } or o or {}
	local window = self._window
	local color = typeof(o.Default) == "Color3" and o.Default or Color3.new(1, 1, 1)
	local h, s, v = color:ToHSV()
	local open, destroyed = false, false

	local HEAD, PANEL_H, SQUARE, BAR_W, FIELDS_X = 36, 128, 128, 16, 168
	local OPEN_H = HEAD + 8 + PANEL_H + 10
	-- três linhas de campos (26px) espalhadas por toda a altura do painel, alinhadas com o quadrado
	local ROW2 = math.floor((PANEL_H - 26) / 2)
	local ROW3 = PANEL_H - 26
	local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
	-- Imagens enviadas ao Roblox (create.roblox.com): quadrado matiz x saturação (256x256) e barra de brilho (32x256).
	local PALETTE_IMAGE = "rbxassetid://117078306072896"
	local VALUE_IMAGE   = "rbxassetid://124282613421852"

	local row = self:_row(HEAD)
	row.ClipsDescendants = true

	--// cabeçalho: nome + amostra da cor
	local head = new("TextButton", { BackgroundTransparency = 1, Text = "", Size = UDim2.new(1, 0, 0, HEAD), Parent = row })
	rowLabel(head, o.Name or "Color")
	local swatch = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(38, 18),
		BackgroundColor3 = color, BorderSizePixel = 0, Parent = head,
	}, { corner(5), new("UIStroke", { Color = Theme.Divider, Thickness = 1 }) })

	local panel = new("Frame", {
		Name = "Panel", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, HEAD + 8),
		Size = UDim2.new(1, -20, 0, PANEL_H), Parent = row,
	})

	--// quadrado: matiz (X) x saturação (Y), desenhado pela imagem PALETTE_IMAGE (matiz da esquerda para a
	-- direita, saturação 100% em cima até branco embaixo). Não é mais gerado por UIGradient.
	local square = new("ImageLabel", {
		Name = "HueSat", BackgroundTransparency = 1, BorderSizePixel = 0, Image = PALETTE_IMAGE,
		ScaleType = Enum.ScaleType.Stretch, Size = UDim2.fromOffset(SQUARE, SQUARE), Parent = panel,
	}, { corner(6) })
	local squareKnob = new("Frame", {
		Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14),
		BackgroundTransparency = 1, ZIndex = 4, Parent = square,
	}, { circle(), new("UIStroke", { Color = BLACK, Thickness = 1 }) })
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(10, 10),
		BackgroundTransparency = 1, ZIndex = 4, Parent = squareKnob,
	}, { circle(), new("UIStroke", { Color = Theme.Text, Thickness = 2 }) })
	-- Área de clique por cima de tudo (um botão "come" o clique, então a página não rola junto no toque).
	local squareHit = new("TextButton", {
		Name = "Hit", BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = square,
	})

	--// barra de brilho: a imagem VALUE_IMAGE é cinza (branco em cima, preto embaixo); o ImageColor3 a pinta
	-- com o tom atual, então fica do tom atual (em cima) até o preto (embaixo).
	local bar = new("ImageLabel", {
		Name = "Value", Position = UDim2.fromOffset(SQUARE + 8, 0), Size = UDim2.fromOffset(BAR_W, PANEL_H),
		BackgroundTransparency = 1, BorderSizePixel = 0, Image = VALUE_IMAGE, ImageColor3 = WHITE,
		ScaleType = Enum.ScaleType.Stretch, Parent = panel,
	}, { corner(6) })
	local barKnob = new("Frame", {
		Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(1, 4, 0, 4),
		BackgroundColor3 = Theme.Text, BorderSizePixel = 0, ZIndex = 2, Parent = bar,
	}, { corner(2), new("UIStroke", { Color = BLACK, Thickness = 1 }) })
	local barHit = new("TextButton", {
		Name = "Hit", BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
		Position = UDim2.fromOffset(-4, 0), Size = UDim2.new(1, 8, 1, 0), ZIndex = 5, Parent = bar,
	})

	--// campos numéricos
	local fields = new("Frame", {
		Name = "Fields", BackgroundTransparency = 1, Position = UDim2.fromOffset(FIELDS_X, 0),
		Size = UDim2.new(1, -FIELDS_X, 1, 0), Parent = panel,
	})
	local boxes = {}

	local function makeBox(parent, props)
		props.BackgroundColor3 = Theme.Track
		props.BorderSizePixel = 0
		props.ClearTextOnFocus = false
		props.Text = ""
		props.TextColor3 = Theme.Text
		props.TextSize = 13
		props.Font = Enum.Font.Gotham
		props.Parent = parent
		local focusStroke = new("UIStroke", {
			Color = Theme.Accent, Thickness = 1, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		})
		local box = new("TextBox", props, { corner(5), focusStroke })
		box.Focused:Connect(function() tween(focusStroke, { Transparency = 0 }, 0.12) end)
		box.FocusLost:Connect(function() tween(focusStroke, { Transparency = 1 }, 0.12) end)
		return box
	end

	local function makeTag(parent, text, width)
		return new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(0, width, 1, 0), Text = text, TextColor3 = Theme.SubText,
			TextSize = 12, Font = Enum.Font.GothamMedium, TextXAlignment = Enum.TextXAlignment.Left, Parent = parent,
		})
	end

	local function field(key, label, col, y)
		local cell = new("Frame", {
			BackgroundTransparency = 1, Position = UDim2.new(col / 3, 0, 0, y), Size = UDim2.new(1 / 3, -6, 0, 26), Parent = fields,
		})
		makeTag(cell, label, 14)
		boxes[key] = makeBox(cell, { Name = key, Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -16, 1, 0) })
	end
	field("H", "H", 0, 0); field("S", "S", 1, 0); field("V", "V", 2, 0)
	field("R", "R", 0, ROW2); field("G", "G", 1, ROW2); field("B", "B", 2, ROW2)

	local hexRow = new("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, ROW3), Size = UDim2.new(1, 0, 0, 26), Parent = fields,
	})
	makeTag(hexRow, "HEX", 28)
	boxes.HEX = makeBox(hexRow, { Name = "HEX", Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -(30 + 46), 1, 0) })
	local preview = new("Frame", {
		Name = "Preview", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(40, 26),
		BackgroundColor3 = color, BorderSizePixel = 0, Parent = hexRow,
	}, { corner(5), new("UIStroke", { Color = Theme.Divider, Thickness = 1 }) })

	--// estado -> tela
	local function render(exact)
		color = exact or Color3.fromHSV(h, s, v)
		swatch.BackgroundColor3 = color
		preview.BackgroundColor3 = color
		bar.ImageColor3 = Color3.fromHSV(h, s, 1)
		squareKnob.Position = UDim2.fromScale(h, 1 - s)
		barKnob.Position = UDim2.fromScale(0.5, 1 - v)

		local texts = {
			H = tostring(math.floor(h * 359 + 0.5)),
			S = tostring(math.floor(s * 255 + 0.5)),
			V = tostring(math.floor(v * 255 + 0.5)),
			R = tostring(math.floor(color.R * 255 + 0.5)),
			G = tostring(math.floor(color.G * 255 + 0.5)),
			B = tostring(math.floor(color.B * 255 + 0.5)),
			HEX = color:ToHex():upper(),
		}
		for key, text in pairs(texts) do
			local box = boxes[key]
			if not box:IsFocused() then box.Text = text end -- não sobrescreve o que está sendo digitado
		end
	end

	-- Cinza e preto não têm matiz/saturação próprios: mantém os que já estavam no quadrado.
	local function fromColor(c)
		local nh, ns, nv = c:ToHSV()
		if nv > 0 and ns > 0 then h = nh end
		if nv > 0 then s = ns end
		v = nv
		render(c)
	end

	local function changed() safeCall(o.Callback, color) end

	--// arrastar (quadrado e barra). input.Position e AbsolutePosition usam o mesmo espaço de coordenadas.
	-- As conexões globais só existem enquanto o arrasto dura.
	local dragging, dragConns -- dragging: "square", "bar" ou nil
	local function endDrag()
		if not dragging then return end
		dragging = nil
		for _, c in ipairs(dragConns or {}) do c:Disconnect() end
		dragConns = nil
		window:_lockScroll(false)
	end
	local function updateFrom(pos)
		if dragging == "square" then
			local p, size = square.AbsolutePosition, square.AbsoluteSize
			h = math.clamp((pos.X - p.X) / math.max(size.X, 1), 0, 1)
			s = 1 - math.clamp((pos.Y - p.Y) / math.max(size.Y, 1), 0, 1)
		elseif dragging == "bar" then
			local p, size = bar.AbsolutePosition, bar.AbsoluteSize
			v = 1 - math.clamp((pos.Y - p.Y) / math.max(size.Y, 1), 0, 1)
		else
			return
		end
		render()
		changed()
	end
	local function beginDrag(kind, input)
		if dragging or not isClick(input) then return end
		dragging = kind
		window:_lockScroll(true)
		updateFrom(input.Position)
		dragConns = {
			UserInputService.InputChanged:Connect(function(i)
				if window._destroyed or destroyed then endDrag() return end
				if i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch then
					updateFrom(i.Position)
				end
			end),
			UserInputService.InputEnded:Connect(function(i)
				if isClick(i) then endDrag() end
			end),
		}
	end
	squareHit.InputBegan:Connect(function(i) beginDrag("square", i) end)
	barHit.InputBegan:Connect(function(i) beginDrag("bar", i) end)

	--// digitar nos campos
	local function commitHSV(key)
		local n = tonumber(boxes[key].Text)
		if not n then render(color) return end -- texto inválido: volta ao valor atual
		if key == "H" then h = math.clamp(n, 0, 359) / 359
		elseif key == "S" then s = math.clamp(n, 0, 255) / 255
		else v = math.clamp(n, 0, 255) / 255 end
		render()
		changed()
	end
	local function commitRGB(key)
		local n = tonumber(boxes[key].Text)
		if not n then render(color) return end
		n = math.clamp(n, 0, 255) / 255
		local r, g, b = color.R, color.G, color.B
		if key == "R" then r = n elseif key == "G" then g = n else b = n end
		fromColor(Color3.new(r, g, b))
		changed()
	end
	for _, key in ipairs({ "H", "S", "V" }) do
		boxes[key].FocusLost:Connect(function() commitHSV(key) end)
	end
	for _, key in ipairs({ "R", "G", "B" }) do
		boxes[key].FocusLost:Connect(function() commitRGB(key) end)
	end
	boxes.HEX.FocusLost:Connect(function()
		local text = (boxes.HEX.Text:gsub("%s+", ""))
		local ok, parsed = pcall(Color3.fromHex, text)
		if ok and typeof(parsed) == "Color3" then
			fromColor(parsed)
			changed()
		else
			render(color)
		end
	end)

	--// abrir / fechar
	local popup = { row = row, autoClose = false, isOpen = function() return open end }
	local function setOpen(state)
		state = state and true or false
		if state == open or destroyed then return end
		if state then
			window:_popupOpening(popup)
		else
			endDrag()
		end
		open = state
		tween(row, { Size = UDim2.new(1, 0, 0, open and OPEN_H or HEAD) }, 0.2)
		if state then safeCall(o.OnOpen) else safeCall(o.OnClose) end
	end
	popup.close = function() setOpen(false) end
	window:_registerPopup(popup)

	local obj = { Instance = row }
	function obj:Get() return color end
	function obj:Set(c, silent)
		if typeof(c) ~= "Color3" then return end
		fromColor(c)
		if not silent then changed() end
	end
	obj.GetColor, obj.SetColor = obj.Get, obj.Set
	function obj:SetOpen(state) setOpen(state) end
	function obj:IsOpen() return open end
	function obj:Start() setOpen(true) end
	function obj:Destroy()
		if destroyed then return end
		endDrag()
		destroyed = true
		window:_unregisterPopup(popup)
		row:Destroy()
	end

	head.MouseButton1Click:Connect(function() setOpen(not open) end)

	render(color)
	return obj
end

--=============================================================================
-- Gallery: grade de previews carregadas com getcustomasset / rbxassetid
--
--   Section:AddGallery({
--       Name        = "M9",                       -- (opcional) usado só para identificar
--       Folder      = "CycleWare/Library/Textures/M9"   -- pasta da workspace (string ou lista de pastas)
--       Items       = { "CW/img/a.png", 123456, { Name = "Fancy", Image = "rbxassetid://123" } },
--       Extensions  = { "png", "jpg", "jpeg" },   -- filtro de extensão para Folder
--       Columns     = 4,                          -- colunas
--       Aspect      = 1,                          -- altura/largura da miniatura
--       MaxHeight   = 260,                        -- se definido, a grade rola internamente
--       LazyLoad    = true,                       -- só carrega as miniaturas quando a galeria ficar visível
--       Default     = "nome ou caminho",          -- seleção inicial
--       AllowDeselect = false,                    -- clicar de novo remove a seleção
--       Callback    = function(item) end,         -- item = { Name, Path, Asset }  (nil se desmarcou)
--   })
--   Retorno: :Get()  :Set(nomeOuCaminho, silent)  :Refresh()  :SetItems(lista)  :Clear()
--=============================================================================
function Section:AddGallery(o)
	o = o or {}
	local columns  = math.max(o.Columns or 4, 1)
	local aspect   = o.Aspect or 1
	local maxHeight = o.MaxHeight
	local PAD = 8
	local container
	local entries, selected = {}, nil
	local firstBuild = true
	local lazy = o.LazyLoad == true
	local started = not lazy -- with LazyLoad, thumbnails load only once the gallery is actually visible

	local function isShown()
		local inst = container
		while inst and not inst:IsA("LayerCollector") do
			if inst:IsA("GuiObject") and not inst.Visible then return false end
			inst = inst.Parent
		end
		return inst ~= nil
	end

	container = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_next(), Parent = self._body,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })

	--// barra superior: busca + contador + atualizar
	local hasFolder = o.Folder ~= nil
	local bar = new("Frame", {
		LayoutOrder = 1, BackgroundColor3 = Theme.Item, BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 32), Parent = container,
	}, { corner(6) })
	local search = new("TextBox", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, hasFolder and -148 or -76, 1, 0), Text = "", PlaceholderText = "Search...",
		PlaceholderColor3 = Theme.SubText, TextColor3 = Theme.Text, TextSize = 14, Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, Parent = bar,
	})
	local countLbl = new("TextLabel", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, hasFolder and -74 or -12, 0.5, 0), Size = UDim2.fromOffset(56, 20),
		Text = "0", TextColor3 = Theme.SubText, TextSize = 13, Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Right, Parent = bar,
	})
	local refreshBtn
	if hasFolder then
		refreshBtn = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -6, 0.5, 0), Size = UDim2.fromOffset(62, 22),
			BackgroundColor3 = Theme.Track, BorderSizePixel = 0, AutoButtonColor = false, Text = "Refresh",
			TextColor3 = Theme.Text, TextSize = 12, Font = Enum.Font.GothamMedium, Parent = bar,
		}, { corner(5) })
		refreshBtn.MouseEnter:Connect(function() tween(refreshBtn, { BackgroundColor3 = Theme.Header }) end)
		refreshBtn.MouseLeave:Connect(function() tween(refreshBtn, { BackgroundColor3 = Theme.Track }) end)
	end

	--// grade
	local scroller = new("ScrollingFrame", {
		LayoutOrder = 2, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
		CanvasSize = UDim2.new(), ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Divider,
		ScrollingDirection = Enum.ScrollingDirection.Y, ScrollingEnabled = false, Parent = container,
	}, { new("UIPadding", {
		PaddingTop = UDim.new(0, 3), PaddingBottom = UDim.new(0, 3),
		PaddingLeft = UDim.new(0, 3), PaddingRight = UDim.new(0, 3),
	}) })
	local grid = new("UIGridLayout", {
		CellPadding = UDim2.fromOffset(PAD, PAD), CellSize = UDim2.fromOffset(90, 118),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = scroller,
	})
	local emptyLbl = new("TextLabel", {
		LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), Visible = false,
		Text = "No images found", TextColor3 = Theme.SubText, TextSize = 13, Font = Enum.Font.Gotham, Parent = container,
	})

	local function relayout()
		local w = scroller.AbsoluteSize.X - 6 - (maxHeight and 4 or 0)
		if w > 0 then
			local cw = math.floor((w - (columns - 1) * PAD) / columns)
			grid.CellSize = UDim2.fromOffset(cw, math.floor(cw * aspect) + 28)
		end
		local h = grid.AbsoluteContentSize.Y + 6
		scroller.CanvasSize = UDim2.fromOffset(0, h)
		scroller.Size = UDim2.new(1, 0, 0, maxHeight and math.min(h, maxHeight) or h)
		scroller.ScrollingEnabled = maxHeight ~= nil and h > maxHeight
	end
	grid:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(relayout)
	scroller:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	--// coleta de itens (pastas + lista manual)
	local function collect()
		local list = {}
		local extSet = {}
		for _, e in ipairs(o.Extensions or { "png", "jpg", "jpeg" }) do extSet[e:lower()] = true end

		local folders = type(o.Folder) == "table" and o.Folder or (o.Folder and { o.Folder }) or {}
		for _, folder in ipairs(folders) do
			if listfiles and isfolder and isfolder(folder) then
				local ok, files = pcall(listfiles, folder)
				if ok and type(files) == "table" then
					table.sort(files)
					for _, f in ipairs(files) do
						local path = (f:gsub("\\", "/"))
						local fname = path:match("[^/]+$") or path
						local ext = fname:match("%.(%w+)$")
						if ext and extSet[ext:lower()] then
							table.insert(list, { Name = (fname:gsub("%.%w+$", "")), Path = path })
						end
					end
				end
			elseif not (listfiles and isfolder) then
				warnOnce("listfiles/isfolder indisponível: Folder ignorado")
			else
				warnOnce("pasta não encontrada na workspace: '" .. tostring(folder) .. "'")
			end
		end

		for _, e in ipairs(o.Items or {}) do
			if type(e) == "table" then
				local src = e.Image or e.Path
				table.insert(list, { Name = e.Name or tostring(src), Path = src })
			else
				local name = type(e) == "string" and (e:match("[^/\\]+$") or e) or ("ID " .. tostring(e))
				table.insert(list, { Name = (tostring(name):gsub("%.%w+$", "")), Path = e })
			end
		end
		return list
	end

	--// seleção visual
	local function visual(e, on)
		tween(e.stroke, { Color = on and Theme.Accent or Theme.Item }, 0.15)
		tween(e.cell, { BackgroundColor3 = on and Theme.ItemSelected or Theme.Item }, 0.15)
		tween(e.name, { TextColor3 = on and Theme.Text or Theme.SubText }, 0.15)
		e.badge.Visible = on
	end

	local function select(e, silent)
		if selected == e then
			if e and o.AllowDeselect then
				visual(e, false)
				selected = nil
				if not silent then safeCall(o.Callback, nil) end
			end
			return
		end
		if selected then visual(selected, false) end
		selected = e
		if e then
			visual(e, true)
			e.item.Asset = e.item.Asset or resolveAsset(e.item.Path)
			if not silent then safeCall(o.Callback, e.item) end
		end
	end

	--// célula (miniatura)
	local function makeCell(item, index)
		local e = { item = item }
		local cell = new("TextButton", {
			Name = item.Name, LayoutOrder = index, AutoButtonColor = false, Text = "",
			BackgroundColor3 = Theme.Item, BorderSizePixel = 0, Parent = scroller,
		}, { corner(8) })
		local stroke = new("UIStroke", {
			Color = Theme.Item, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = cell,
		})
		local thumb = new("Frame", {
			Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -34), BackgroundColor3 = Theme.Track,
			BorderSizePixel = 0, ClipsDescendants = true, Parent = cell,
		}, { corner(6) })
		local img = new("ImageLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ImageTransparency = 1,
			ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Parent = thumb,
		}, { new("UIScale", { Scale = 1 }) })
		local imgScale = img:FindFirstChildOfClass("UIScale")
		local failLbl = new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "?", Visible = false,
			TextColor3 = Theme.SubText, TextSize = 22, Font = Enum.Font.GothamBold, Parent = thumb,
		})
		local name = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 6, 1, -24), Size = UDim2.new(1, -12, 0, 18),
			Text = item.Name, TextColor3 = Theme.SubText, TextSize = 12, Font = Enum.Font.GothamMedium,
			TextTruncate = Enum.TextTruncate.AtEnd, Parent = cell,
		})
		-- selo de seleção (check desenhado)
		local badge = new("Frame", {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = Theme.Accent, BorderSizePixel = 0, Visible = false, ZIndex = 5, Parent = cell,
		}, { circle() })
		for _, a in ipairs({ { 6, 11, 4.5, 45 }, { 10.5, 9.5, 9, -45 } }) do
			new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(a[1], a[2]),
				Size = UDim2.fromOffset(a[3], 2), Rotation = a[4], BackgroundColor3 = Theme.Text,
				BorderSizePixel = 0, ZIndex = 6, Parent = badge,
			}, { corner(1) })
		end

		e.cell, e.stroke, e.name, e.badge = cell, stroke, name, badge

		-- placeholder pulsando até a imagem carregar (só começa quando o carregamento começa)
		local pulse = TweenService:Create(thumb, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.65 })
		local function onLoaded(asset)
			pcall(function()
				pulse:Cancel()
				thumb.BackgroundTransparency = 0
				if asset then
					item.Asset = asset
					img.Image = asset
					tween(img, { ImageTransparency = 0 }, 0.25)
				else
					failLbl.Visible = true
				end
			end)
		end
		e.load = function()
			if e.loadStarted then return end
			e.loadStarted = true
			local cachedAsset = type(item.Path) == "string" and assetCache[item.Path]
			if cachedAsset then
				onLoaded(cachedAsset)
			else
				pulse:Play()
				enqueueLoad(item.Path, onLoaded)
			end
		end
		if started then e.load() end

		-- interação
		cell.MouseEnter:Connect(function()
			tween(imgScale, { Scale = 1.07 }, 0.18)
			if selected ~= e then
				tween(cell, { BackgroundColor3 = Theme.ItemHover }, 0.12)
				tween(stroke, { Color = Theme.Divider }, 0.12)
			end
		end)
		cell.MouseLeave:Connect(function()
			tween(imgScale, { Scale = 1 }, 0.18)
			if selected ~= e then
				tween(cell, { BackgroundColor3 = Theme.Item }, 0.12)
				tween(stroke, { Color = Theme.Item }, 0.12)
			end
		end)
		cell.MouseButton1Click:Connect(function() select(e) end)
		return e
	end

	--// busca
	local function applyFilter()
		local q = search.Text:lower()
		local shown = 0
		for _, e in ipairs(entries) do
			local ok = q == "" or e.item.Name:lower():find(q, 1, true) ~= nil
			e.cell.Visible = ok
			if ok then shown += 1 end
		end
		countLbl.Text = (q == "") and tostring(#entries) or (shown .. "/" .. #entries)
		emptyLbl.Visible = shown == 0
		scroller.Visible = shown > 0
	end
	search:GetPropertyChangedSignal("Text"):Connect(applyFilter)

	--// (re)construção
	local obj = { Instance = container }

	local function build()
		local prev = selected and selected.item.Path
		for _, e in ipairs(entries) do
			if type(e.item.Path) == "string" then assetCache[e.item.Path] = nil end
			e.cell:Destroy()
		end
		entries, selected = {}, nil

		for i, item in ipairs(collect()) do entries[i] = makeCell(item, i) end

		local target = prev
		if target == nil and firstBuild then target = o.Default end
		firstBuild = false
		if target ~= nil then
			for _, e in ipairs(entries) do
				if e.item.Name == target or e.item.Path == target then select(e, true) break end
			end
		end
		applyFilter()
		relayout()
	end

	function obj:Get() return selected and selected.item or nil end
	function obj:Set(v, silent)
		if v == nil then
			if selected then visual(selected, false) selected = nil end
			return
		end
		for _, e in ipairs(entries) do
			if e.item.Name == v or e.item.Path == v then select(e, silent) return end
		end
	end
	function obj:Clear() obj:Set(nil) end
	function obj:Refresh() build() end
	function obj:SetItems(list) o.Items = list build() end

	if refreshBtn then refreshBtn.MouseButton1Click:Connect(build) end
	build()

	if lazy then
		-- Um único vigia por janela (em vez de um loop por galeria); devolve true quando não precisa mais.
		self._window:_registerLazy(function()
			if started or not container.Parent then return true end
			if isShown() then
				started = true
				for _, e in ipairs(entries) do e.load() end
				return true
			end
			return false
		end)
	end
	return obj
end

--=============================================================================
-- Seções colapsáveis (aninháveis)
--=============================================================================
local function createSection(window, parentContainer, order, o, nested)
	o = type(o) == "string" and { Name = o } or o or {}
	local sec = setmetatable({ _window = window, Name = o.Name or "Section", _n = 0 }, Section)
	local H = nested and 36 or 42

	local holder = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order, Parent = parentContainer,
	}, { new("UIListLayout", { Padding = UDim.new(0, nested and 3 or 4), SortOrder = Enum.SortOrder.LayoutOrder }) })

	local header = new("TextButton", {
		LayoutOrder = 1, BackgroundColor3 = nested and Theme.Item or Theme.Header, BorderSizePixel = 0,
		AutoButtonColor = false, Size = UDim2.new(1, 0, 0, H), Text = "", Parent = holder,
	}, { corner(nested and 6 or 8) })

	local textX = nested and 14 or 16
	if o.Icon then
		makeIcon(header, o.Icon, nested and 20 or 24, UDim2.fromOffset(nested and 22 or 27, H / 2))
		textX = nested and 44 or 59
	end
	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(textX, 0), Size = UDim2.new(1, -(textX + 40), 1, 0),
		Text = sec.Name, TextColor3 = Theme.Text, TextSize = nested and 15 or 18, Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	})
	local chev = makeChevron(header, UDim2.new(1, nested and -22 or -27, 0.5, 0), nested and 0.8 or 1)

	local base, hover = (nested and Theme.Item or Theme.Header), (nested and Theme.ItemHover or Theme.HeaderHover)
	header.MouseEnter:Connect(function() tween(header, { BackgroundColor3 = hover }) end)
	header.MouseLeave:Connect(function() tween(header, { BackgroundColor3 = base }) end)

	local body = new("Frame", {
		LayoutOrder = 2, BackgroundColor3 = nested and Theme.SubBody or Theme.Body, BorderSizePixel = 0,
		ClipsDescendants = true, Size = UDim2.new(1, 0, 0, 0), Visible = false, Parent = holder,
	}, { corner(nested and 6 or 8) })
	local padV, padH = nested and 6 or 8, nested and 6 or 8
	new("UIPadding", {
		PaddingTop = UDim.new(0, padV), PaddingBottom = UDim.new(0, padV),
		PaddingLeft = UDim.new(0, padH), PaddingRight = UDim.new(0, padH), Parent = body,
	})
	local layout = new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = body })
	sec._body = body

	local open, animating, token = false, false, 0
	local function targetHeight() return layout.AbsoluteContentSize.Y + padV * 2 end

	function sec:SetOpen(state)
		open = state and true or false
		token += 1
		local mine = token
		animating = true
		tween(chev, { Rotation = open and 180 or 0 }, 0.2)
		if open then body.Visible = true end
		local tw = tween(body, { Size = UDim2.new(1, 0, 0, open and targetHeight() or 0) }, 0.2)
		tw.Completed:Connect(function()
			if mine ~= token then return end
			animating = false
			if open then
				body.Size = UDim2.new(1, 0, 0, targetHeight())
			else
				body.Visible = false
			end
		end)
	end
	function sec:Toggle() sec:SetOpen(not open) end
	function sec:IsOpen() return open end

	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
		if open and not animating then body.Size = UDim2.new(1, 0, 0, targetHeight()) end
	end)
	header.MouseButton1Click:Connect(function() sec:Toggle() end)
	if o.Open then task.defer(function() sec:SetOpen(true) end) end

	return sec
end

-- Subseção dentro de uma seção (pode aninhar quantas quiser)
function Section:AddSubSection(o)
	return createSection(self._window, self._body, self:_next(), o, true)
end

--// Tab ------------------------------------------------------------------------
function Tab:AddSection(o)
	return createSection(self._window, self._page, self:_next(), o, false)
end

--// Window ----------------------------------------------------------------------
function Window:_connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(self._conns, c)
	return c
end

-- Trava o scroll da aba enquanto um slider/colorpicker é arrastado (no toque, arrastar rolaria a página).
function Window:_lockScroll(lock)
	self._scrollLocks = math.max(0, self._scrollLocks + (lock and 1 or -1))
	local tab = self._selected
	if tab then tab._page.ScrollingEnabled = self._scrollLocks == 0 end
end

-- Popups (dropdown, colorpicker): abrir um fecha os outros; os com autoClose fecham ao clicar fora.
function Window:_registerPopup(p) table.insert(self._popups, p) end
function Window:_unregisterPopup(p)
	local index = table.find(self._popups, p)
	if index then table.remove(self._popups, index) end
end
function Window:_popupOpening(popup)
	for _, p in ipairs(self._popups) do
		if p ~= popup and p.isOpen() then pcall(p.close) end
	end
end

-- Vigia único de carregamento preguiçoso das galerias.
function Window:_registerLazy(fn)
	table.insert(self._lazy, fn)
	if self._lazyRunning then return end
	self._lazyRunning = true
	task.spawn(function()
		while #self._lazy > 0 and not self._destroyed do
			for i = #self._lazy, 1, -1 do
				local ok, done = pcall(self._lazy[i])
				if not ok or done then table.remove(self._lazy, i) end
			end
			if #self._lazy > 0 then task.wait(0.3) end
		end
		self._lazyRunning = false
	end)
end

function Window:SelectTab(tab)
	for _, t in ipairs(self._tabs) do
		local on = (t == tab)
		t._page.Visible = on
		t._page.ScrollingEnabled = self._scrollLocks == 0
		tween(t._btn, { BackgroundTransparency = on and 0 or 1, BackgroundColor3 = Theme.Selected }, 0.18)
	end
	self._selected = tab
end

function Window:AddTab(o)
	o = type(o) == "string" and { Name = o } or o or {}
	local tab = setmetatable({ _window = self, Name = o.Name or "Tab", _n = 0 }, Tab)

	local btn = new("TextButton", {
		BackgroundColor3 = Theme.Selected, BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false,
		Size = UDim2.new(1, 0, 0, 52), Text = "", LayoutOrder = #self._tabs, Parent = self._tabList,
	})
	local textX = 18
	if o.Icon then
		makeIcon(btn, o.Icon, 26, UDim2.fromOffset(31, 26))
		textX = 60
	end
	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(textX, 0), Size = UDim2.new(1, -(textX + 6), 1, 0),
		Text = tab.Name, TextColor3 = Theme.Text, TextSize = 16, Font = Enum.Font.GothamMedium,
		TextXAlignment = Enum.TextXAlignment.Left, Parent = btn,
	})
	btn.MouseEnter:Connect(function()
		if self._selected ~= tab then tween(btn, { BackgroundColor3 = Theme.TabHover, BackgroundTransparency = 0.8 }) end
	end)
	btn.MouseLeave:Connect(function()
		if self._selected ~= tab then tween(btn, { BackgroundTransparency = 1 }) end
	end)

	local page = new("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Visible = false,
		ScrollBarThickness = 3, ScrollBarImageColor3 = Theme.Divider, CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Parent = self._content,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }),
		new("UIPadding", {
			PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14),
			PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
		}),
	})

	tab._btn, tab._page = btn, page
	table.insert(self._tabs, tab)
	btn.MouseButton1Click:Connect(function() self:SelectTab(tab) end)
	if #self._tabs == 1 then self:SelectTab(tab) end
	return tab
end

function Window:SetVisible(v) self._shell.Visible = v end
function Window:Toggle() self._shell.Visible = not self._shell.Visible end

function Window:Destroy()
	self._destroyed = true
	for _, c in ipairs(self._conns) do c:Disconnect() end
	table.clear(self._conns)
	self._gui:Destroy()
end

--[[
    CW:CreateWindow({
        Title      = "CW",                 -- texto do logo (se Logo não for informado)
        Logo       = "CW/logo.png",        -- (opcional) caminho da workspace ou ID
        Icons      = { Settings = "...", Discord = "...", Info = "..." },  -- botões do rodapé (caminho/ID)
        Discord    = "https://discord.gg/xxx",  -- copiado ao clicar no botão do Discord
        OnSettings = function() end, OnDiscord = function(link) end, OnInfo = function() end,
        ToggleKey  = Enum.KeyCode.RightShift,   -- false para desativar
        Size       = UDim2.fromOffset(712, 500),
    })

    O rodapé só aparece se algum botão tiver ícone ou ação; sem nenhum, nem a linha divisória é desenhada.
    A janela é um Frame comum com cores lisas (nada de CanvasGroup nem de gradiente nos fundos).
]]
function CW:CreateWindow(cfg)
	cfg = cfg or {}
	local self = setmetatable({
		_tabs = {}, _conns = {}, _popups = {}, _lazy = {}, _scrollLocks = 0,
	}, Window)

	local gui = new("ScreenGui", {
		Name = cfg.Name or "CW_UI", ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999999,
	})
	if syn and syn.protect_gui then pcall(syn.protect_gui, gui) end
	gui.Parent = (gethui and gethui()) or CoreGui
	self._gui = gui

	local RADIUS, SIDEBAR_W, LOGO_H = 8, 169, 66

	-- Active = true: clicar na janela não "atravessa" para o jogo (não atira).
	local window = new("Frame", {
		Name = "Window", Active = true, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = cfg.Size or UDim2.fromOffset(712, 500), BackgroundColor3 = Theme.Content,
		BorderSizePixel = 0, Parent = gui,
	}, { corner(RADIUS) })
	local shell = window
	self._shell = window

	local content = new("Frame", {
		Name = "Content", BackgroundTransparency = 1, BorderSizePixel = 0,
		Position = UDim2.fromOffset(SIDEBAR_W, 0), Size = UDim2.new(1, -SIDEBAR_W, 1, 0), Parent = window,
	})
	self._content = content

	-- Barra lateral: cantos arredondados só à esquerda (o lado direito é "quadrado" por uma faixa da mesma cor).
	local sidebar = new("Frame", {
		Name = "Sidebar", Size = UDim2.new(0, SIDEBAR_W, 1, 0), BackgroundColor3 = Theme.Sidebar,
		BorderSizePixel = 0, Parent = window,
	}, { corner(RADIUS) })
	new("Frame", {
		Name = "SquareRight", Position = UDim2.new(1, -RADIUS * 2, 0, 0), Size = UDim2.new(0, RADIUS * 2, 1, 0),
		BackgroundColor3 = Theme.Sidebar, BorderSizePixel = 0, Parent = sidebar,
	})

	-- Faixa do logo: só o canto superior esquerdo é arredondado.
	local logo = new("Frame", {
		Name = "Logo", Size = UDim2.new(1, 0, 0, LOGO_H), BackgroundColor3 = Theme.Logo,
		BorderSizePixel = 0, Parent = sidebar,
	}, { corner(RADIUS) })
	new("Frame", {
		Name = "SquareBottom", Position = UDim2.new(0, 0, 1, -RADIUS * 2), Size = UDim2.new(1, 0, 0, RADIUS * 2),
		BackgroundColor3 = Theme.Logo, BorderSizePixel = 0, Parent = logo,
	})
	new("Frame", {
		Name = "SquareRight", Position = UDim2.new(1, -RADIUS * 2, 0, 0), Size = UDim2.new(0, RADIUS * 2, 1, 0),
		BackgroundColor3 = Theme.Logo, BorderSizePixel = 0, Parent = logo,
	})

	local logoAsset = resolveAsset(cfg.Logo)
	if logoAsset then
		new("ImageLabel", {
			BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(98, 40), Image = logoAsset, ScaleType = Enum.ScaleType.Fit, Parent = logo,
		})
	else
		new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = cfg.Title or "CW",
			TextColor3 = Theme.Text, TextSize = 52, Font = Enum.Font.GothamBlack, Parent = logo,
		})
	end

	-- Rodapé: só os botões que têm ícone ou ação.
	local footerIcons = cfg.Icons or {}
	local footer = {}
	if footerIcons.Settings or cfg.OnSettings then
		table.insert(footer, { icon = footerIcons.Settings, glyph = "S", cb = cfg.OnSettings })
	end
	if footerIcons.Discord or cfg.Discord or cfg.OnDiscord then
		table.insert(footer, { icon = footerIcons.Discord, glyph = "D", cb = function()
			if cfg.Discord and setclipboard then pcall(setclipboard, cfg.Discord) end
			safeCall(cfg.OnDiscord, cfg.Discord)
		end })
	end
	if footerIcons.Info or cfg.OnInfo then
		table.insert(footer, { icon = footerIcons.Info, glyph = "i", cb = cfg.OnInfo })
	end
	local hasFooter = #footer > 0

	self._tabList = new("ScrollingFrame", {
		Name = "Tabs", BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(0, LOGO_H),
		Size = UDim2.new(1, 0, 1, -(LOGO_H + (hasFooter and 74 or 8))), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y, Parent = sidebar,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 2.5), SortOrder = Enum.SortOrder.LayoutOrder }),
		new("UIPadding", { PaddingTop = UDim.new(0, 4) }),
	})

	if hasFooter then
		new("Frame", {
			Name = "Divider", Position = UDim2.new(0, 12, 1, -76), Size = UDim2.new(1, -24, 0, 1),
			BackgroundColor3 = Theme.Divider, BorderSizePixel = 0, Parent = sidebar,
		})
		for index, item in ipairs(footer) do
			local x = (index - (#footer + 1) / 2) * 50
			local b = new("TextButton", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, x, 1, -41.5), Size = UDim2.fromOffset(36, 36),
				BackgroundColor3 = Theme.Text, BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Parent = sidebar,
			}, { circle(), new("UIStroke", { Color = Theme.Text, Thickness = 1.6 }) })
			if item.icon then
				makeIcon(b, item.icon, 20, UDim2.fromScale(0.5, 0.5))
			else
				b.Text = item.glyph
				b.TextColor3 = Theme.Text
				b.TextSize = 16
				b.Font = Enum.Font.GothamBold
			end
			b.MouseEnter:Connect(function() tween(b, { BackgroundTransparency = 0.85 }) end)
			b.MouseLeave:Connect(function() tween(b, { BackgroundTransparency = 1 }) end)
			b.MouseButton1Click:Connect(function() safeCall(item.cb) end)
		end
	end

	-- arrastar pelo logo
	local dragging, dragStart, startPos
	logo.InputBegan:Connect(function(i)
		if isClick(i) then
			dragging, dragStart, startPos = true, i.Position, shell.Position
			i.Changed:Connect(function() if i.UserInputState == Enum.UserInputState.End then dragging = false end end)
		end
	end)
	self:_connect(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			shell.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)

	-- clique fora de um dropdown aberto fecha ele
	self:_connect(UserInputService.InputBegan, function(i)
		if not isClick(i) then return end
		for _, p in ipairs(self._popups) do
			if p.autoClose and p.isOpen() and not insideGui(p.row, i.Position) then pcall(p.close) end
		end
	end)

	local key = cfg.ToggleKey == nil and Enum.KeyCode.RightShift or cfg.ToggleKey
	if key then
		self:_connect(UserInputService.InputBegan, function(i, gpe)
			if not gpe and i.KeyCode == key then self:Toggle() end
		end)
	end

	return self
end

return CW
