--[[
    CW UI Library  v3.0

    VISUAL
      Fundo escuro de concreto com um único destaque: o laranja do uniforme de detento do Prison Life.
      Laranja sempre significa "ligado / selecionado / ativo". Títulos em Oswald (letreiro de prisão),
      textos em Builder Sans (a fonte do próprio Roblox, legível em tamanho pequeno).
      Tudo que se toca tem pelo menos 44 px de altura (celular). Com "Reduzir movimento" do Roblox, nada anima.

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
        A própria Tab também aceita elementos direto (sem seção).
        Elementos: Label, Button, Toggle, Slider, Textbox, InputRow, Dropdown, Colorpicker, Gallery, SlotBoard

    PERSONALIZAÇÃO
        CW.SetTheme({ Accent, Text, Background, Sidebar, Panel = Color3, BackgroundTransparency, PanelTransparency = 0..1 })
        CW.ResetTheme(), CW.GetTheme(); Window:SetBackgroundImage(id ou caminho), Window:SetBackgroundImageTransparency(0..1)
]]

local CW = { Version = "3.0.0" }

--// Services ---------------------------------------------------------------
local cloneref = cloneref or function(x) return x end
local TweenService     = cloneref(game:GetService("TweenService"))
local UserInputService = cloneref(game:GetService("UserInputService"))
local GuiService       = cloneref(game:GetService("GuiService"))
local CoreGui          = cloneref(game:GetService("CoreGui"))

--// Tema ---------------------------------------------------------------------
-- A pessoa escolhe 5 cores (Palette); os outros tons derivam delas para o tema continuar coerente.
-- Padrão com contraste conferido (WCAG AA): Text e SubText passam de 5:1 em todos os fundos.
local DEFAULT_PALETTE = {
	Accent = Color3.fromRGB(255, 128, 32),    -- laranja do uniforme de detento: ligado / selecionado / ativo
	Text = Color3.fromRGB(240, 240, 242),
	Background = Color3.fromRGB(21, 21, 24),
	Sidebar = Color3.fromRGB(14, 14, 16),
	Panel = Color3.fromRGB(36, 36, 41),
	BackgroundTransparency = 0,                -- janela e barra lateral
	PanelTransparency = 0,                     -- cabeçalhos, corpos das seções e linhas
}
local Palette = table.clone(DEFAULT_PALETTE)
local Theme = {}
CW.Theme = Theme

local WHITE, BLACK = Color3.new(1, 1, 1), Color3.new(0, 0, 0)
local function luminance(c)
	local function channel(v) return v <= 0.03928 and v / 12.92 or ((v + 0.055) / 1.055) ^ 2.4 end
	return 0.2126 * channel(c.R) + 0.7152 * channel(c.G) + 0.0722 * channel(c.B)
end
local function contrast(a, b)
	local la, lb = luminance(a), luminance(b)
	return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05)
end

local function derive()
	local panel, accent = Palette.Panel, Palette.Accent
	Theme.Accent, Theme.Text = accent, Palette.Text
	Theme.Content, Theme.Sidebar = Palette.Background, Palette.Sidebar
	Theme.TabHover = Palette.Sidebar:Lerp(WHITE, 0.06)
	Theme.Item, Theme.ItemHover = panel, panel:Lerp(WHITE, 0.05)
	Theme.Header, Theme.HeaderHover = panel:Lerp(BLACK, 0.11), panel:Lerp(WHITE, 0.025)
	Theme.Body, Theme.SubBody = panel:Lerp(BLACK, 0.28), panel:Lerp(BLACK, 0.39)
	Theme.Track, Theme.Divider = panel:Lerp(BLACK, 0.58), panel:Lerp(WHITE, 0.1)
	Theme.ItemSelected = accent:Lerp(Theme.Track, 0.8)
	Theme.SubText = Palette.Text:Lerp(panel, 0.33)
	-- Texto sobre o destaque: escuro ou claro, o que for mais legível na cor escolhida.
	local dark, light = Color3.fromRGB(18, 13, 8), Color3.fromRGB(245, 245, 245)
	Theme.OnAccent = contrast(accent, dark) >= contrast(accent, light) and dark or light
end
derive()

local Fonts = {
	Title  = Font.new("rbxasset://fonts/families/Oswald.json", Enum.FontWeight.Bold),
	Body   = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Regular),
	Medium = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	Bold   = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
}

local ROW_H  = 44 -- altura de toda linha clicável (alvo de toque confortável no celular)
local RADIUS = 4  -- cantos quase retos: placas de metal, não pílulas

--// Helpers ------------------------------------------------------------------
-- Cores são passadas pelo papel ("Item", "Accent"...), não pelo valor. Cada instância lembra o papel de
-- cada propriedade, e CW.SetTheme repinta tudo na hora.
local COLOR_PROPS = {
	BackgroundColor3 = true, TextColor3 = true, PlaceholderColor3 = true,
	ImageColor3 = true, ScrollBarImageColor3 = true, Color = true,
}
local painted = setmetatable({}, { __mode = "k" })  -- instância -> { propriedade = papel }
local surfaces = setmetatable({}, { __mode = "k" }) -- instância -> "Background" | "Panel" (transparência)

local function remember(inst, prop, role)
	local roles = painted[inst]
	if not roles then roles = {} painted[inst] = roles end
	roles[prop] = role
end

local function paint(inst, prop, role)
	remember(inst, prop, role)
	inst[prop] = Theme[role]
end

-- Surface = "Background" | "Panel": o fundo segue a transparência escolhida para essa camada.
local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		elseif k == "Surface" then
			surfaces[inst] = v
			inst.BackgroundTransparency = Palette[v .. "Transparency"]
		elseif COLOR_PROPS[k] and type(v) == "string" then
			paint(inst, k, v)
		else
			inst[k] = v
		end
	end
	for _, c in ipairs(children or {}) do c.Parent = inst end
	inst.Parent = parent
	return inst
end

local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function circle()  return new("UICorner", { CornerRadius = UDim.new(1, 0) }) end

local function reducedMotion()
	local ok, on = pcall(function() return GuiService.ReducedMotionEnabled end)
	return ok and on == true
end

local function tween(inst, props, t, style)
	local goal = {}
	for k, v in pairs(props) do
		if COLOR_PROPS[k] and type(v) == "string" then
			remember(inst, k, v)
			v = Theme[v]
		end
		goal[k] = v
	end
	local time = reducedMotion() and 0 or (t or 0.15)
	local tw = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tw:Play()
	return tw
end

-- Fundo que responde ao mouse: clareia no hover e um pouco mais enquanto pressionado.
local function hoverColors(button, target, base, hover)
	target = target or button
	button.MouseEnter:Connect(function() tween(target, { BackgroundColor3 = hover }, 0.12) end)
	button.MouseLeave:Connect(function() tween(target, { BackgroundColor3 = base }, 0.12) end)
	button.MouseButton1Down:Connect(function()
		tween(target, { BackgroundColor3 = Theme[hover]:Lerp(Theme.Text, 0.08) }, 0.05)
	end)
	button.MouseButton1Up:Connect(function() tween(target, { BackgroundColor3 = hover }, 0.12) end)
end

--// Tema em tempo real ----------------------------------------------------------
-- CW.SetTheme({ Accent = Color3, Text = Color3, Background = Color3, Sidebar = Color3, Panel = Color3,
--               BackgroundTransparency = 0..1, PanelTransparency = 0..1 })
-- Só as chaves passadas mudam. CW.ResetTheme() volta ao padrão. A repintura acontece uma vez por quadro,
-- então arrastar um seletor de cor não pesa.
local repaintQueued = false
local function repaint()
	repaintQueued = false
	for inst, roles in pairs(painted) do
		for prop, role in pairs(roles) do inst[prop] = Theme[role] end
	end
	for inst, layer in pairs(surfaces) do
		inst.BackgroundTransparency = Palette[layer .. "Transparency"]
	end
end

function CW.SetTheme(changes)
	for key, value in pairs(changes or {}) do
		local default = DEFAULT_PALETTE[key]
		if default ~= nil and typeof(value) == typeof(default) then
			Palette[key] = type(value) == "number" and math.clamp(value, 0, 1) or value
		end
	end
	derive()
	if not repaintQueued then
		repaintQueued = true
		task.defer(repaint)
	end
end

function CW.ResetTheme() CW.SetTheme(DEFAULT_PALETTE) end
function CW.GetTheme() return table.clone(Palette) end

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

-- Botão compacto (Add ID, Edit, Refresh...): desenho de 30 px, área de toque da altura da linha.
local function smallButton(parent, text, width, zIndex)
	local hit = new("TextButton", {
		BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(width, ROW_H),
		ZIndex = zIndex, Parent = parent,
	})
	local face = new("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 30),
		BackgroundColor3 = "Track", BorderSizePixel = 0, Text = text, TextColor3 = "Text", TextSize = 14,
		FontFace = Fonts.Bold, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = zIndex, Parent = hit,
	}, { corner(RADIUS) })
	hoverColors(hit, face, "Track", "Header")
	return hit, face
end

-- Campo de texto: caixa de 30 px com contorno laranja no foco; o TextBox ocupa a altura da linha.
-- props: Size, Position, AnchorPoint, LayoutOrder, Text, Placeholder, TextSize, TextXAlignment
local function textInput(parent, props)
	local face = new("Frame", {
		AnchorPoint = props.AnchorPoint, Position = props.Position, Size = props.Size, LayoutOrder = props.LayoutOrder,
		BackgroundColor3 = "Track", BorderSizePixel = 0, ZIndex = props.ZIndex, Parent = parent,
	}, { corner(RADIUS) })
	local stroke = new("UIStroke", {
		Color = "Accent", Thickness = 1, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = face,
	})
	local box = new("TextBox", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, ROW_H),
		BackgroundTransparency = 1, ClearTextOnFocus = false, Text = props.Text or "",
		PlaceholderText = props.Placeholder or "", PlaceholderColor3 = "SubText", TextColor3 = "Text",
		TextSize = props.TextSize or 15, FontFace = Fonts.Body, ZIndex = props.ZIndex,
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = face,
	}, { new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) })
	box.Focused:Connect(function() tween(stroke, { Transparency = 0 }, 0.12) end)
	box.FocusLost:Connect(function() tween(stroke, { Transparency = 1 }, 0.12) end)
	return box, face
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

-- Seta desenhada (não depende de imagem). Aponta para baixo; girar 180° quando aberto.
local function makeChevron(parent, pos, scale, color)
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
			BackgroundColor3 = color or "Text", BorderSizePixel = 0, Parent = holder,
		}, { corner(1) })
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
setmetatable(Tab, { __index = Section }) -- a aba aceita elementos direto (vão para a página dela)

function Tab:_next() self._n += 1 return self._n end
function Section:_next() self._n += 1 return self._n end

--// Section: linha base -------------------------------------------------------
function Section:_row(height)
	return new("Frame", {
		Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, LayoutOrder = self:_next(),
		Size = UDim2.new(1, 0, 0, height or ROW_H), Parent = self._body,
	}, { corner(RADIUS) })
end

local function rowLabel(row, text)
	return new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(0.55, 0, 1, 0),
		Text = text, TextColor3 = "Text", TextSize = 16, FontFace = Fonts.Medium,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = row,
	})
end

-- Linha inteira clicável, com hover. Fica por baixo dos controles da linha.
local function rowHit(row)
	local hit = new("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.fromScale(1, 1), Parent = row })
	hoverColors(hit, row, "Item", "ItemHover")
	return hit
end

function Section:AddLabel(text)
	local lbl = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_next(), Text = text or "", TextColor3 = "SubText", TextSize = 14, LineHeight = 1.1,
		FontFace = Fonts.Body, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Parent = self._body,
	}, { new("UIPadding", {
		PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 4), PaddingBottom = UDim.new(0, 4),
	}) })
	return { Set = function(_, t) lbl.Text = t end, Instance = lbl }
end

function Section:AddButton(o)
	o = type(o) == "string" and { Name = o } or o
	local btn = new("TextButton", {
		Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, AutoButtonColor = false, LayoutOrder = self:_next(),
		Size = UDim2.new(1, 0, 0, ROW_H), Text = o.Name or "Button", TextColor3 = "Text",
		TextSize = 16, FontFace = Fonts.Bold, Parent = self._body,
	}, { corner(RADIUS) })
	hoverColors(btn, btn, "Item", "ItemHover")
	btn.MouseButton1Click:Connect(function() safeCall(o.Callback) end)
	return { Instance = btn, SetText = function(_, t) btn.Text = t end }
end

-- Chave em placa: desligada = trilho escuro com alça cinza; ligada = laranja com alça escura.
function Section:AddToggle(o)
	o = type(o) == "string" and { Name = o } or o
	local state = o.Default == true
	local row = self:_row()
	rowLabel(row, o.Name or "Toggle")
	local hit = rowHit(row)

	local OFF, ON = UDim2.new(0, 3, 0.5, 0), UDim2.new(1, -21, 0.5, 0)
	local sw = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -14, 0.5, 0), Size = UDim2.fromOffset(44, 24),
		BackgroundColor3 = state and "Accent" or "Track", BorderSizePixel = 0, Parent = row,
	}, { corner(RADIUS) })
	local swStroke = new("UIStroke", { Color = "Divider", Thickness = 1, Transparency = state and 1 or 0, Parent = sw })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = state and ON or OFF, Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = state and "OnAccent" or "SubText", BorderSizePixel = 0, Parent = sw,
	}, { corner(RADIUS - 1) })

	local obj = { Instance = row }
	function obj:Set(v, silent)
		state = v and true or false
		tween(sw, { BackgroundColor3 = state and "Accent" or "Track" })
		tween(swStroke, { Transparency = state and 1 or 0 })
		tween(knob, { Position = state and ON or OFF, BackgroundColor3 = state and "OnAccent" or "SubText" })
		if not silent then safeCall(o.Callback, state) end
	end
	function obj:Get() return state end

	hit.MouseButton1Click:Connect(function() obj:Set(not state) end)
	return obj
end

function Section:AddSlider(o)
	local min, max, inc = tonumber(o.Min) or 0, tonumber(o.Max) or 100, tonumber(o.Increment) or 1
	if inc <= 0 then inc = 1 end              -- a step of 0 would divide by zero
	if max < min then min, max = max, min end -- math.clamp errors when min > max
	local scale = 10 ^ math.max(decimalsOf(inc), decimalsOf(min))
	local value = min
	local row = self:_row(60)
	local nameLbl = rowLabel(row, o.Name or "Slider")
	nameLbl.Size = UDim2.new(1, -110, 0, 36)
	local hit = rowHit(row) -- a linha inteira arrasta, não só o trilho fino

	-- Valor numa caixa: mostra que dá para digitar um número exato.
	local valueBox = textInput(row, {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 6), Size = UDim2.fromOffset(72, 26),
		TextSize = 14, TextXAlignment = Enum.TextXAlignment.Right,
	})
	local track = new("Frame", {
		Position = UDim2.new(0, 14, 1, -16), Size = UDim2.new(1, -28, 0, 6),
		BackgroundColor3 = "Track", BorderSizePixel = 0, Parent = row,
	}, { corner(3) })
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = "Accent", BorderSizePixel = 0, Parent = track }, { corner(3) })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(10, 20),
		BackgroundColor3 = "Text", BorderSizePixel = 0, Parent = track,
	}, { corner(3) })
	local knobScale = new("UIScale", { Parent = knob })

	local obj = { Instance = row }
	local function snap(v)
		v = math.floor((v - min) / inc + 0.5) * inc + min
		return math.clamp(math.floor(v * scale + 0.5) / scale, min, max) -- sem ruído (0.35 e não 0.35000000000000003)
	end
	local function show(animate)
		local a = max == min and 0 or (value - min) / (max - min)
		local t = animate and 0.08 or 0 -- tempo 0 ainda passa por um tween: cancela um deslize em andamento
		tween(fill, { Size = UDim2.fromScale(a, 1) }, t)
		tween(knob, { Position = UDim2.fromScale(a, 0.5) }, t)
		if not valueBox:IsFocused() then valueBox.Text = fmt(value) .. (o.Suffix or "") end
	end
	function obj:Set(v, silent)
		v = tonumber(v)
		if not v then return end
		value = snap(v)
		show(not silent)
		if not silent then safeCall(o.Callback, value) end
	end
	function obj:Get() return value end

	valueBox.FocusLost:Connect(function()
		local typed = tonumber(valueBox.Text:match("%-?%d*%.?%d+"))
		if typed and snap(typed) ~= value then obj:Set(typed) else show(false) end
	end)

	local dragging, hovering = false, false
	local function grow() tween(knobScale, { Scale = (dragging or hovering) and 1.25 or 1 }, 0.1) end
	local function update(x)
		local a = math.clamp((x - track.AbsolutePosition.X) / math.max(track.AbsoluteSize.X, 1), 0, 1)
		local v = snap(min + (max - min) * a)
		if v ~= value then obj:Set(v) end -- the callback runs only when the value really changed
	end
	hit.MouseEnter:Connect(function() hovering = true grow() end)
	hit.MouseLeave:Connect(function() hovering = false grow() end)
	hit.InputBegan:Connect(function(i)
		-- A second touch while dragging must not take another scroll lock: only one is ever released.
		if isClick(i) and not dragging then
			dragging = true
			grow()
			self._window:_lockScroll(true)
			update(i.Position.X)
		end
	end)
	self._window:_connect(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			update(i.Position.X)
		end
	end)
	self._window:_connect(UserInputService.InputEnded, function(i)
		if isClick(i) and dragging then
			dragging = false
			grow()
			self._window:_lockScroll(false)
		end
	end)

	value = snap(tonumber(o.Default) or min)
	show(false)
	return obj
end

function Section:AddTextbox(o)
	o = type(o) == "string" and { Name = o } or o
	local row = self:_row()
	rowLabel(row, o.Name or "Textbox")
	local box = textInput(row, {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.new(0.42, 0, 0, 30),
		Text = o.Default, Placeholder = o.Placeholder,
	})
	box.FocusLost:Connect(function(enter) safeCall(o.Callback, box.Text, enter) end)
	return { Instance = row, Get = function() return box.Text end, Set = function(_, t) box.Text = t end }
end

-- Linha com vários campos de texto lado a lado e botões compactos à direita (mesmo visual do Textbox).
--   Section:AddInputRow({
--       Fields  = { { Key = "id", Placeholder = "Asset ID", Weight = 0.45 }, { Key = "name", Placeholder = "Name" } },
--       Buttons = { { Text = "Add ID", Callback = function(values, row) end } },  -- values = { id = "...", name = "..." }
--   })
--   Retorno: :Get(key)  :Set(key, texto)  :Clear()  :Flash(índiceDoBotão, texto, segundos)
function Section:AddInputRow(o)
	o = o or {}
	local fields, buttons = o.Fields or {}, o.Buttons or {}
	local GAP, BUTTON_W = 6, 66
	local row = self:_row()
	local holder = new("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(8, 0), Size = UDim2.new(1, -16, 1, 0), Parent = row,
	}, { new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, GAP),
		VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder,
	}) })

	-- Largura fixa (botões + espaços) repartida entre os campos conforme o peso de cada um.
	local fixed = #buttons * BUTTON_W + math.max(#fields + #buttons - 1, 0) * GAP
	local totalWeight, defaultWeight = 0, 1 / math.max(#fields, 1)
	for _, f in ipairs(fields) do totalWeight += (tonumber(f.Weight) or defaultWeight) end
	if totalWeight <= 0 then totalWeight = 1 end

	local obj = { Instance = row }
	local boxes = {}
	for i, f in ipairs(fields) do
		local weight = (tonumber(f.Weight) or defaultWeight) / totalWeight
		boxes[f.Key or i] = textInput(holder, {
			LayoutOrder = i, Size = UDim2.new(weight, -math.ceil(fixed * weight), 0, 30),
			Text = f.Default, Placeholder = f.Placeholder,
		})
	end

	local function values()
		local v = {}
		for key, box in pairs(boxes) do v[key] = box.Text end
		return v
	end

	local buttonObjs, flashIds = {}, {}
	for i, b in ipairs(buttons) do
		local hit, face = smallButton(holder, b.Text or "OK", BUTTON_W)
		hit.LayoutOrder = #fields + i
		hit.MouseButton1Click:Connect(function() safeCall(b.Callback, values(), obj) end)
		buttonObjs[i] = { button = face, text = face.Text }
	end

	function obj:Get(key) local box = boxes[key] return box and box.Text or nil end
	function obj:Set(key, text) local box = boxes[key] if box then box.Text = text or "" end end
	function obj:Clear() for _, box in pairs(boxes) do box.Text = "" end end
	-- Troca o texto normal de um botão ("Add ID" <-> "Save").
	function obj:SetButtonText(index, text)
		local entry = buttonObjs[index or 1]
		if not entry then return end
		entry.text = tostring(text)
		entry.button.Text = entry.text
	end
	-- Troca o texto de um botão por alguns segundos (retorno rápido: "Added", "Invalid"...).
	function obj:Flash(index, text, seconds)
		local entry = buttonObjs[index or 1]
		if not entry then return end
		local id = (flashIds[index or 1] or 0) + 1
		flashIds[index or 1] = id
		entry.button.Text = tostring(text)
		task.delay(seconds or 1.5, function()
			if flashIds[index or 1] == id and entry.button.Parent then entry.button.Text = entry.text end
		end)
	end
	return obj
end

-- Quadro de slots: uma fileira de slots (como a barra do inventário) e, embaixo, os itens para arrastar.
--   Section:AddSlotBoard({
--       Slots = { "1", "2", ..., "0" },                       -- rótulo de cada slot
--       Items = { { Key = "AK-47", Text = "AK-47" }, ... },   -- itens arrastáveis
--       Value = { [1] = { "AK-47", "M4A1" }, [3] = { "Hammer" } }, -- slot -> chaves (a primeira tem prioridade)
--       Hint  = "texto opcional abaixo dos slots",
--       Extra = { Key = "hidden", Text = "Hidden", Placeholder = "Drop here to ..." }, -- área extra opcional
--       Callback = function(value) end,                       -- cópia do valor a cada mudança
--   })
--   Com Extra, value[Extra.Key] = { chaves } é mais um destino (uma área larga abaixo dos slots).
--   Arrastar um item para um slot coloca ele no fim da lista daquele slot (e tira de qualquer outro).
--   Arrastar um slot: leva o último item dele; soltar fora dos slots tira o item. Botão direito limpa o slot.
--   Retorno: :Get()  :Set(value, silent)
function Section:AddSlotBoard(o)
	o = o or {}
	local labels = o.Slots or { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
	local items = o.Items or {}
	local GAP = 4
	local value = {}
	local itemText = {}
	for _, item in ipairs(items) do itemText[item.Key] = item.Text or item.Key end

	local extra = o.Extra
	local function copyValue(source)
		local result = {}
		for slot, keys in pairs(source or {}) do
			local valid = type(slot) == "number" or (extra and slot == extra.Key)
			if valid and type(keys) == "table" and #keys > 0 then
				result[slot] = table.clone(keys)
			end
		end
		return result
	end
	value = copyValue(o.Value)

	local container = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_next(), Parent = self._body,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })

	--// slots (the Extra area, when there is one, sits above them like the old backpack's inventory)
	local slotArea = new("Frame", {
		LayoutOrder = 3, Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 60), Parent = container,
	}, { corner(RADIUS), new("UIPadding", {
		PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8),
	}) })
	local slotGrid = new("UIGridLayout", {
		CellPadding = UDim2.fromOffset(GAP, GAP), CellSize = UDim2.fromOffset(44, 44),
		SortOrder = Enum.SortOrder.LayoutOrder, HorizontalAlignment = Enum.HorizontalAlignment.Center, Parent = slotArea,
	})

	-- Números dos slots em Oswald, como numeração pintada; laranja quando o slot tem item.
	local slotCells = {}
	for index, label in ipairs(labels) do
		local cell = new("TextButton", {
			LayoutOrder = index, BackgroundColor3 = "Track", BorderSizePixel = 0, AutoButtonColor = false,
			Text = "", Parent = slotArea,
		}, { corner(RADIUS - 1) })
		local stroke = new("UIStroke", { Color = "Divider", Thickness = 1, Transparency = 0.5, Parent = cell })
		local number = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 1), Size = UDim2.fromOffset(14, 14),
			Text = label, TextColor3 = "SubText", TextSize = 13, FontFace = Fonts.Title,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = cell,
		})
		local name = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 3, 0, 12), Size = UDim2.new(1, -6, 1, -24), TextYAlignment = Enum.TextYAlignment.Center,
			Text = "", TextColor3 = "Text", TextScaled = true, TextWrapped = true, FontFace = Fonts.Medium,
			Parent = cell,
		}, { new("UITextSizeConstraint", { MaxTextSize = 12, MinTextSize = 6 }) })
		local extra = new("TextLabel", {
			BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4, 0, 2),
			Size = UDim2.fromOffset(20, 12), Text = "", TextColor3 = "Accent", TextSize = 11,
			FontFace = Fonts.Bold, TextXAlignment = Enum.TextXAlignment.Right, Parent = cell,
		})
		slotCells[index] = { cell = cell, stroke = stroke, number = number, name = name, extra = extra }
	end


	-- Extra area: a lower strip above the slots holding its items as smaller squares; empty, it shows its
	-- placeholder text.
	local extraCell, extraLabel, extraStroke, extraHolder, extraGrid
	local extraTiles = {}
	local EXTRA_EMPTY_H, EXTRA_PAD = 36, 6
	if extra then
		-- Its own grey rounded rectangle, a little above the slot bar (like the old backpack's inventory panel).
		extraCell = new("TextButton", {
			LayoutOrder = 1, Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, AutoButtonColor = false, Text = "",
			Size = UDim2.new(1, 0, 0, EXTRA_EMPTY_H), Parent = container,
		}, { corner(RADIUS) })
		new("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 4), Parent = container })
		extraStroke = new("UIStroke", { Color = "Divider", Thickness = 1, Transparency = 0.5, Parent = extraCell })
		extraLabel = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 0, EXTRA_EMPTY_H),
			Text = "", TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Medium,
			TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = extraCell,
		})
		extraHolder = new("Frame", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(EXTRA_PAD + 2, EXTRA_PAD),
			Size = UDim2.new(1, -2 * (EXTRA_PAD + 2), 1, -2 * EXTRA_PAD), Parent = extraCell,
		})
		extraGrid = new("UIGridLayout", {
			CellPadding = UDim2.fromOffset(GAP, GAP), CellSize = UDim2.fromOffset(33, 33),
			SortOrder = Enum.SortOrder.LayoutOrder, Parent = extraHolder,
		})
	end

	if o.Hint then
		new("TextLabel", {
			LayoutOrder = 4, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			Text = o.Hint, TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Body, TextWrapped = true,
			LineHeight = 1.1, TextXAlignment = Enum.TextXAlignment.Left, Parent = container,
		}, { new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }) })
	end

	--// itens
	local itemArea = new("Frame", {
		LayoutOrder = 5, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Parent = container,
	})
	-- Same padding and cell size as the slot row, so the item squares line up with the slots.
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = itemArea })
	local itemGrid = new("UIGridLayout", {
		CellPadding = UDim2.fromOffset(GAP, GAP), CellSize = UDim2.fromOffset(44, 44),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = itemArea,
	})
	local itemCells = {}
	for index, item in ipairs(items) do
		local tile = new("TextButton", {
			LayoutOrder = index, Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, AutoButtonColor = false,
			Text = "", Parent = itemArea,
		}, { corner(RADIUS - 1) })
		local stroke = new("UIStroke", {
			Color = "Accent", Thickness = 1, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = tile,
		})
		local name = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 3, 0, 12), Size = UDim2.new(1, -6, 1, -24), TextYAlignment = Enum.TextYAlignment.Center,
			Text = itemText[item.Key], TextColor3 = "SubText", TextScaled = true, TextWrapped = true,
			FontFace = Fonts.Medium, Parent = tile,
		}, { new("UITextSizeConstraint", { MaxTextSize = 12, MinTextSize = 6 }) })
		-- The slot the item is in (top-left, like the slot numbers).
		local badge = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 1), Size = UDim2.fromOffset(14, 14),
			Text = "", TextColor3 = "Accent", TextSize = 13, FontFace = Fonts.Title,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = tile,
		})
		itemCells[item.Key] = { tile = tile, stroke = stroke, name = name, badge = badge }
	end

	-- Slots: 10 por linha quando cabem com pelo menos 44 px (toque); senão 5 por linha. Os itens usam o mesmo tamanho.
	local relayoutExtra -- sizeExtra, once it exists
	local function relayout()
		local width = slotArea.AbsoluteSize.X - 16
		if width > 0 then
			local columns = (width - 9 * GAP) / 10 >= 44 and 10 or 5
			local cell = math.min(math.floor((width - (columns - 1) * GAP) / columns), 64)
			slotGrid.CellSize = UDim2.fromOffset(cell, cell)
			slotGrid.FillDirectionMaxCells = columns -- 5 + 5, não 6 + 4 quando sobra espaço
			itemGrid.CellSize = UDim2.fromOffset(cell, cell)
			if extraGrid then
				local small = math.max(math.floor(cell * 0.75), 24)
				extraGrid.CellSize = UDim2.fromOffset(small, small)
				if relayoutExtra then relayoutExtra() end
			end
			local rows = math.ceil(#labels / columns)
			slotArea.Size = UDim2.new(1, 0, 0, rows * cell + (rows - 1) * GAP + 16)
		end
	end
	slotArea:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	local function slotOf(key)
		for slot, keys in pairs(value) do
			for _, k in ipairs(keys) do
				if k == key then return slot end
			end
		end
		return nil
	end

	local startDrag -- defined with the dragging code below
	-- Height of the strip: as many rows of small squares as its items need (a thin strip when empty).
	local function sizeExtra()
		local count = #(value[extra.Key] or {})
		if count == 0 then
			extraCell.Size = UDim2.new(1, 0, 0, EXTRA_EMPTY_H)
			return
		end
		local small = extraGrid.CellSize.X.Offset
		local width = extraHolder.AbsoluteSize.X
		local columns = width > 0 and math.max(1, math.floor((width + GAP) / (small + GAP))) or 10
		local rows = math.ceil(count / columns)
		extraCell.Size = UDim2.new(1, 0, 0, rows * small + (rows - 1) * GAP + 2 * EXTRA_PAD)
	end
	relayoutExtra = extra and sizeExtra or nil
	local function renderExtra()
		for _, tile in ipairs(extraTiles) do tile:Destroy() end
		table.clear(extraTiles)
		local keys = value[extra.Key] or {}
		extraLabel.Visible = #keys == 0
		extraLabel.Text = extra.Placeholder or (extra.Text or "Extra")
		for index, key in ipairs(keys) do
			local tile = new("TextButton", {
				LayoutOrder = index, BackgroundColor3 = "ItemSelected", BorderSizePixel = 0, AutoButtonColor = false,
				Text = "", Parent = extraHolder,
			}, { corner(RADIUS - 1), new("TextLabel", {
				BackgroundTransparency = 1, Position = UDim2.fromOffset(2, 2), Size = UDim2.new(1, -4, 1, -4),
				Text = itemText[key] or key, TextColor3 = "Text", TextScaled = true, TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Center, FontFace = Fonts.Medium,
			}, { new("UITextSizeConstraint", { MaxTextSize = 10, MinTextSize = 5 }) }) })
			tile.InputBegan:Connect(function(input)
				if isClick(input) and startDrag then startDrag(key, extra.Key, input) end
			end)
			table.insert(extraTiles, tile)
		end
		sizeExtra()
	end

	local function render()
		for index, s in ipairs(slotCells) do
			local keys = value[index]
			local filled = keys and #keys > 0
			s.name.Text = filled and (itemText[keys[1]] or keys[1]) or ""
			s.extra.Text = (filled and #keys > 1) and ("+" .. (#keys - 1)) or ""
			paint(s.cell, "BackgroundColor3", filled and "ItemSelected" or "Track")
			paint(s.number, "TextColor3", filled and "Accent" or "SubText")
		end
		if extraCell then
			renderExtra()
		end
		for key, c in pairs(itemCells) do
			local slot = slotOf(key)
			local badgeText = ""
			if extra and slot == extra.Key then
				badgeText = extra.Badge or "H"
			elseif slot then
				badgeText = tostring(labels[slot] or slot)
			end
			c.badge.Text = badgeText
			paint(c.name, "TextColor3", slot and "Text" or "SubText")
			c.stroke.Transparency = slot and 0.2 or 1
		end
	end

	local obj = { Instance = container }
	local function changed()
		render()
		safeCall(o.Callback, copyValue(value))
	end

	local function removeKey(key)
		for slot, keys in pairs(value) do
			for i = #keys, 1, -1 do
				if keys[i] == key then table.remove(keys, i) end
			end
			if #keys == 0 then value[slot] = nil end
		end
	end

	--// arrastar
	local gui = self._window._gui
	local dragging -- { key, ghost, fromSlot }
	-- input.Position is in the same space as AbsolutePosition (see insideGui); GetMouseLocation is not
	-- (it counts the top bar inset), which put the drop point below the cursor and missed the slots.
	local function pointOf(input)
		return Vector2.new(input.Position.X, input.Position.Y)
	end
	local function slotAt(point)
		for index, s in ipairs(slotCells) do
			if insideGui(s.cell, point) then return index end
		end
		if extraCell and insideGui(extraCell, point) then return extra.Key end
		return nil
	end
	-- The ghost lives in the window's ScreenGui: its offset is relative to the gui's own top-left corner.
	local function placeGhost(ghost, point)
		local origin = gui.AbsolutePosition
		ghost.Position = UDim2.fromOffset(point.X - origin.X, point.Y - origin.Y)
	end
	local function highlight(index)
		for i, s in ipairs(slotCells) do
			paint(s.stroke, "Color", (i == index) and "Accent" or "Divider")
			s.stroke.Transparency = (i == index) and 0 or 0.5
		end
		if extraStroke then
			local on = extra and index == extra.Key
			paint(extraStroke, "Color", on and "Accent" or "Divider")
			extraStroke.Transparency = on and 0 or 0.5
		end
	end

	function startDrag(key, fromSlot, input)
		if dragging or not key then return end
		local cell = slotGrid.CellSize -- the ghost is a square of the same size as the slots and the items
		local ghost = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Size = cell, BackgroundColor3 = "Accent",
			BackgroundTransparency = 0.1, BorderSizePixel = 0, ZIndex = 50, Parent = gui,
		}, { corner(RADIUS), new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 3, 0, 12), Size = UDim2.new(1, -6, 1, -24),
			Text = itemText[key] or key, TextColor3 = "OnAccent", TextScaled = true, TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Center, FontFace = Fonts.Bold, ZIndex = 51,
		}, { new("UITextSizeConstraint", { MaxTextSize = 12, MinTextSize = 6 }) }) })
		placeGhost(ghost, pointOf(input))
		dragging = { key = key, ghost = ghost, fromSlot = fromSlot }
		self._window:_lockScroll(true)
	end

	local function endDrag(input)
		local d = dragging
		if not d then return end
		dragging = nil
		self._window:_lockScroll(false)
		pcall(function() d.ghost:Destroy() end)
		highlight(nil)
		local target = slotAt(pointOf(input)) or (d.lastPoint and slotAt(d.lastPoint))
		if target then
			if target == d.fromSlot then return end
			removeKey(d.key)
			value[target] = value[target] or {}
			table.insert(value[target], d.key)
			changed()
		elseif d.fromSlot then
			removeKey(d.key) -- arrastado de um slot e solto fora: tira do slot
			changed()
		end
	end

	for key, c in pairs(itemCells) do
		c.tile.InputBegan:Connect(function(input)
			if isClick(input) then startDrag(key, nil, input) end
		end)
		c.tile.MouseEnter:Connect(function() if not dragging then tween(c.tile, { BackgroundColor3 = "ItemHover" }) end end)
		c.tile.MouseLeave:Connect(function() tween(c.tile, { BackgroundColor3 = "Item" }) end)
	end
	for index, s in ipairs(slotCells) do
		s.cell.InputBegan:Connect(function(input)
			local keys = value[index]
			if isClick(input) and keys and #keys > 0 then
				startDrag(keys[#keys], index, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 and keys then
				value[index] = nil
				changed()
			end
		end)
	end

	if extraCell then
		extraCell.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 and value[extra.Key] then
				value[extra.Key] = nil
				changed()
			end
		end)
		-- The squares wrap when the strip changes width.
		extraHolder:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeExtra)
	end

	self._window:_connect(UserInputService.InputChanged, function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local point = pointOf(input)
			dragging.lastPoint = point
			placeGhost(dragging.ghost, point)
			highlight(slotAt(point))
		end
	end)
	self._window:_connect(UserInputService.InputEnded, function(input)
		if dragging and isClick(input) then endDrag(input) end
	end)

	function obj:Get() return copyValue(value) end
	function obj:Set(newValue, silent)
		value = copyValue(newValue)
		render()
		if not silent then safeCall(o.Callback, copyValue(value)) end
	end

	render()
	task.defer(relayout)
	return obj
end

-- Small action buttons ("Edit", "Remove"...) for the right side of a header bar.
-- actions = { { Text = "Edit", Callback = fn }, ... }. Returns the box (hidden) and its width.
local ACTION_W, ACTION_GAP = 60, 4
local function buildHeaderActions(parent, actions, zIndex)
	local width = #actions * ACTION_W + math.max(#actions - 1, 0) * ACTION_GAP
	local box = new("Frame", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Size = UDim2.fromOffset(width, ROW_H),
		Visible = false, ZIndex = zIndex, Parent = parent,
	}, { new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, ACTION_GAP),
		HorizontalAlignment = Enum.HorizontalAlignment.Right, VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}) })
	for index, action in ipairs(actions) do
		local hit = smallButton(box, action.Text or "?", ACTION_W, zIndex)
		hit.LayoutOrder = index
		hit.MouseButton1Click:Connect(function() safeCall(action.Callback) end)
	end
	return box, width
end

-- Opção escolhida: laranja e em negrito (não depende só da cor). Sem opções: mostra "No options".
function Section:AddDropdown(o)
	local options = o.Options or {}
	local selected = o.Default
	local open = false
	local row = self:_row()
	row.ClipsDescendants = true

	local head = new("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, ROW_H), Parent = row })
	rowLabel(head, o.Name or "Dropdown")
	local chevron = makeChevron(head, UDim2.new(1, -24, 0.5, 0), 0.7, "SubText")
	local VALUE_X = -42
	local valLbl = new("TextLabel", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, VALUE_X, 0.5, 0),
		Size = UDim2.new(0.4, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Right, Text = tostring(selected or "None"),
		TextColor3 = "SubText", TextSize = 15, FontFace = Fonts.Medium, TextTruncate = Enum.TextTruncate.AtEnd, Parent = head,
	})
	local maxList = o.MaxHeight or ROW_H * 5
	local list = new("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(6, ROW_H),
		Size = UDim2.new(1, -12, 0, 0), CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3, ScrollBarImageColor3 = "Divider",
		ScrollingDirection = Enum.ScrollingDirection.Y, Parent = row,
	}, { new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }) })
	local emptyLbl = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW_H), Text = "No options", TextColor3 = "SubText",
		TextSize = 15, FontFace = Fonts.Body, Visible = false, Parent = list,
	})

	local obj = { Instance = row }
	local function listHeight() return math.min(math.max(#options, 1) * ROW_H, maxList) end
	local function height() return ROW_H + listHeight() + 6 end
	local popup = { row = row, autoClose = true, isOpen = function() return open end }
	local function setOpen(v)
		if v and not open then self._window:_popupOpening(popup) end
		open = v
		list.Size = UDim2.new(1, -12, 0, listHeight())
		tween(row, { Size = UDim2.new(1, 0, 0, open and height() or ROW_H) }, 0.22, Enum.EasingStyle.Quart)
		tween(chevron, { Rotation = open and 180 or 0 }, 0.22, Enum.EasingStyle.Quart)
		if open then tween(row, { BackgroundColor3 = "Item" }, 0.12) end
	end
	local function paintOption(b, on)
		paint(b, "TextColor3", on and "Accent" or "Text")
		b.FontFace = on and Fonts.Bold or Fonts.Medium
	end
	function obj:Set(v, silent)
		selected = v
		valLbl.Text = v == nil and "None" or tostring(v)
		for _, b in ipairs(list:GetChildren()) do
			if b:IsA("TextButton") then paintOption(b, b.Name == tostring(v)) end
		end
		if not silent then safeCall(o.Callback, v) end
	end
	function obj:Get() return selected end
	-- Action buttons in the header, between the value text and the arrow; shown with :ShowActions(true).
	local actionBox, actionWidth
	function obj:SetActions(actions)
		if actionBox then actionBox:Destroy() end
		actionBox, actionWidth = buildHeaderActions(head, actions)
		actionBox.Position = UDim2.new(1, VALUE_X + 6, 0.5, 0)
	end
	function obj:ShowActions(visible)
		if not actionBox then return end
		actionBox.Visible = visible == true
		valLbl.Position = UDim2.new(1, visible and (VALUE_X - actionWidth - 2) or VALUE_X, 0.5, 0)
	end
	function obj:Refresh(newOptions)
		options = newOptions or {}
		for _, b in ipairs(list:GetChildren()) do if b:IsA("TextButton") then b:Destroy() end end
		emptyLbl.Visible = #options == 0
		for index, opt in ipairs(options) do
			local b = new("TextButton", {
				Name = tostring(opt), LayoutOrder = index, BackgroundColor3 = "Track", BackgroundTransparency = 1,
				BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, ROW_H), Text = tostring(opt), TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, AutoButtonColor = false, Parent = list,
			}, { corner(RADIUS), new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }) })
			paintOption(b, opt == selected)
			b.MouseEnter:Connect(function() tween(b, { BackgroundTransparency = 0.3 }, 0.1) end)
			b.MouseLeave:Connect(function() tween(b, { BackgroundTransparency = 1 }, 0.1) end)
			b.MouseButton1Click:Connect(function() obj:Set(opt) setOpen(false) end)
		end
		if open then setOpen(true) end
	end
	head.MouseEnter:Connect(function() if not open then tween(row, { BackgroundColor3 = "ItemHover" }, 0.12) end end)
	head.MouseLeave:Connect(function() tween(row, { BackgroundColor3 = "Item" }, 0.12) end)
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

	-- A barra de brilho fica a 14 px do quadrado para a área de toque dela (44 px) não invadir o quadrado.
	local HEAD, PANEL_H, SQUARE, BAR_W, FIELDS_X = ROW_H, 128, 128, 16, 178
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
	local head = new("TextButton", { BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, HEAD), Parent = row })
	rowLabel(head, o.Name or "Color")
	local chevron = makeChevron(head, UDim2.new(1, -24, 0.5, 0), 0.7, "SubText")
	local swatch = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -42, 0.5, 0), Size = UDim2.fromOffset(40, 22),
		BackgroundColor3 = color, BorderSizePixel = 0, Parent = head,
	}, { corner(RADIUS - 1), new("UIStroke", { Color = "Divider", Thickness = 1 }) })

	local panel = new("Frame", {
		Name = "Panel", BackgroundTransparency = 1, Position = UDim2.fromOffset(10, HEAD + 8),
		Size = UDim2.new(1, -20, 0, PANEL_H), Parent = row,
	})

	--// quadrado: matiz (X) x saturação (Y), desenhado pela imagem PALETTE_IMAGE (matiz da esquerda para a
	-- direita, saturação 100% em cima até branco embaixo). Não é mais gerado por UIGradient.
	local square = new("ImageLabel", {
		Name = "HueSat", BackgroundTransparency = 1, BorderSizePixel = 0, Image = PALETTE_IMAGE,
		ScaleType = Enum.ScaleType.Stretch, Size = UDim2.fromOffset(SQUARE, SQUARE), Parent = panel,
	}, { corner(RADIUS) })
	local squareKnob = new("Frame", {
		Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14),
		BackgroundTransparency = 1, ZIndex = 4, Parent = square,
	}, { circle(), new("UIStroke", { Color = BLACK, Thickness = 1 }) })
	new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(10, 10),
		BackgroundTransparency = 1, ZIndex = 4, Parent = squareKnob,
	}, { circle(), new("UIStroke", { Color = "Text", Thickness = 2 }) })
	-- Área de clique por cima de tudo (um botão "come" o clique, então a página não rola junto no toque).
	local squareHit = new("TextButton", {
		Name = "Hit", BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1), ZIndex = 5, Parent = square,
	})

	--// barra de brilho: a imagem VALUE_IMAGE é cinza (branco em cima, preto embaixo); o ImageColor3 a pinta
	-- com o tom atual, então fica do tom atual (em cima) até o preto (embaixo).
	local bar = new("ImageLabel", {
		Name = "Value", Position = UDim2.fromOffset(SQUARE + 14, 0), Size = UDim2.fromOffset(BAR_W, PANEL_H),
		BackgroundTransparency = 1, BorderSizePixel = 0, Image = VALUE_IMAGE, ImageColor3 = WHITE,
		ScaleType = Enum.ScaleType.Stretch, Parent = panel,
	}, { corner(RADIUS) })
	local barKnob = new("Frame", {
		Name = "Knob", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.new(1, 6, 0, 5),
		BackgroundColor3 = "Text", BorderSizePixel = 0, ZIndex = 2, Parent = bar,
	}, { corner(2), new("UIStroke", { Color = BLACK, Thickness = 1 }) })
	local barHit = new("TextButton", {
		Name = "Hit", BackgroundTransparency = 1, Text = "", AutoButtonColor = false,
		Position = UDim2.fromOffset(-14, 0), Size = UDim2.new(1, 28, 1, 0), ZIndex = 5, Parent = bar,
	})

	--// campos numéricos
	local fields = new("Frame", {
		Name = "Fields", BackgroundTransparency = 1, Position = UDim2.fromOffset(FIELDS_X, 0),
		Size = UDim2.new(1, -FIELDS_X, 1, 0), Parent = panel,
	})
	local boxes = {}

	local function makeTag(parent, text, width)
		return new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.new(0, width, 1, 0), Text = text, TextColor3 = "SubText",
			TextSize = 13, FontFace = Fonts.Bold, TextXAlignment = Enum.TextXAlignment.Left, Parent = parent,
		})
	end

	local function field(key, label, col, y)
		local cell = new("Frame", {
			BackgroundTransparency = 1, Position = UDim2.new(col / 3, 0, 0, y), Size = UDim2.new(1 / 3, -6, 0, 26), Parent = fields,
		})
		makeTag(cell, label, 14)
		boxes[key] = textInput(cell, { Position = UDim2.fromOffset(16, 0), Size = UDim2.new(1, -16, 1, 0), TextSize = 14 })
	end
	field("H", "H", 0, 0); field("S", "S", 1, 0); field("V", "V", 2, 0)
	field("R", "R", 0, ROW2); field("G", "G", 1, ROW2); field("B", "B", 2, ROW2)

	local hexRow = new("Frame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, ROW3), Size = UDim2.new(1, 0, 0, 26), Parent = fields,
	})
	makeTag(hexRow, "HEX", 30)
	boxes.HEX = textInput(hexRow, { Position = UDim2.fromOffset(32, 0), Size = UDim2.new(1, -(32 + 46), 1, 0), TextSize = 14 })
	local preview = new("Frame", {
		Name = "Preview", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(40, 26),
		BackgroundColor3 = color, BorderSizePixel = 0, Parent = hexRow,
	}, { corner(RADIUS - 1), new("UIStroke", { Color = "Divider", Thickness = 1 }) })

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
		tween(row, { Size = UDim2.new(1, 0, 0, open and OPEN_H or HEAD) }, 0.22, Enum.EasingStyle.Quart)
		tween(chevron, { Rotation = open and 180 or 0 }, 0.22, Enum.EasingStyle.Quart)
		if open then tween(row, { BackgroundColor3 = "Item" }, 0.12) end
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

	head.MouseEnter:Connect(function() if not open then tween(row, { BackgroundColor3 = "ItemHover" }, 0.12) end end)
	head.MouseLeave:Connect(function() tween(row, { BackgroundColor3 = "Item" }, 0.12) end)
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
	local RIGHT = hasFolder and -84 or -14 -- borda direita do contador (com Refresh, fica à esquerda dele)
	local bar = new("Frame", {
		LayoutOrder = 1, Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, ROW_H), Parent = container,
	}, { corner(RADIUS) })
	local barStroke = new("UIStroke", {
		Color = "Accent", Thickness = 1, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = bar,
	})
	local search = new("TextBox", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, RIGHT - 76, 1, 0), Text = "", PlaceholderText = "Search by name",
		PlaceholderColor3 = "SubText", TextColor3 = "Text", TextSize = 15, FontFace = Fonts.Body,
		TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, Parent = bar,
	})
	search.Focused:Connect(function() tween(barStroke, { Transparency = 0 }, 0.12) end)
	search.FocusLost:Connect(function() tween(barStroke, { Transparency = 1 }, 0.12) end)
	local countLbl = new("TextLabel", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, RIGHT, 0.5, 0), Size = UDim2.fromOffset(56, 20),
		Text = "0", TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Medium,
		TextXAlignment = Enum.TextXAlignment.Right, Parent = bar,
	})
	local actionBox, actionWidth
	local function placeActions(visible)
		if actionBox then
			actionBox.Visible = visible
			actionBox.Position = UDim2.new(1, RIGHT, 0.5, 0)
		end
		local shift = (visible and actionBox) and (actionWidth + 8) or 0
		countLbl.Position = UDim2.new(1, RIGHT - shift, 0.5, 0)
		search.Size = UDim2.new(1, RIGHT - 76 - shift, 1, 0)
	end
	local refreshBtn
	if hasFolder then
		refreshBtn = smallButton(bar, "Refresh", 72)
		refreshBtn.AnchorPoint = Vector2.new(1, 0.5)
		refreshBtn.Position = UDim2.new(1, -6, 0.5, 0)
	end

	--// grade
	local scroller = new("ScrollingFrame", {
		LayoutOrder = 2, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
		CanvasSize = UDim2.new(), ScrollBarThickness = 3, ScrollBarImageColor3 = "Divider",
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
		LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW_H), Visible = false,
		Text = "", TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Body, TextWrapped = true, Parent = container,
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
		tween(e.stroke, { Color = on and "Accent" or "Item" }, 0.15)
		tween(e.cell, { BackgroundColor3 = on and "ItemSelected" or "Item" }, 0.15)
		tween(e.name, { TextColor3 = on and "Text" or "SubText" }, 0.15)
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
			Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, Parent = scroller,
		}, { corner(RADIUS + 1) })
		local stroke = new("UIStroke", {
			Color = "Item", Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = cell,
		})
		local thumb = new("Frame", {
			Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 1, -34), BackgroundColor3 = "Track",
			BorderSizePixel = 0, ClipsDescendants = true, Parent = cell,
		}, { corner(RADIUS - 1) })
		local img = new("ImageLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ImageTransparency = 1,
			ScaleType = Enum.ScaleType.Fit, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Parent = thumb,
		}, { new("UIScale", { Scale = 1 }) })
		local imgScale = img:FindFirstChildOfClass("UIScale")
		local failLbl = new("TextLabel", {
			BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "?", Visible = false,
			TextColor3 = "SubText", TextSize = 22, FontFace = Fonts.Bold, Parent = thumb,
		})
		local name = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 6, 1, -25), Size = UDim2.new(1, -12, 0, 20),
			Text = item.Name, TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Medium,
			TextTruncate = Enum.TextTruncate.AtEnd, Parent = cell,
		})
		-- selo de seleção: placa laranja com check escuro (mesma placa do logo e da aba ativa)
		local badge = new("Frame", {
			AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 10), Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = "Accent", BorderSizePixel = 0, Visible = false, ZIndex = 5, Parent = cell,
		}, { corner(RADIUS - 1) })
		for _, a in ipairs({ { 6, 11, 4.5, 45 }, { 10.5, 9.5, 9, -45 } }) do
			new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(a[1], a[2]),
				Size = UDim2.fromOffset(a[3], 2.2), Rotation = a[4], BackgroundColor3 = "OnAccent",
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
				if reducedMotion() then thumb.BackgroundTransparency = 0.4 else pulse:Play() end
				enqueueLoad(item.Path, onLoaded)
			end
		end
		if started then e.load() end

		-- interação
		cell.MouseEnter:Connect(function()
			tween(imgScale, { Scale = 1.07 }, 0.18)
			if selected ~= e then
				tween(cell, { BackgroundColor3 = "ItemHover" }, 0.12)
				tween(stroke, { Color = "Divider" }, 0.12)
			end
		end)
		cell.MouseLeave:Connect(function()
			tween(imgScale, { Scale = 1 }, 0.18)
			if selected ~= e then
				tween(cell, { BackgroundColor3 = "Item" }, 0.12)
				tween(stroke, { Color = "Item" }, 0.12)
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
		if #entries == 0 then
			emptyLbl.Text = hasFolder and "No images yet. Add PNG files to the folder, then press Refresh." or "No images yet."
		else
			emptyLbl.Text = "Nothing matches \"" .. search.Text .. "\"."
		end
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
	-- Action buttons in the top bar (left of the counter); shown with :ShowActions(true).
	function obj:SetActions(actions)
		if actionBox then actionBox:Destroy() end
		actionBox, actionWidth = buildHeaderActions(bar, actions)
		placeActions(false)
	end
	function obj:ShowActions(visible) placeActions(visible == true) end
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
	local H = nested and ROW_H or 52

	local holder = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order, Parent = parentContainer,
	}, { new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }) })

	local header = new("TextButton", {
		LayoutOrder = 1, Surface = "Panel", BackgroundColor3 = nested and "Item" or "Header", BorderSizePixel = 0,
		AutoButtonColor = false, Size = UDim2.new(1, 0, 0, H), Text = "", Parent = holder,
	}, { corner(RADIUS) })

	local textX = 14
	if o.Icon then
		makeIcon(header, o.Icon, nested and 20 or 24, UDim2.fromOffset(nested and 24 or 28, H / 2))
		textX = nested and 44 or 52
	end
	-- Primeiro nível: Oswald em maiúsculas, como letreiro. Subseção: Builder Sans, para não competir.
	local title = new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(textX, 0), Size = UDim2.new(1, -(textX + 44), 1, 0),
		Text = nested and sec.Name or sec.Name:upper(), TextColor3 = "Text", TextSize = nested and 16 or 22,
		FontFace = nested and Fonts.Bold or Fonts.Title,
		TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	})
	local chev = makeChevron(header, UDim2.new(1, -24, 0.5, 0), nested and 0.7 or 0.85, nested and "SubText" or "Text")

	local base, hover = (nested and "Item" or "Header"), (nested and "ItemHover" or "HeaderHover")
	hoverColors(header, header, base, hover)

	local body = new("Frame", {
		LayoutOrder = 2, Surface = "Panel", BackgroundColor3 = nested and "SubBody" or "Body", BorderSizePixel = 0,
		ClipsDescendants = true, Size = UDim2.new(1, 0, 0, 0), Visible = false, Parent = holder,
	}, { corner(RADIUS) })
	local pad = nested and 6 or 8
	new("UIPadding", {
		PaddingTop = UDim.new(0, pad), PaddingBottom = UDim.new(0, pad),
		PaddingLeft = UDim.new(0, pad), PaddingRight = UDim.new(0, pad), Parent = body,
	})
	local layout = new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = body })
	sec._body = body

	local open, animating, token = false, false, 0
	local function targetHeight() return layout.AbsoluteContentSize.Y + pad * 2 end

	function sec:SetOpen(state)
		open = state and true or false
		token += 1
		local mine = token
		animating = true
		tween(chev, { Rotation = open and 180 or 0 }, 0.22, Enum.EasingStyle.Quart)
		if not nested then tween(title, { TextColor3 = open and "Accent" or "Text" }, 0.15) end
		if open then body.Visible = true end
		local tw = tween(body, { Size = UDim2.new(1, 0, 0, open and targetHeight() or 0) }, 0.22, Enum.EasingStyle.Quart)
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

-- Botão de navegação (aba da barra lateral ou do rodapé): transparente; no hover, fundo e texto acendem.
local function navHover(window, btn, label)
	local function active() return window._selected ~= nil and window._selected._btn == btn end
	btn.MouseEnter:Connect(function()
		if active() then return end
		tween(btn, { BackgroundTransparency = 0 }, 0.12)
		tween(label, { TextColor3 = "Text" }, 0.12)
	end)
	btn.MouseLeave:Connect(function()
		if active() then return end
		tween(btn, { BackgroundTransparency = 1 }, 0.12)
		tween(label, { TextColor3 = "SubText" }, 0.12)
	end)
end

-- Aba ativa = placa no destaque com texto contrastante.
function Window:SelectTab(tab)
	local changed = self._selected ~= tab
	for _, t in ipairs(self._tabs) do
		local on = (t == tab)
		t._page.Visible = on
		t._page.ScrollingEnabled = self._scrollLocks == 0
		tween(t._btn, { BackgroundTransparency = on and 0 or 1, BackgroundColor3 = on and "Accent" or "TabHover" }, 0.15)
		tween(t._label, { TextColor3 = on and "OnAccent" or "SubText" }, 0.15)
	end
	self._selected = tab
	if changed then
		-- O conteúdo sobe 10 px ao entrar: sinal de que a página trocou.
		tab._page.Position = UDim2.fromOffset(0, 10)
		tween(tab._page, { Position = UDim2.fromOffset(0, 0) }, 0.2, Enum.EasingStyle.Quart)
	end
end

-- Footer = "Settings": a página não ganha aba na barra lateral; o botão do rodapé com esse nome a abre.
function Window:AddTab(o)
	o = type(o) == "string" and { Name = o } or o or {}
	local tab = setmetatable({ _window = self, Name = o.Name or "Tab", _n = 0 }, Tab)

	local btn = o.Footer and self._footerButtons[o.Footer]
	local label = btn
	if not btn then
		btn = new("TextButton", {
			BackgroundColor3 = "TabHover", BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false,
			Size = UDim2.new(1, 0, 0, 48), Text = "", LayoutOrder = #self._tabs, Parent = self._tabList,
		}, { corner(RADIUS) })
		local textX = 14
		if o.Icon then
			makeIcon(btn, o.Icon, 24, UDim2.fromOffset(26, 24))
			textX = 48
		end
		label = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(textX, 0), Size = UDim2.new(1, -(textX + 6), 1, 0),
			Text = tab.Name:upper(), TextColor3 = "SubText", TextSize = 21, FontFace = Fonts.Title,
			TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Parent = btn,
		})
		navHover(self, btn, label)
	end

	local page = new("ScrollingFrame", {
		BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Visible = false,
		ScrollBarThickness = 3, ScrollBarImageColor3 = "Divider", CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollingDirection = Enum.ScrollingDirection.Y, Parent = self._content,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		new("UIPadding", {
			PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14),
			PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14),
		}),
	})

	tab._btn, tab._label, tab._page, tab._body = btn, label, page, page
	table.insert(self._tabs, tab)
	btn.MouseButton1Click:Connect(function() self:SelectTab(tab) end)
	if not self._selected and not o.Footer then self:SelectTab(tab) end
	return tab
end

function Window:SetVisible(v) self._shell.Visible = v end
function Window:Toggle() self._shell.Visible = not self._shell.Visible end

-- Imagem de fundo: ID do Roblox ou arquivo da workspace; nil ou "" remove. Devolve false se não carregar.
function Window:SetBackgroundImage(source)
	if source == nil or source == "" then
		self._backdrop.Visible = false
		return true
	end
	local asset = resolveAsset(source)
	if not asset then return false end
	self._backdrop.Image = asset
	self._backdrop.Visible = true
	return true
end
function Window:SetBackgroundImageTransparency(t) self._backdrop.ImageTransparency = math.clamp(t, 0, 1) end

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
        SettingsButton = true,             -- botão Settings no rodapé, para uma página AddTab{ Footer = "Settings" }
        ToggleKey  = Enum.KeyCode.RightShift,   -- false para desativar
        Size       = UDim2.fromOffset(712, 500),
    })

    O rodapé só aparece se algum botão tiver ícone ou ação; sem nenhum, nem a linha divisória é desenhada.
    A janela é um Frame comum com cores lisas (nada de CanvasGroup nem de gradiente nos fundos).
    Size em pixels é o tamanho máximo: numa tela menor, a janela encolhe para caber.
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

	local WIN_R, SIDEBAR_W, LOGO_H, FOOTER_H, INSET = 6, 164, 72, 58, 6
	local baseSize = cfg.Size or UDim2.fromOffset(712, 500)

	-- Active = true: clicar na janela não "atravessa" para o jogo (não atira).
	-- A borda fina separa a janela do cenário do jogo, que pode ser claro ou escuro.
	local window = new("Frame", {
		Name = "Window", Active = true, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = baseSize, Surface = "Background", BackgroundColor3 = "Content", BorderSizePixel = 0, Parent = gui,
	}, { corner(WIN_R), new("UIStroke", { Color = "Divider", Thickness = 1 }) })
	self._shell = window

	-- Imagem de fundo (opcional): fica entre a cor da janela e o conteúdo.
	self._backdrop = new("ImageLabel", {
		Name = "Backdrop", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ScaleType = Enum.ScaleType.Crop,
		ImageTransparency = 0.5, Visible = false, ZIndex = 0, Parent = window,
	}, { corner(WIN_R) })

	-- Em telas menores que a janela (celular), ela encolhe para caber, sem diminuir texto nem alvos de toque.
	if baseSize.X.Scale == 0 and baseSize.Y.Scale == 0 then
		local function fit()
			local screen = gui.AbsoluteSize
			if screen.X <= 0 or screen.Y <= 0 then return end
			window.Size = UDim2.fromOffset(
				math.min(baseSize.X.Offset, screen.X - 16), math.min(baseSize.Y.Offset, screen.Y - 16))
		end
		self:_connect(gui:GetPropertyChangedSignal("AbsoluteSize"), fit)
		fit()
	end

	-- ClipsDescendants: a página entra deslizando 10 px e não pode vazar pela borda de baixo.
	local content = new("Frame", {
		Name = "Content", BackgroundTransparency = 1, BorderSizePixel = 0, ClipsDescendants = true,
		Position = UDim2.fromOffset(SIDEBAR_W, 0), Size = UDim2.new(1, -SIDEBAR_W, 1, 0), Parent = window,
	})
	self._content = content

	-- Barra lateral: painel embutido com margem, sem peças sobrepostas (com transparência, sobreposição
	-- apareceria como uma faixa mais escura).
	local sidebar = new("Frame", {
		Name = "Sidebar", Position = UDim2.fromOffset(INSET, INSET), Size = UDim2.new(0, SIDEBAR_W - INSET, 1, -INSET * 2),
		Surface = "Background", BackgroundColor3 = "Sidebar", BorderSizePixel = 0, Parent = window,
	}, { corner(RADIUS) })

	-- Topo da barra: o nome em Oswald no destaque, alinhado com as abas. Texto e não placa, para não parecer
	-- uma segunda aba ativa. Serve de alça para arrastar a janela.
	local logo = new("Frame", { Name = "Logo", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, LOGO_H), Parent = sidebar })
	local logoAsset = resolveAsset(cfg.Logo)
	if logoAsset then
		new("ImageLabel", {
			BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(110, 44), Image = logoAsset, ScaleType = Enum.ScaleType.Fit, Parent = logo,
		})
	else
		new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(18, 0), Size = UDim2.new(1, -28, 1, 0),
			Text = cfg.Title or "CW", TextColor3 = "Accent", TextSize = 44, FontFace = Fonts.Title,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = logo,
		})
	end

	-- Rodapé: só os botões que têm ícone ou ação. Sem ícone, o botão mostra o nome por extenso.
	-- SettingsButton = true cria o botão Settings para uma página ligada a ele (AddTab{ Footer = "Settings" }).
	local footerIcons = cfg.Icons or {}
	local footer = {}
	if footerIcons.Settings or cfg.OnSettings or cfg.SettingsButton then
		table.insert(footer, { icon = footerIcons.Settings, name = "Settings", cb = cfg.OnSettings })
	end
	if footerIcons.Discord or cfg.Discord or cfg.OnDiscord then
		local copies = cfg.Discord ~= nil and setclipboard ~= nil
		table.insert(footer, { icon = footerIcons.Discord, name = "Discord", done = copies and "Copied" or nil, cb = function()
			if copies then pcall(setclipboard, cfg.Discord) end
			safeCall(cfg.OnDiscord, cfg.Discord)
		end })
	end
	if footerIcons.Info or cfg.OnInfo then
		table.insert(footer, { icon = footerIcons.Info, name = "Info", cb = cfg.OnInfo })
	end
	local hasFooter = #footer > 0

	self._tabList = new("ScrollingFrame", {
		Name = "Tabs", BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromOffset(0, LOGO_H),
		Size = UDim2.new(1, 0, 1, -(LOGO_H + (hasFooter and FOOTER_H or 4))), CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 0,
		ScrollingDirection = Enum.ScrollingDirection.Y, Parent = sidebar,
	}, {
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
		new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }),
	})

	self._footerButtons = {}
	if hasFooter then
		new("Frame", {
			Name = "Divider", Position = UDim2.new(0, 4, 1, -FOOTER_H), Size = UDim2.new(1, -8, 0, 1),
			BackgroundColor3 = "Divider", BorderSizePixel = 0, Parent = sidebar,
		})
		local bar = new("Frame", {
			BackgroundTransparency = 1, Position = UDim2.new(0, 4, 1, -(FOOTER_H - 6)), Size = UDim2.new(1, -8, 0, ROW_H),
			Parent = sidebar,
		}, { new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
		}) })
		for index, item in ipairs(footer) do
			local b = new("TextButton", {
				LayoutOrder = index, Size = UDim2.new(1 / #footer, -4 * (#footer - 1) / #footer, 1, 0),
				BackgroundColor3 = "TabHover", BackgroundTransparency = 1, BorderSizePixel = 0, AutoButtonColor = false,
				Text = item.icon and "" or item.name, TextColor3 = "SubText", TextSize = 15, FontFace = Fonts.Bold,
				TextTruncate = Enum.TextTruncate.AtEnd, Parent = bar,
			}, { corner(RADIUS) })
			if item.icon then makeIcon(b, item.icon, 22, UDim2.fromScale(0.5, 0.5)) end
			navHover(self, b, b)
			b.MouseButton1Click:Connect(function()
				safeCall(item.cb)
				if item.done and not item.icon then -- confirma a ação que não tem outro retorno visível
					b.Text = item.done
					task.delay(1.5, function() if b.Parent then b.Text = item.name end end)
				end
			end)
			self._footerButtons[item.name] = b
		end
	end

	-- arrastar pelo logo
	local dragging, dragStart, startPos
	logo.InputBegan:Connect(function(i)
		if isClick(i) then
			dragging, dragStart, startPos = true, i.Position, window.Position
			i.Changed:Connect(function() if i.UserInputState == Enum.UserInputState.End then dragging = false end end)
		end
	end)
	self:_connect(UserInputService.InputChanged, function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local d = i.Position - dragStart
			window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
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
