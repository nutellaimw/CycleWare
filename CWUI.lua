--[[
    CW UI Library  v3.2

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
        Group: painel fixo dentro da seção que junta controles de uma mesma coisa (não abre nem fecha)
        Pager (na aba): uma página por item, com nome, prévia 3D e, embaixo dela, anterior/próxima e os controles da prévia

    PERSONALIZAÇÃO
        CW.SetTheme({ Accent, Text, Background, Sidebar, Panel = Color3, BackgroundTransparency, PanelTransparency = 0..1 })
        CW.ResetTheme(), CW.GetTheme(); Window:SetBackgroundLayers({ camada, ... }) (até CW.MaxLayers),
        Window:SetParallax(ligado, força 0..0.1, só com o mouse em cima); Section:AddLayerCanvas (editor visual)
]]

local CW = { Version = "3.2.0" }

--// Executor functions -------------------------------------------------------
-- CycleWare passes its own versions of these (each call runs on a thread of its own, so an executor that lowers
-- the permissions of the thread calling it can't break the interface). Loaded by anything else, the library uses
-- the executor's own.
local host = ...
local function hostFn(name, fallback)
	if type(host) == "table" and type(host[name]) == "function" then return host[name] end
	return fallback
end
local cloneref = hostFn("cloneref", cloneref) or function(x) return x end
local gethui = hostFn("gethui", gethui)
local protectGui = hostFn("protectGui", syn and syn.protect_gui)
local setclipboard = hostFn("setclipboard", setclipboard)
local getcustomasset = hostFn("getcustomasset", getcustomasset)
local isfile = hostFn("isfile", isfile)
local isfolder = hostFn("isfolder", isfolder)
local listfiles = hostFn("listfiles", listfiles)

--// Services ---------------------------------------------------------------
local TweenService     = cloneref(game:GetService("TweenService"))
local RunService       = cloneref(game:GetService("RunService"))
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
	Selector = false,                          -- cor da aba ativa; false = a mesma do destaque
	BackgroundTransparency = 0,                -- janela e barra lateral
	PanelTransparency = 0,                     -- cabeçalhos, corpos das seções e linhas
	SelectorTransparency = 0,                  -- aba ativa e hover das abas
	Corners = true,                            -- false = cantos retos em tudo (os círculos continuam)
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
	-- Texto sobre o destaque e sobre a aba ativa: escuro ou claro, o que for mais legível na cor escolhida.
	local function readableOn(color)
		local dark, light = Color3.fromRGB(18, 13, 8), Color3.fromRGB(245, 245, 245)
		return contrast(color, dark) >= contrast(color, light) and dark or light
	end
	Theme.Selector = Palette.Selector or accent
	Theme.OnAccent, Theme.OnSelector = readableOn(accent), readableOn(Theme.Selector)
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
-- Tabelas comuns, não fracas: no Roblox o objeto Lua de uma instância pode ser coletado com a instância
-- ainda viva, e ela sairia do registro (pararia de mudar de cor). Instâncias destruídas saem na repintura.
local painted = {}  -- instância -> { propriedade = papel }
local surfaces = {} -- instância -> "Background" | "Panel" | "Selector" (transparência)
local corners = {}  -- UICorner -> raio original (Corners = false zera)

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

local function corner(r)
	local c = new("UICorner", { CornerRadius = UDim.new(0, Palette.Corners and r or 0) })
	corners[c] = r
	return c
end
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
--               Selector = Color3 ou false (segue o destaque), BackgroundTransparency, PanelTransparency,
--               SelectorTransparency = 0..1, Corners = true/false })
-- Só as chaves passadas mudam. CW.ResetTheme() volta ao padrão. A repintura acontece uma vez por quadro,
-- então arrastar um seletor de cor não pesa.
local repaintQueued = false
local function repaint()
	repaintQueued = false
	for inst, roles in pairs(painted) do
		if inst.Parent == nil then
			painted[inst] = nil
		else
			for prop, role in pairs(roles) do inst[prop] = Theme[role] end
		end
	end
	for inst, layer in pairs(surfaces) do
		if inst.Parent == nil then surfaces[inst] = nil else inst.BackgroundTransparency = Palette[layer .. "Transparency"] end
	end
	for c, r in pairs(corners) do
		if c.Parent == nil then corners[c] = nil else c.CornerRadius = UDim.new(0, Palette.Corners and r or 0) end
	end
end

function CW.SetTheme(changes)
	for key, value in pairs(changes or {}) do
		local default = DEFAULT_PALETTE[key]
		local valid = default ~= nil and (typeof(value) == typeof(default) or (key == "Selector" and typeof(value) == "Color3"))
		if valid then
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
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5), Position = state and ON or OFF, Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = state and "OnAccent" or "SubText", BorderSizePixel = 0, Parent = sw,
	}, { corner(RADIUS - 1) })

	local obj = { Instance = row }
	function obj:Set(v, silent)
		state = v and true or false
		tween(sw, { BackgroundColor3 = state and "Accent" or "Track" })
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
--       Changed = function(values, row) end,  -- opcional: a cada letra digitada
--   })
--   Sem Fields, é uma linha só de botões; sem Buttons, só de campos.
--   Retorno: :Get(key)  :Set(key, texto)  :Clear()  :Flash(índiceDoBotão, texto, segundos)
--            :SetButtonText(índice, texto)  :SetButtonVisible(índice, visível)
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

	local obj = { Instance = row }
	local boxes, faces, buttonObjs, flashIds = {}, {}, {}, {}
	local function values()
		local v = {}
		for key, box in pairs(boxes) do v[key] = box.Text end
		return v
	end

	-- Os campos repartem, conforme o peso de cada um, a largura que os botões visíveis deixam.
	local totalWeight, defaultWeight = 0, 1 / math.max(#fields, 1)
	for _, f in ipairs(fields) do totalWeight += (tonumber(f.Weight) or defaultWeight) end
	if totalWeight <= 0 then totalWeight = 1 end
	local function layoutFields()
		local shown = 0
		for _, entry in ipairs(buttonObjs) do
			if entry.hit.Visible then shown += 1 end
		end
		local fixed = shown * BUTTON_W + math.max(#fields + shown - 1, 0) * GAP
		for _, field in ipairs(faces) do
			field.face.Size = UDim2.new(field.weight, -math.ceil(fixed * field.weight), 0, 30)
		end
	end

	for i, f in ipairs(fields) do
		local box, face = textInput(holder, {
			LayoutOrder = i, Size = UDim2.fromOffset(0, 30), Text = f.Default, Placeholder = f.Placeholder,
		})
		boxes[f.Key or i] = box
		table.insert(faces, { face = face, weight = (tonumber(f.Weight) or defaultWeight) / totalWeight })
		if o.Changed then
			box:GetPropertyChangedSignal("Text"):Connect(function() safeCall(o.Changed, values(), obj) end)
		end
	end

	for i, b in ipairs(buttons) do
		local hit, face = smallButton(holder, b.Text or "OK", BUTTON_W)
		hit.LayoutOrder = #fields + i
		hit.MouseButton1Click:Connect(function() safeCall(b.Callback, values(), obj) end)
		buttonObjs[i] = { hit = hit, button = face, text = face.Text }
	end
	layoutFields()

	function obj:Get(key) local box = boxes[key] return box and box.Text or nil end
	function obj:Set(key, text) local box = boxes[key] if box then box.Text = text or "" end end
	function obj:Clear() for _, box in pairs(boxes) do box.Text = "" end end
	-- Troca o texto normal de um botão ("Add" <-> "Save").
	function obj:SetButtonText(index, text)
		local entry = buttonObjs[index or 1]
		if not entry then return end
		entry.text = tostring(text)
		entry.button.Text = entry.text
	end
	-- Só fica à vista o que se pode fazer agora; os campos ocupam o espaço de um botão escondido.
	function obj:SetButtonVisible(index, visible)
		local entry = buttonObjs[index]
		visible = visible ~= false
		if not entry or entry.hit.Visible == visible then return end
		entry.hit.Visible = visible
		layoutFields()
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
--   Com Extra, value[Extra.Key] = { chaves } é mais um destino (uma faixa larga acima dos slots).
--   Cada item é um bloco só, que mora num lugar: na lista de baixo (sem lugar), num slot ou na faixa Extra.
--   Arrastar leva o próprio bloco (ele sai do lugar e segue o cursor); solto num slot, ele fica por cima da pilha
--   daquele slot (passa a ser o primeiro); solto fora dos slots, volta para a lista. Num slot com vários, aparece
--   o de cima, com "+N" pelos de baixo. Botão direito num slot (ou na faixa) esvazia ele.
--   Retorno: :Get()  :Set(value, silent)
function Section:AddSlotBoard(o)
	o = o or {}
	local labels = o.Slots or { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }
	local items = o.Items or {}
	local extra = o.Extra
	local GAP = 4
	local itemText, poolOrder = {}, {}
	for index, item in ipairs(items) do
		itemText[item.Key] = item.Text or item.Key
		poolOrder[item.Key] = index
	end

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
	local value = copyValue(o.Value)

	local container = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_next(), Parent = self._body,
	}, { new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }) })

	--// slots (a faixa Extra, quando existe, fica acima deles, como o inventário da mochila antiga)
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

	-- Números dos slots em Oswald, como numeração pintada; laranja quando o slot tem item. O número e o "+N" ficam
	-- por cima do bloco que o slot segura.
	local slotCells = {}
	for index, label in ipairs(labels) do
		local cell = new("TextButton", {
			LayoutOrder = index, BackgroundColor3 = "Track", BorderSizePixel = 0, AutoButtonColor = false,
			Text = "", Parent = slotArea,
		}, { corner(RADIUS - 1) })
		local stroke = new("UIStroke", { Color = "Accent", Thickness = 1, Transparency = 1, Parent = cell })
		local number = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 1), Size = UDim2.fromOffset(14, 14),
			Text = label, TextColor3 = "SubText", TextSize = 13, FontFace = Fonts.Title, ZIndex = 2,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = cell,
		})
		local more = new("TextLabel", {
			BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4, 0, 2),
			Size = UDim2.fromOffset(20, 12), Text = "", TextColor3 = "Accent", TextSize = 11, ZIndex = 2,
			FontFace = Fonts.Bold, TextXAlignment = Enum.TextXAlignment.Right, Parent = cell,
		})
		slotCells[index] = { cell = cell, stroke = stroke, number = number, more = more }
	end

	-- Faixa Extra: uma faixa cinza acima dos slots com os blocos dela em quadrados menores; vazia, mostra o texto
	-- de espera.
	local extraCell, extraLabel, extraStroke, extraHolder, extraGrid
	local EXTRA_EMPTY_H, EXTRA_PAD = 36, 6
	if extra then
		extraCell = new("TextButton", {
			LayoutOrder = 1, Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, AutoButtonColor = false, Text = "",
			Size = UDim2.new(1, 0, 0, EXTRA_EMPTY_H), Parent = container,
		}, { corner(RADIUS) })
		new("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 4), Parent = container })
		extraStroke = new("UIStroke", { Color = "Accent", Thickness = 1, Transparency = 1, Parent = extraCell })
		extraLabel = new("TextLabel", {
			BackgroundTransparency = 1, Position = UDim2.fromOffset(10, 0), Size = UDim2.new(1, -20, 0, EXTRA_EMPTY_H),
			Text = extra.Placeholder or (extra.Text or "Extra"), TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Medium,
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

	--// lista: os blocos que não estão em lugar nenhum (mesmo recuo e tamanho dos slots, para alinhar com eles)
	local itemArea = new("Frame", {
		LayoutOrder = 5, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		Parent = container,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), Parent = itemArea })
	local itemGrid = new("UIGridLayout", {
		CellPadding = UDim2.fromOffset(GAP, GAP), CellSize = UDim2.fromOffset(44, 44),
		SortOrder = Enum.SortOrder.LayoutOrder, Parent = itemArea,
	})

	--// blocos: um por item, criado na primeira vez que aparece (uma chave salva que não está em Items também ganha
	-- o seu, para poder sair do slot)
	local blocks = {} -- chave -> { button, label, size, stroke, where }
	-- Como o bloco fica em cada lugar: cor, cor do nome, recuo do nome (o slot tem o número em cima) e letra máxima.
	local LOOKS = {
		pool  = { color = "Item", text = "SubText", inset = 12, max = 12, panel = true },
		slot  = { color = "ItemSelected", text = "Text", inset = 12, max = 12 },
		extra = { color = "ItemSelected", text = "Text", inset = 2, max = 10 },
	}
	local function dress(block, where)
		local look = LOOKS[where]
		block.where = where
		paint(block.button, "BackgroundColor3", look.color)
		surfaces[block.button] = look.panel and "Panel" or nil
		block.button.BackgroundTransparency = look.panel and Palette.PanelTransparency or 0
		block.button.Size = UDim2.fromScale(1, 1) -- dentro de um slot ele o preenche; numa grade, a grade manda
		block.button.Position = UDim2.new()
		block.label.Position = UDim2.new(0, 3, 0, look.inset)
		block.label.Size = UDim2.new(1, -6, 1, -2 * look.inset)
		paint(block.label, "TextColor3", look.text)
		block.size.MaxTextSize = look.max
	end

	local startDrag, clearAt -- (definidas com o arraste, mais abaixo)
	local lifted -- o bloco sendo arrastado: { key, block, from, holder, offset, lastPoint }
	local function blockOf(key)
		local block = blocks[key]
		if block then return block end
		local button = new("TextButton", {
			BorderSizePixel = 0, AutoButtonColor = false, Text = "", ZIndex = 1,
		}, { corner(RADIUS - 1) })
		local size = new("UITextSizeConstraint", { MaxTextSize = 12, MinTextSize = 5 })
		local label = new("TextLabel", {
			BackgroundTransparency = 1, Text = itemText[key] or key, TextScaled = true, TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Center, FontFace = Fonts.Medium, Parent = button,
		}, { size })
		local stroke = new("UIStroke", {
			Color = "Accent", Thickness = 1, Transparency = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = button,
		})
		block = { key = key, button = button, label = label, size = size, stroke = stroke }
		blocks[key] = block
		button.InputBegan:Connect(function(input)
			if isClick(input) then
				startDrag(key, input)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				clearAt(key)
			end
		end)
		button.MouseEnter:Connect(function()
			if not lifted and block.where == "pool" then tween(button, { BackgroundColor3 = "ItemHover" }) end
		end)
		button.MouseLeave:Connect(function()
			if block.where == "pool" then tween(button, { BackgroundColor3 = "Item" }) end
		end)
		return block
	end

	-- Slots: 10 por linha quando cabem com pelo menos 44 px (toque); senão 5 por linha. A lista usa o mesmo tamanho.
	local sizeExtra -- (definida com a faixa, mais abaixo)
	local function relayout()
		local width = slotArea.AbsoluteSize.X - 16
		if width <= 0 then return end
		local columns = (width - 9 * GAP) / 10 >= 44 and 10 or 5
		local cell = math.min(math.floor((width - (columns - 1) * GAP) / columns), 64)
		slotGrid.CellSize = UDim2.fromOffset(cell, cell)
		slotGrid.FillDirectionMaxCells = columns -- 5 + 5, não 6 + 4 quando sobra espaço
		itemGrid.CellSize = UDim2.fromOffset(cell, cell)
		if extraGrid then
			local small = math.max(math.floor(cell * 0.75), 24)
			extraGrid.CellSize = UDim2.fromOffset(small, small)
			sizeExtra()
		end
		local rows = math.ceil(#labels / columns)
		slotArea.Size = UDim2.new(1, 0, 0, rows * cell + (rows - 1) * GAP + 16)
	end
	slotArea:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayout)

	-- Onde uma chave está agora (o número do slot, Extra.Key ou nil).
	local function slotOf(key)
		for slot, keys in pairs(value) do
			if table.find(keys, key) then return slot end
		end
		return nil
	end
	-- As chaves de um lugar, sem a que está no ar.
	local function shownKeys(slot)
		local keys = {}
		for _, key in ipairs(value[slot] or {}) do
			if not (lifted and lifted.key == key) then table.insert(keys, key) end
		end
		return keys
	end

	-- Altura da faixa: quantas fileiras de quadradinhos os blocos dela pedem (fina quando vazia).
	function sizeExtra()
		local count = #shownKeys(extra.Key)
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

	-- Põe cada bloco no seu lugar. O que está no ar fica onde está (com o cursor).
	local function render()
		local placed = {}
		for index, s in ipairs(slotCells) do
			local keys = shownKeys(index)
			for position, key in ipairs(keys) do
				local block = blockOf(key)
				placed[key] = true
				dress(block, "slot")
				block.button.Parent = s.cell
				block.button.Visible = position == 1 -- os de baixo da pilha ficam guardados no slot
			end
			s.more.Text = #keys > 1 and ("+" .. (#keys - 1)) or ""
			paint(s.number, "TextColor3", #keys > 0 and "Accent" or "SubText")
		end
		if extraCell then
			local keys = shownKeys(extra.Key)
			for position, key in ipairs(keys) do
				local block = blockOf(key)
				placed[key] = true
				dress(block, "extra")
				block.button.LayoutOrder = position
				block.button.Visible = true
				block.button.Parent = extraHolder
			end
			extraLabel.Visible = #keys == 0
			sizeExtra()
		end
		for _, item in ipairs(items) do blockOf(item.Key) end
		for key, block in pairs(blocks) do
			if not placed[key] and not (lifted and lifted.key == key) then
				if poolOrder[key] then
					dress(block, "pool")
					block.button.LayoutOrder = poolOrder[key]
					block.button.Visible = true
					block.button.Parent = itemArea
				else
					block.button.Parent = nil -- uma chave que não está em Items só aparece enquanto tem lugar
				end
			end
		end
	end

	local obj = { Instance = container }
	local function changed()
		render()
		safeCall(o.Callback, copyValue(value))
	end

	local function removeKey(key)
		for slot, keys in pairs(value) do
			local at = table.find(keys, key)
			if at then table.remove(keys, at) end
			if #keys == 0 then value[slot] = nil end
		end
	end

	--// arrastar: o próprio bloco sai do lugar e vai para o ScreenGui da janela, por cima de tudo, seguindo o cursor
	-- do ponto em que foi pego.
	local gui = self._window._gui
	local LIFTED_Z = 50
	-- input.Position está no mesmo espaço de AbsolutePosition (ver insideGui); GetMouseLocation não (conta a faixa
	-- de cima do Roblox), o que punha o ponto de soltar abaixo do cursor.
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
	local function highlight(target)
		for index, s in ipairs(slotCells) do
			s.stroke.Transparency = index == target and 0 or 1
		end
		if extraStroke then extraStroke.Transparency = (extra and target == extra.Key) and 0 or 1 end
	end
	local function follow(point)
		local origin = gui.AbsolutePosition
		lifted.block.button.Position = UDim2.fromOffset(point.X - lifted.offset.X - origin.X, point.Y - lifted.offset.Y - origin.Y)
	end

	function startDrag(key, input)
		if lifted then return end
		local block = blocks[key]
		local button = block.button
		local point = pointOf(input)
		local at, size = button.AbsolutePosition, button.AbsoluteSize
		lifted = { key = key, block = block, from = slotOf(key), offset = point - at }
		-- Tirado da lista, ele deixa o espaço vazio até ser solto, para a lista não correr enquanto isso.
		if block.where == "pool" then
			lifted.holder = new("Frame", { BackgroundTransparency = 1, LayoutOrder = button.LayoutOrder, Parent = itemArea })
		end
		button.Parent = gui
		button.Size = UDim2.fromOffset(size.X, size.Y) -- o tamanho que tinha na tela (a janela pode estar em escala)
		button.ZIndex = LIFTED_Z
		button.Visible = true
		block.stroke.Transparency = 0
		follow(point)
		render() -- o slot de onde saiu mostra o que estava embaixo dele (ou fica vazio)
		self._window:_lockScroll(true)
	end

	-- Solta o bloco onde o cursor está (input) ou esteve por último; cancel: volta para onde estava.
	local function endDrag(input, cancel)
		local d = lifted
		if not d then return end
		lifted = nil
		self._window:_lockScroll(false)
		highlight(nil)
		if d.holder then d.holder:Destroy() end
		d.block.button.ZIndex = 1
		d.block.stroke.Transparency = 1
		local target = nil
		if not cancel then
			target = (input and slotAt(pointOf(input))) or (d.lastPoint and slotAt(d.lastPoint))
		end
		if cancel then
			render()
		elseif target and target ~= d.from then
			removeKey(d.key)
			value[target] = value[target] or {}
			table.insert(value[target], 1, d.key) -- por cima da pilha: o que se vê no slot é o que vale
			changed()
		elseif not target and d.from then
			removeKey(d.key) -- tirado de um lugar e solto fora dos slots: volta para a lista
			changed()
		else
			render() -- solto onde estava: volta para o mesmo lugar
		end
	end

	-- Botão direito: esvazia o lugar do bloco (um slot ou a faixa); na lista não faz nada.
	function clearAt(key)
		local slot = slotOf(key)
		if lifted or slot == nil then return end
		value[slot] = nil
		changed()
	end
	for index, s in ipairs(slotCells) do
		s.cell.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 and value[index] and not lifted then
				value[index] = nil
				changed()
			end
		end)
	end
	if extraCell then
		extraCell.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 and value[extra.Key] and not lifted then
				value[extra.Key] = nil
				changed()
			end
		end)
		-- Os quadradinhos mudam de fileira quando a faixa muda de largura.
		extraHolder:GetPropertyChangedSignal("AbsoluteSize"):Connect(sizeExtra)
	end

	self._window:_connect(UserInputService.InputChanged, function(input)
		if lifted and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local point = pointOf(input)
			lifted.lastPoint = point
			follow(point)
			highlight(slotAt(point))
		end
	end)
	self._window:_connect(UserInputService.InputEnded, function(input)
		if lifted and isClick(input) then endDrag(input) end
	end)
	-- O botão solto fora da janela do Roblox não chega aqui: o bloco cai onde o cursor esteve por último.
	self._window:_connect(UserInputService.WindowFocusReleased, function()
		if lifted then endDrag(nil) end
	end)
	-- A janela escondida no meio do arraste (o bloco no ar fica fora dela): ele volta para o lugar.
	self._window:_connect(self._window._shell:GetPropertyChangedSignal("Visible"), function()
		if lifted and not self._window._shell.Visible then endDrag(nil, true) end
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
		-- With buttons in the header the value keeps to the right half, so a long name never covers the title.
		valLbl.Size = visible and UDim2.new(0.5, VALUE_X - actionWidth - 2, 1, 0) or UDim2.new(0.4, 0, 1, 0)
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
	}, { corner(RADIUS - 1) })

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
	}, { corner(RADIUS - 1) })

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
--// Camadas de fundo: dados e desenho (usados pela janela e pelo editor) ---------------------
local MAX_LAYERS = 8
local SCALE_TYPES = { Crop = Enum.ScaleType.Crop, Fit = Enum.ScaleType.Fit, Stretch = Enum.ScaleType.Stretch }

-- Camadas copiadas e limpas; `rank` = ordem de desenho (profundidade, depois a ordem da lista).
local function normalizeLayers(list)
	local layers = {}
	for i, src in ipairs(list or {}) do
		if i > MAX_LAYERS then break end
		layers[i] = {
			Image = src.Image, X = tonumber(src.X) or 0, Y = tonumber(src.Y) or 0,
			W = math.max(tonumber(src.W) or 1, 0.02), H = math.max(tonumber(src.H) or 1, 0.02),
			Depth = math.clamp(tonumber(src.Depth) or 0, 0, 10),
			Transparency = math.clamp(tonumber(src.Transparency) or 0, 0, 1),
			Scale = SCALE_TYPES[src.Scale] and src.Scale or "Crop",
			Fill = typeof(src.Fill) == "Color3" and src.Fill or BLACK,
			FillTransparency = math.clamp(tonumber(src.FillTransparency) or 1, 0, 1),
		}
	end
	local order = {}
	for i in ipairs(layers) do order[i] = i end
	table.sort(order, function(a, b)
		if layers[a].Depth ~= layers[b].Depth then return layers[a].Depth < layers[b].Depth end
		return a < b
	end)
	for z, i in ipairs(order) do layers[i].rank = z end
	return layers
end

-- Uma ImageLabel por camada, reaproveitada entre chamadas (sem piscar ao mexer num controle).
local function syncLayerLabels(labels, layers, parent, zBase)
	for i, layer in ipairs(layers) do
		local label = labels[i]
		if not label then
			label = new("ImageLabel", { BorderSizePixel = 0, Parent = parent })
			labels[i] = label
		end
		local asset = layer.Image and resolveAsset(layer.Image) or ""
		if label.Image ~= asset then label.Image = asset end
		label.ImageTransparency = layer.Transparency
		label.ScaleType = SCALE_TYPES[layer.Scale]
		-- O preenchimento tinge a imagem (por trás dela não aparecia: a imagem cobre o fundo); sem imagem,
		-- a camada é só a cor. Transparência 1 = sem cor.
		if layer.Image then
			label.ImageColor3 = WHITE:Lerp(layer.Fill, 1 - layer.FillTransparency)
			label.BackgroundTransparency = 1
		else
			label.ImageColor3 = WHITE
			label.BackgroundColor3 = layer.Fill
			label.BackgroundTransparency = layer.FillTransparency
		end
		label.ZIndex = zBase + layer.rank
	end
	for i = #layers + 1, #labels do
		labels[i]:Destroy()
		labels[i] = nil
	end
end

-- Editor visual das camadas de fundo, no formato da janela: clicar escolhe a camada (a de cima ganha),
-- arrastar move, a alça no canto redimensiona. A prévia mostra o lugar de cada camada sem parallax.
-- o.OnSelect(index); o.Callback(index, { X, Y, W, H }) a cada movimento.
-- obj:SetLayers(lista, selecionada) com as mesmas camadas de Window:SetBackgroundLayers.
function Section:AddLayerCanvas(o)
	o = o or {}
	local window = self._window
	local MIN_SIZE = 0.05
	local row = new("Frame", {
		Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, LayoutOrder = self:_next(),
		Size = UDim2.new(1, 0, 0, 236), Parent = self._body,
	}, { corner(RADIUS) })
	local area = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 10), Size = UDim2.new(1, -20, 0, 190),
		BackgroundColor3 = "Track", BorderSizePixel = 0, ClipsDescendants = true, Parent = row,
	}, { corner(RADIUS - 1) })
	local aspect = new("UIAspectRatioConstraint", { AspectRatio = 1.42, Parent = area })
	local function syncAspect()
		local size = window._shell.AbsoluteSize
		if size.X > 0 and size.Y > 0 then aspect.AspectRatio = size.X / size.Y end
	end
	window:_connect(window._shell:GetPropertyChangedSignal("AbsoluteSize"), syncAspect)
	syncAspect()

	local readout = new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.new(0, 14, 1, -32), Size = UDim2.new(1, -28, 0, 28),
		Text = "", TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Body, Parent = row,
	})
	-- Contorno e alça da camada escolhida, por cima das prévias.
	local selection = new("Frame", { BackgroundTransparency = 1, Visible = false, ZIndex = 20, Parent = area }, {
		new("UIStroke", { Color = "Accent", Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	local handle = new("TextButton", { -- área de toque de 44 px; o desenho é o quadrado de 12 px no canto
		AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(44, 44),
		BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 21, Parent = selection,
	})
	new("Frame", {
		AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(12, 12),
		BackgroundColor3 = "Accent", BorderSizePixel = 0, ZIndex = 22, Parent = handle,
	})

	local layers, labels, selected = {}, {}, nil
	local obj = { Instance = row }

	local function percent(v) return math.floor(v * 100 + 0.5) .. "%" end
	local function render()
		for i, layer in ipairs(layers) do
			local label = labels[i]
			label.Position = UDim2.fromScale(layer.X, layer.Y)
			label.Size = UDim2.fromScale(layer.W, layer.H)
			-- Camada sem imagem e sem preenchimento ainda precisa aparecer para ser escolhida.
			if not layer.Image and layer.FillTransparency >= 1 then
				label.BackgroundColor3 = Theme.Divider
				label.BackgroundTransparency = 0.5
			end
		end
		local layer = selected and layers[selected]
		selection.Visible = layer ~= nil
		if layer then
			selection.Position = UDim2.fromScale(layer.X, layer.Y)
			selection.Size = UDim2.fromScale(layer.W, layer.H)
			readout.Text = string.format("Layer %d  ·  X %s  ·  Y %s  ·  W %s  ·  H %s",
				selected, percent(layer.X), percent(layer.Y), percent(layer.W), percent(layer.H))
		else
			readout.Text = #layers == 0 and "No layers yet: add one above." or "Click a layer to edit it."
		end
	end

	function obj:SetLayers(list, index)
		layers = normalizeLayers(list)
		syncLayerLabels(labels, layers, area, 0)
		selected = layers[index or 0] and index or nil
		render()
	end
	function obj:Select(index)
		selected = layers[index or 0] and index or nil
		render()
	end

	-- A camada de cima que contém o ponto.
	local function layerAt(point)
		local pos, size = area.AbsolutePosition, area.AbsoluteSize
		local x, y = (point.X - pos.X) / size.X, (point.Y - pos.Y) / size.Y
		local best
		for i, layer in ipairs(layers) do
			local inside = x >= layer.X and x <= layer.X + layer.W and y >= layer.Y and y <= layer.Y + layer.H
			if inside and (not best or layer.rank > layers[best].rank) then best = i end
		end
		return best
	end

	local drag
	local function startDrag(mode, input)
		local layer = layers[selected]
		drag = { mode = mode, start = input.Position, X = layer.X, Y = layer.Y, W = layer.W, H = layer.H }
		window:_lockScroll(true)
	end
	area.InputBegan:Connect(function(input)
		if drag or not isClick(input) then return end
		local hit = layerAt(input.Position)
		if not hit then return end
		if hit ~= selected then
			selected = hit
			render()
			safeCall(o.OnSelect, hit)
		end
		startDrag("move", input)
	end)
	handle.InputBegan:Connect(function(input)
		if not drag and isClick(input) and selected then startDrag("size", input) end
	end)
	window:_connect(UserInputService.InputChanged, function(input)
		if not drag or not layers[selected] then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then return end
		local size = area.AbsoluteSize
		local dx, dy = (input.Position.X - drag.start.X) / size.X, (input.Position.Y - drag.start.Y) / size.Y
		local layer = layers[selected]
		if drag.mode == "move" then
			-- Pelo menos 5% da camada continua dentro da prévia, para dar para pegar de volta.
			layer.X = math.clamp(drag.X + dx, MIN_SIZE - layer.W, 1 - MIN_SIZE)
			layer.Y = math.clamp(drag.Y + dy, MIN_SIZE - layer.H, 1 - MIN_SIZE)
		else
			layer.W = math.clamp(drag.W + dx, MIN_SIZE, 3)
			layer.H = math.clamp(drag.H + dy, MIN_SIZE, 3)
		end
		render()
		safeCall(o.Callback, selected, { X = layer.X, Y = layer.Y, W = layer.W, H = layer.H })
	end)
	window:_connect(UserInputService.InputEnded, function(input)
		if drag and isClick(input) then
			drag = nil
			window:_lockScroll(false)
		end
	end)

	render()
	return obj
end

local function createSection(window, parentContainer, order, o, nested)
	o = type(o) == "string" and { Name = o } or o or {}
	local sec = setmetatable({ _window = window, Name = o.Name or "Section", _n = 0 }, Section)
	local H = nested and ROW_H or 52

	local holder = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order, Parent = parentContainer,
	}, { new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }) })

	sec.Instance = holder -- para esconder a seção inteira (cabeçalho e corpo)

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

-- Grupo fixo dentro de uma seção: um painel recuado, com legenda opcional, que junta controles de uma mesma
-- coisa (um editor e o que pertence a ele) e os separa do resto. Não abre nem fecha. Aceita os mesmos
-- elementos de uma seção.   Retorno: a seção do grupo, com :SetName(texto) para trocar a legenda.
function Section:AddGroup(o)
	o = type(o) == "string" and { Name = o } or o or {}
	local group = setmetatable({ _window = self._window, Name = o.Name or "", _n = 0 }, Section)
	-- Espaço só acima: o grupo se afasta da linha anterior e fica colado na seguinte, que é o ajuste ligado a ele.
	local holder = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_next(), Parent = self._body,
	}, { new("UIPadding", { PaddingTop = UDim.new(0, 6) }) })
	local panel = new("Frame", {
		Surface = "Panel", BackgroundColor3 = "Track", BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = holder,
	}, {
		corner(RADIUS),
		new("UIPadding", {
			PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6),
		}),
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local caption = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 0, Text = group.Name, TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Bold,
		TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Visible = group.Name ~= "", Parent = panel,
	}, { new("UIPadding", {
		PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 2),
	}) })
	group._body = panel
	group.Instance = holder
	function group:SetName(text)
		group.Name = tostring(text or "")
		caption.Text = group.Name
		caption.Visible = group.Name ~= ""
	end
	return group
end

-- Subseção dentro de uma seção (pode aninhar quantas quiser)
function Section:AddSubSection(o)
	return createSection(self._window, self._body, self:_next(), o, true)
end

--// Tab ------------------------------------------------------------------------
function Tab:AddSection(o)
	return createSection(self._window, self._page, self:_next(), o, false)
end

--// Páginas com prévia 3D -----------------------------------------------------------------
-- Uma página por item (na aba Guns, uma por arma) e só a escolhida aparece. Em cima, sem fundo nenhum: o nome da
-- página, a posição dela ("3 / 9") e a prévia 3D; logo embaixo da prévia, uma linha com anterior (à esquerda),
-- próxima (à direita) e, no meio, os controles da prévia: - e + (zoom), Reset e Auto-Rotate. As setas dão a volta:
-- depois da última vem a primeira.
-- A prévia: arrastar gira, a roda do mouse aproxima (com Shift, mais rápido), dois cliques voltam à vista inicial.
-- Auto-Rotate (ligado de início) gira a peça enquanto ninguém mexe; com "Reduzir movimento" do Roblox, não gira.
-- Com o mouse em cima, a roda não rola a página nem mexe na câmera do jogo.
-- o = { Pages = { nomes }, Height = altura da prévia (210), Hint = texto de ajuda no alto da prévia,
--       Changed = function(i, nome) }
-- Retorno: pager:Page(i) (recebe seções e elementos como uma aba), pager:Select(i), pager:Get() -> i, nome,
--          pager:SetModel(model, manterCâmera, centro, tamanho): mostra um Model (ou nada, com nil) e destrói o
--          anterior. O Model chega com o comprimento no eixo Z. A prévia centraliza e enquadra a caixa dada (centro e
--          tamanho, no espaço do Model) ou, sem ela, a do próprio Model.
--          pager:SetHandle(peça, aoMover): uma peça do Model que se move com setas (o ponto de tiro, na aba Guns):
--          duas por eixo do Model, como as do Move do Studio (X vermelho, Y verde, Z azul), sempre do mesmo tamanho
--          na tela. Arrastar uma seta move a peça só ao longo do eixo dela; arrastar fora das setas gira, como sempre.
--          A cada passo, aoMover(posição no espaço do Model, terminou); no fim, terminou = true. Enquanto houver uma,
--          a prévia não gira sozinha. Some com o próximo SetModel ou com SetHandle(nil).
--          pager:SetHint(texto): troca o texto de ajuda (nil volta ao de o.Hint).
--          pager:SetMessage(texto): o que a prévia diz quando não tem Model ("Loading..."); nil volta a "No preview".
local PAGER_YAW, PAGER_PITCH = math.rad(70), math.rad(-12) -- de lado, um pouco de cima
local PAGER_SPIN = math.rad(30)                            -- graus por segundo
local PAGER_FOV = 28                                       -- pouca perspectiva: a ponta que vem não incha
local PAGER_ZOOM = 0.12                                    -- fração por dente da roda
local PAGER_CORNERS = {}
for _, x in ipairs({ -1, 1 }) do
	for _, y in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -1, 1 }) do table.insert(PAGER_CORNERS, Vector3.new(x, y, z) / 2) end
	end
end
local ContextActionService = cloneref(game:GetService("ContextActionService"))

function Tab:AddPager(o)
	o = o or {}
	local window, tab = self._window, self
	local names = o.Pages or {}
	local TITLE_H, COUNT_H, VIEW_H = 34, 18, o.Height or 210

	local holder = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = self:_next(), Parent = self._page,
	}, { new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
	local header = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TITLE_H + COUNT_H + VIEW_H + ROW_H), LayoutOrder = 0,
		Parent = holder,
	})
	local title = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, TITLE_H), Text = "", TextColor3 = "Text", TextSize = 30,
		FontFace = Fonts.Title, TextTruncate = Enum.TextTruncate.AtEnd, Parent = header,
	})
	local count = new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, TITLE_H), Size = UDim2.new(1, 0, 0, COUNT_H), Text = "",
		TextColor3 = "SubText", TextSize = 14, FontFace = Fonts.Medium, Parent = header,
	})

	-- A prévia não tem fundo: a arma fica direto sobre a página. A luz acompanha a câmera.
	local view = new("ViewportFrame", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, TITLE_H + COUNT_H), Size = UDim2.new(1, 0, 0, VIEW_H),
		Ambient = Color3.fromRGB(150, 150, 150), LightColor = Color3.fromRGB(190, 190, 190), Parent = header,
	})
	local camera = new("Camera", { FieldOfView = PAGER_FOV, Parent = view })
	view.CurrentCamera = camera
	local empty = new("TextLabel", {
		BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Text = "No preview", TextColor3 = "SubText",
		TextSize = 15, FontFace = Fonts.Medium, Visible = false, Parent = view,
	})
	local surface = new("TextButton", {
		BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Position = view.Position, Size = view.Size,
		ZIndex = 2, Parent = header,
	})
	local hint = new("TextLabel", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.new(1, -16, 0, 18), Text = o.Hint or "", TextColor3 = "SubText", TextSize = 13,
		FontFace = Fonts.Body, TextTruncate = Enum.TextTruncate.AtEnd, ZIndex = 3, Parent = surface,
	})

	local pager, pages, current = {}, {}, 0
	local model, size = nil, Vector3.one
	local shift = Vector3.zero -- quanto o Model foi deslocado para ficar centralizado
	local yaw, pitch, distance = PAGER_YAW, PAGER_PITCH, 10
	local autoRotate = true
	-- A peça que se move com as setas, quem ouve, a seta sendo arrastada (o índice dela) e o eixo realçado.
	local handlePart, handleMoved, handleDrag, hotAxis = nil, nil, nil, nil
	local arrows = {} -- { dir, color, shaft, tip, from, to }: from e to, onde a seta começa e acaba (espaço da prévia)
	local layoutArrows -- (definida com as setas, mais abaixo)

	local function place()
		local rotation = CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)
		camera.CFrame = CFrame.lookAt(rotation * Vector3.new(0, 0, distance), Vector3.zero)
		local cf = camera.CFrame
		view.LightDirection = (cf.LookVector - cf.UpVector * 0.35 + cf.RightVector * 0.35).Unit
		if layoutArrows then layoutArrows() end -- do mesmo tamanho na tela, com a câmera onde estiver
	end
	-- Distância em que a peça inteira cabe na prévia em qualquer ponto do giro: os cantos da caixa dela, a cada 15
	-- graus, vistos da câmera inclinada. Cada canto pede uma distância (a profundidade dele mais o quanto ele sai
	-- para o lado ou para cima); vale a maior, com uma folga.
	local function fitDistance()
		local px = view.AbsoluteSize
		local tanV = math.tan(math.rad(camera.FieldOfView) / 2)
		local tanH = tanV * ((px.X > 0 and px.Y > 0) and px.X / px.Y or 2.4)
		local tilt = CFrame.Angles(-PAGER_PITCH, 0, 0)
		local need = 0
		for step = 0, 23 do
			local turn = tilt * CFrame.Angles(0, step * math.pi / 12, 0)
			for _, c in ipairs(PAGER_CORNERS) do
				local p = turn * (size * c)
				need = math.max(need, p.Z + math.abs(p.X) / tanH, p.Z + math.abs(p.Y) / tanV)
			end
		end
		return need * 1.06
	end
	local function reset()
		yaw, pitch = PAGER_YAW, PAGER_PITCH
		distance = fitDistance()
		place()
	end
	-- notches > 0 aproxima. Fica entre 0,3x e 4x a distância em que a peça cabe.
	local function zoom(notches)
		local base = fitDistance()
		distance = math.clamp(distance * (1 - PAGER_ZOOM) ^ notches, base * 0.3, base * 4)
		place()
	end

	-- Onde um ponto da prévia (no espaço dela, já centralizado) aparece na tela, e a que distância da câmera.
	local function toScreen(point)
		local p = camera.CFrame:PointToObjectSpace(point)
		local px = view.AbsoluteSize
		if p.Z > -1e-3 or px.X <= 0 or px.Y <= 0 then return nil end
		local tanV = math.tan(math.rad(camera.FieldOfView) / 2)
		local tanH = tanV * px.X / px.Y
		local x, y = p.X / (-p.Z * tanH), p.Y / (-p.Z * tanV)
		return view.AbsolutePosition + Vector2.new((x + 1) / 2 * px.X, (1 - y) / 2 * px.Y), -p.Z
	end
	-- A posição de um clique no espaço de AbsolutePosition. O clique caiu na prévia (é dela o InputBegan): se ele
	-- não cai dentro dela sem a faixa de cima do Roblox, a faixa é somada.
	local function clickPoint(i)
		local pos = Vector2.new(i.Position.X, i.Position.Y)
		if insideGui(surface, pos) then return pos end
		local ok, inset = pcall(GuiService.GetGuiInset, GuiService)
		return ok and pos + inset or pos
	end
	-- As setas: duas por eixo, nas cores do Move do Studio, para quem já conhece o Studio reconhecer de cara qual eixo
	-- cada uma move. Comprimento, espessura e ponta em pixels da tela, na distância em que a peça está.
	local ARROW_AXES = {
		{ Vector3.xAxis, Color3.fromRGB(235, 80, 80) }, { -Vector3.xAxis, Color3.fromRGB(235, 80, 80) },
		{ Vector3.yAxis, Color3.fromRGB(90, 205, 110) }, { -Vector3.yAxis, Color3.fromRGB(90, 205, 110) },
		{ Vector3.zAxis, Color3.fromRGB(80, 145, 245) }, { -Vector3.zAxis, Color3.fromRGB(80, 145, 245) },
	}
	local ARROW_LENGTH, ARROW_WIDTH, ARROW_TIP, ARROW_REACH = 30, 3, 10, 10 -- px; REACH: até onde um clique pega
	local WHITE = Color3.new(1, 1, 1)
	-- Um CFrame com o eixo X ao longo de dir (o comprimento de um Cylinder fica no X dele).
	local function alongX(at, dir)
		local up = math.abs(dir.Y) > 0.9 and Vector3.xAxis or Vector3.yAxis
		local z = dir:Cross(up).Unit
		return CFrame.fromMatrix(at, dir, z:Cross(dir).Unit, z)
	end
	-- Quantos studs um pixel da tela cobre na distância de um ponto da prévia.
	local function studsPerPixel(point)
		local depth = math.max(-camera.CFrame:PointToObjectSpace(point).Z, 1e-3)
		return 2 * depth * math.tan(math.rad(camera.FieldOfView) / 2) / math.max(view.AbsoluteSize.Y, 1)
	end
	layoutArrows = function()
		if not (handlePart and handlePart.Parent and #arrows > 0) then return end
		local origin = handlePart.Position
		local unit = studsPerPixel(origin)
		local gap = handlePart.Size.X / 2 + 2 * unit
		for index, arrow in ipairs(arrows) do
			local from = origin + arrow.dir * gap
			local to = from + arrow.dir * ARROW_LENGTH * unit
			arrow.from, arrow.to = from, to
			arrow.shaft.Size = Vector3.new(ARROW_LENGTH * unit, ARROW_WIDTH * unit, ARROW_WIDTH * unit)
			arrow.shaft.CFrame = alongX((from + to) / 2, arrow.dir)
			arrow.tip.Size = Vector3.one * ARROW_TIP * unit
			arrow.tip.CFrame = CFrame.new(to)
			-- o eixo sob o mouse (ou sendo arrastado) clareia: as duas setas dele, sem perder a cor do eixo
			local color = math.ceil(index / 2) == hotAxis and arrow.color:Lerp(WHITE, 0.35) or arrow.color
			arrow.shaft.Color, arrow.tip.Color = color, color
		end
	end
	local function setHot(index)
		local axis = index and math.ceil(index / 2) or nil
		if axis == hotAxis then return end
		hotAxis = axis
		layoutArrows()
	end
	local function clearArrows()
		for _, arrow in ipairs(arrows) do
			arrow.shaft:Destroy()
			arrow.tip:Destroy()
		end
		table.clear(arrows)
		hotAxis = nil
	end
	local function buildArrows()
		clearArrows()
		if not handlePart then return end
		for _, spec in ipairs(ARROW_AXES) do
			local arrow = { dir = spec[1], color = spec[2] }
			for _, key in ipairs({ "shaft", "tip" }) do
				local part = Instance.new("Part")
				part.Name = "Arrow"
				part.Shape = key == "shaft" and Enum.PartType.Cylinder or Enum.PartType.Ball
				part.Material = Enum.Material.SmoothPlastic -- Neon, numa prévia, estoura a cor (o verde sai branco)
				part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.CastShadow = true, false, false, false, false
				part.Parent = model
				arrow[key] = part
			end
			table.insert(arrows, arrow)
		end
		layoutArrows()
	end
	-- A seta mais perto de um ponto da tela, até ARROW_REACH px dela (do corpo à ponta), ou nil. Em cima da própria
	-- peça, nenhuma: ali as seis se encontram e o clique gira a prévia.
	local function arrowAt(point)
		if not (handlePart and handlePart.Parent) then return nil end
		local center = toScreen(handlePart.Position)
		if center and (point - center).Magnitude <= handlePart.Size.X / 2 / studsPerPixel(handlePart.Position) + 2 then
			return nil
		end
		local best, bestDistance
		for index, arrow in ipairs(arrows) do
			local a, b = arrow.from and toScreen(arrow.from), arrow.to and toScreen(arrow.to)
			if a and b then
				local ab = b - a
				local t = ab.Magnitude > 1e-3 and math.clamp((point - a):Dot(ab) / ab:Dot(ab), 0, 1) or 0
				local away = (point - (a + ab * t)).Magnitude
				if away <= ARROW_REACH + ARROW_TIP / 2 and (bestDistance == nil or away < bestDistance) then
					best, bestDistance = index, away
				end
			end
		end
		return best
	end
	local function finishHandle()
		local drag = handleDrag
		handleDrag = nil
		setHot(nil)
		if drag and handlePart and handlePart.Parent and handleMoved then
			safeCall(handleMoved, handlePart.Position + shift, true)
		end
	end

	-- Arrastar gira (ou move a peça, começando numa seta); a página não rola enquanto isso (no toque, arrastar
	-- rolaria).
	local dragging, lastPos, lastClick = false, nil, 0
	surface.InputBegan:Connect(function(i)
		if not isClick(i) or dragging then return end
		local index = handlePart and handlePart.Parent and arrowAt(clickPoint(i)) or nil
		if index then
			handleDrag = index
			setHot(index)
			lastClick = 0
		else
			local now = os.clock()
			if now - lastClick < 0.35 then reset() end
			lastClick = now
		end
		dragging, lastPos = true, i.Position
		window:_lockScroll(true)
	end)
	local function stopDragging()
		if not dragging then return end
		dragging = false
		finishHandle()
		window:_lockScroll(false)
	end
	window:_connect(UserInputService.InputEnded, function(i)
		if isClick(i) then stopDragging() end
	end)

	-- Com o mouse em cima, a roda é da prévia: a página não rola e a câmera do jogo não aproxima (a ação de
	-- prioridade alta engole a roda antes dela).
	local WHEEL_ACTION = "CW_PreviewWheel_" .. tostring(math.random(1, 1e9))
	local hovered = false
	local function setHovered(on)
		if hovered == on then return end
		hovered = on
		window:_lockScroll(on)
		pcall(function()
			if on then
				ContextActionService:BindActionAtPriority(WHEEL_ACTION, function() return Enum.ContextActionResult.Sink end,
					false, Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseWheel)
			else
				ContextActionService:UnbindAction(WHEEL_ACTION)
			end
		end)
	end
	surface.MouseEnter:Connect(function() setHovered(true) end)
	surface.MouseLeave:Connect(function() setHovered(false) end)
	view.Destroying:Connect(function() setHovered(false) end)

	window:_connect(UserInputService.InputChanged, function(i)
		if i.UserInputType == Enum.UserInputType.MouseWheel then
			if hovered then
				zoom(i.Position.Z * (UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) and 3 or 1))
			end
		elseif not dragging and hovered and handlePart and i.UserInputType == Enum.UserInputType.MouseMovement then
			setHot(arrowAt(clickPoint(i))) -- a seta sob o mouse clareia
		elseif dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
			local delta = i.Position - lastPos
			lastPos = i.Position
			if handleDrag then
				-- A peça anda ao longo da seta: o quanto o mouse andou na direção em que a seta aparece na tela.
				local arrow = arrows[handleDrag]
				if not (arrow and handlePart and handlePart.Parent) then return end
				local a, b = toScreen(arrow.from), toScreen(arrow.to)
				if not (a and b) then return end
				local perStud = (b - a) / math.max((arrow.to - arrow.from).Magnitude, 1e-6) -- px por stud, na tela
				-- um eixo que aponta para a câmera quase não aparece: andar nele pularia longe
				if perStud.Magnitude < 0.2 / studsPerPixel(handlePart.Position) then return end
				local moved = Vector2.new(delta.X, delta.Y):Dot(perStud) / perStud:Dot(perStud)
				handlePart.Position += arrow.dir * moved
				layoutArrows()
				if handleMoved then safeCall(handleMoved, handlePart.Position + shift, false) end
				return
			end
			yaw -= delta.X * 0.01
			pitch = math.clamp(pitch - delta.Y * 0.01, -1.4, 1.4)
			place()
		end
	end)

	-- Escondida (a janela fechou, outra aba) sem o mouse sair: solta a roda e o arraste.
	window:_connect(RunService.RenderStepped, function(dt)
		local shown = window._shell.Visible and window._selected == tab
		if not shown then
			setHovered(false)
			stopDragging()
			return
		end
		if not model or dragging or handlePart or not autoRotate or reducedMotion() then return end
		yaw += PAGER_SPIN * math.min(dt, 0.1)
		place()
	end)

	for index, name in ipairs(names) do
		local frame = new("Frame", {
			BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = index, Visible = false, Parent = holder,
		}, { new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
		pages[index] = setmetatable({ _window = window, Name = tostring(name), _n = 0, _page = frame, _body = frame }, Tab)
	end

	local function select(index)
		if #names == 0 then return end
		index = (index - 1) % #names + 1
		current = index
		for i, page in ipairs(pages) do page._page.Visible = i == index end
		title.Text = tostring(names[index]):upper()
		count.Text = index .. " / " .. #names
		safeCall(o.Changed, index, names[index])
	end

	-- A linha embaixo da prévia: setas nas pontas (placas como as linhas da interface, com a seta desenhada) e os
	-- controles da prévia no meio.
	local function navButton(anchorX, step)
		local hit = new("TextButton", {
			BackgroundTransparency = 1, Text = "", AutoButtonColor = false, AnchorPoint = Vector2.new(anchorX, 1),
			Position = UDim2.new(anchorX, 0, 1, 0), Size = UDim2.fromOffset(ROW_H, ROW_H), Parent = header,
		})
		local face = new("Frame", {
			Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(ROW_H - 4, ROW_H - 4), Parent = hit,
		}, { corner(RADIUS) })
		makeChevron(face, UDim2.fromScale(0.5, 0.5), 0.9, "Text").Rotation = step < 0 and 90 or -90
		hoverColors(hit, face, "Item", "ItemHover")
		hit.MouseButton1Click:Connect(function() select(current + step) end)
	end
	navButton(0, -1)
	navButton(1, 1)

	local tools = new("Frame", {
		BackgroundTransparency = 1, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(0, ROW_H), AutomaticSize = Enum.AutomaticSize.X, Parent = header,
	}, {
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Center,
		}),
	})
	local function toolButton(order, text, width, onClick)
		local hit, face = smallButton(tools, text, width)
		hit.LayoutOrder = order
		hit.MouseButton1Click:Connect(onClick)
		return face
	end
	toolButton(1, "-", 30, function() zoom(-2) end)
	toolButton(2, "+", 30, function() zoom(2) end)
	toolButton(3, "Reset", 54, reset)
	local spinFace
	spinFace = toolButton(4, "Auto-Rotate", 92, function()
		autoRotate = not autoRotate
		paint(spinFace, "TextColor3", autoRotate and "Text" or "SubText") -- apagado = desligado
	end)

	function pager:Page(index) return pages[index] end
	function pager:Get() return current, names[current] end
	function pager:Select(index) select(index) end
	-- manterCâmera: a mesma vista (o giro e o zoom, na proporção do tamanho novo).
	function pager:SetModel(newModel, keepCamera, frameCenter, frameSize)
		-- Um arraste de seta em curso termina aqui (quem ouve recebe o fim), antes que a peça suma com o Model.
		if dragging and handleDrag then stopDragging() end
		local zoomed = model and distance / fitDistance() or 1
		if model then model:Destroy() end
		model = newModel
		handlePart, handleMoved, handleDrag = nil, nil, nil
		table.clear(arrows) -- foram embora com o Model antigo
		hotAxis = nil
		shift = Vector3.zero
		empty.Visible = newModel == nil
		if not newModel then return end
		if not (frameCenter and frameSize) then
			local ok, cf, bounds = pcall(newModel.GetBoundingBox, newModel)
			if ok then frameCenter, frameSize = cf.Position, bounds end
		end
		if frameCenter and pcall(newModel.TranslateBy, newModel, -frameCenter) then shift = frameCenter end
		size = frameSize or size
		newModel.Parent = view
		if keepCamera then
			distance = fitDistance() * zoomed
			place()
		else
			reset()
		end
	end

	function pager:SetHandle(part, onMove)
		local valid = typeof(part) == "Instance" and part:IsA("BasePart") and model ~= nil and part:IsDescendantOf(model)
		handlePart = valid and part or nil
		handleMoved = valid and onMove or nil
		handleDrag = nil
		buildArrows()
	end
	function pager:SetHint(text)
		hint.Text = text or o.Hint or ""
	end
	function pager:SetMessage(text)
		empty.Text = text or "No preview"
	end

	-- A primeira página aparece já; a prévia ajusta a distância quando a página ganha tamanho.
	view:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if model then reset() end
	end)
	select(1)
	return pager
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
		tween(btn, { BackgroundTransparency = Palette.SelectorTransparency }, 0.12)
		tween(label, { TextColor3 = "Text" }, 0.12)
	end)
	btn.MouseLeave:Connect(function()
		if active() then return end
		tween(btn, { BackgroundTransparency = 1 }, 0.12)
		tween(label, { TextColor3 = "SubText" }, 0.12)
	end)
end

-- Aba ativa = placa na cor do seletor (o destaque, se não escolhida) com texto contrastante.
-- Só a aba ativa entra no registro de transparência; as outras ficam transparentes até o hover.
function Window:SelectTab(tab)
	local changed = self._selected ~= tab
	for _, t in ipairs(self._tabs) do
		local on = (t == tab)
		t._page.Visible = on
		t._page.ScrollingEnabled = self._scrollLocks == 0
		surfaces[t._btn] = on and "Selector" or nil
		tween(t._btn, {
			BackgroundTransparency = on and Palette.SelectorTransparency or 1,
			BackgroundColor3 = on and "Selector" or "TabHover",
		}, 0.15)
		tween(t._label, { TextColor3 = on and "OnSelector" or "SubText" }, 0.15)
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

function Window:SetVisible(v)
	self._shell.Visible = v
	if not v and self._dialog then self._dialog.close() end -- a question can't wait behind a hidden window
end
function Window:Toggle() self:SetVisible(not self._shell.Visible) end

-- A line over the content for what the host needs the player to know (CycleWare: the parts that did not load).
-- SetNotice(nil) or its Dismiss button takes it away; the pages move down while it shows.
local NOTICE_H = 56
function Window:SetNotice(text)
	if self._notice then
		self._notice:Destroy()
		self._notice = nil
	end
	local content, sidebarW = self._content, self._sidebarW or 164
	local function place(offset)
		content.Position = UDim2.fromOffset(sidebarW, offset)
		content.Size = UDim2.new(1, -sidebarW, 1, -offset)
	end
	if type(text) ~= "string" or text == "" then
		place(0)
		return
	end
	local notice = new("Frame", {
		Name = "Notice", Position = UDim2.fromOffset(sidebarW + 8, 8), Size = UDim2.new(1, -(sidebarW + 16), 0, NOTICE_H - 12),
		Surface = "Panel", BackgroundColor3 = "Item", BorderSizePixel = 0, Parent = self._shell,
	}, { corner(RADIUS) })
	new("Frame", { -- the orange edge: something to read
		Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = "Accent", BorderSizePixel = 0, Parent = notice,
	}, { corner(RADIUS) })
	new("TextLabel", { -- a longer text gets smaller instead of running out of the box
		BackgroundTransparency = 1, Position = UDim2.fromOffset(14, 4), Size = UDim2.new(1, -120, 1, -8),
		Text = text, TextColor3 = "Text", TextScaled = true, FontFace = Fonts.Medium, TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center, Parent = notice,
	}, { new("UITextSizeConstraint", { MaxTextSize = 14, MinTextSize = 10 }) })
	local dismiss = smallButton(notice, "Dismiss", 88, 2)
	dismiss.AnchorPoint = Vector2.new(1, 0.5)
	dismiss.Position = UDim2.new(1, -8, 0.5, 0)
	dismiss.MouseButton1Click:Connect(function() self:SetNotice(nil) end)
	self._notice = notice
	place(NOTICE_H)
end

--// Confirmation -------------------------------------------------------------------
-- A question in front of the window: a card with the title ("Are you sure you want to ...?"), a close button (X),
-- Cancel and Confirm. Meanwhile the screen behind is dimmed and takes no clicks, and the game behind is blurred: a
-- BlurEffect on the camera, which Roblox applies to the 3D view only (interface is never blurred), so the window
-- behind is dimmed instead. Cancel, the X and hiding the window close it without confirming. One at a time: a new
-- question replaces the one showing.
-- Confirm({ Title = text, ConfirmText = "Confirm", CancelText = "Cancel", OnConfirm = fn, OnCancel = fn })
-- Returns { close = function() } (closes it without confirming).
local DIALOG_W, DIALOG_Z, DIALOG_BLUR = 380, 100, 12
local function dialogButton(parent, text, primary, order)
	local hit = new("TextButton", {
		BackgroundTransparency = 1, Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(104, ROW_H),
		LayoutOrder = order, Parent = parent,
	})
	local face = new("TextLabel", {
		AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 32),
		BackgroundColor3 = primary and "Accent" or "Track", BorderSizePixel = 0, Text = text,
		TextColor3 = primary and "OnAccent" or "Text", TextSize = 15, FontFace = Fonts.Bold, Parent = hit,
	}, { corner(RADIUS) })
	if primary then
		-- the accent has no lighter role: the face lightens through its transparency instead
		hit.MouseEnter:Connect(function() tween(face, { BackgroundTransparency = 0.12 }, 0.12) end)
		hit.MouseLeave:Connect(function() tween(face, { BackgroundTransparency = 0 }, 0.12) end)
	else
		hoverColors(hit, face, "Track", "Header")
	end
	return hit
end

function Window:Confirm(o)
	o = type(o) == "table" and o or { Title = tostring(o) }
	if self._dialog then self._dialog.close() end
	self:_popupOpening(nil) -- an open dropdown or color picker closes
	local gui, shell = self._gui, self._shell
	local conns, closed = {}, false
	local dialog = {}

	-- The whole screen: dimmed, and it keeps clicks from the window and the game (Modal frees the mouse in first
	-- person, as the window does).
	local scrim = new("TextButton", {
		Name = "Confirm", Text = "", AutoButtonColor = false, Active = true, Modal = true,
		BackgroundColor3 = "Track", BackgroundTransparency = 1, BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1), ZIndex = DIALOG_Z, Parent = gui,
	})
	local card = new("Frame", {
		Name = "Card", AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(DIALOG_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = "Item", BorderSizePixel = 0, ZIndex = 2,
		Parent = scrim,
	}, {
		corner(RADIUS + 2),
		new("UIStroke", { Color = "Divider", Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }),
	})
	local scale = new("UIScale", { Scale = 0.96, Parent = card })
	new("Frame", { -- the orange edge, as on the notice: something to read
		Size = UDim2.new(0, 3, 1, 0), BackgroundColor3 = "Accent", BorderSizePixel = 0, Parent = card,
	}, { corner(RADIUS) })
	local body = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = card,
	}, {
		new("UIPadding", {
			PaddingLeft = UDim.new(0, 20), PaddingRight = UDim.new(0, 12), PaddingTop = UDim.new(0, 12),
			PaddingBottom = UDim.new(0, 8),
		}),
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	-- Title and the X
	local top = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1, Parent = body,
	})
	new("TextLabel", {
		BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, -44, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y, Text = o.Title or "Are you sure?", TextColor3 = "Text", TextSize = 17,
		LineHeight = 1.1, FontFace = Fonts.Bold, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	}, { new("UIPadding", { PaddingBottom = UDim.new(0, 6) }) })
	local x = new("TextButton", {
		AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(32, 32),
		BackgroundColor3 = "Track", BackgroundTransparency = 1, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
		Parent = top,
	}, { corner(RADIUS) })
	for _, angle in ipairs({ 45, -45 }) do
		new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 2),
			Rotation = angle, BackgroundColor3 = "SubText", BorderSizePixel = 0, Parent = x,
		}, { corner(1) })
	end
	x.MouseEnter:Connect(function() tween(x, { BackgroundTransparency = 0 }, 0.12) end)
	x.MouseLeave:Connect(function() tween(x, { BackgroundTransparency = 1 }, 0.12) end)

	-- Cancel and Confirm, on the right
	local row = new("Frame", {
		BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, ROW_H), LayoutOrder = 2, Parent = body,
	}, { new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder,
	}) })
	local cancel = dialogButton(row, o.CancelText or "Cancel", false, 1)
	local confirm = dialogButton(row, o.ConfirmText or "Confirm", true, 2)

	-- In the middle of the window, wherever it is, and never wider than it.
	local function place()
		local at, size, origin = shell.AbsolutePosition, shell.AbsoluteSize, scrim.AbsolutePosition
		card.Position = UDim2.fromOffset(at.X - origin.X + size.X / 2, at.Y - origin.Y + size.Y / 2)
		card.Size = UDim2.fromOffset(math.max(math.min(DIALOG_W, size.X - 32), 200), 0)
	end
	place()
	table.insert(conns, shell:GetPropertyChangedSignal("AbsolutePosition"):Connect(place))
	table.insert(conns, shell:GetPropertyChangedSignal("AbsoluteSize"):Connect(place))

	local blur
	pcall(function()
		local camera = workspace.CurrentCamera
		if not camera then return end
		blur = Instance.new("BlurEffect")
		blur.Name = "CW_ConfirmBlur"
		blur.Size = 0
		blur.Parent = camera
	end)

	local function close(confirmed)
		if closed then return end
		closed = true
		if self._dialog == dialog then self._dialog = nil end
		for _, c in ipairs(conns) do c:Disconnect() end
		self:_lockScroll(false)
		card.Visible = false
		tween(scrim, { BackgroundTransparency = 1 }, 0.12)
		if blur then tween(blur, { Size = 0 }, 0.12) end
		task.delay(0.15, function()
			scrim:Destroy()
			if blur then blur:Destroy() end
		end)
		safeCall(confirmed and o.OnConfirm or o.OnCancel)
	end
	dialog.close = function() close(false) end
	self._dialog = dialog
	self:_lockScroll(true)
	x.MouseButton1Click:Connect(function() close(false) end)
	cancel.MouseButton1Click:Connect(function() close(false) end)
	confirm.MouseButton1Click:Connect(function() close(true) end)

	tween(scrim, { BackgroundTransparency = 0.45 }, 0.15)
	tween(scale, { Scale = 1 }, 0.15)
	if blur then tween(blur, { Size = DIALOG_BLUR }, 0.2) end
	return dialog
end

--// Camadas de fundo com parallax ------------------------------------------------
-- Adaptado do editor de camadas do Iterator Meadow e do parallax estilo Rain World, com estas mudanças:
--   * posição e tamanho em frações da janela (a referência usava pixels de uma prévia 399x280 e
--     recalculava atributos a cada redimensionamento);
--   * uma câmera só, com aproximação exponencial independente do FPS (a referência suavizava duas vezes
--     com fator fixo por quadro: mais lenta a 30 FPS, mais rápida a 144);
--   * nada é lido de atributos a cada quadro, e nada é escrito quando a câmera não andou;
--   * a ordem de desenho segue a profundidade (a referência prometia isso, mas desenhava na ordem de criação).
-- Camada: { Image = ID/caminho, X, Y, W, H (frações da janela), Depth = 0..10, Transparency = 0..1,
--           Scale = "Crop" | "Fit" | "Stretch", Fill = Color3 (tinge a imagem; sem imagem, preenche),
--           FillTransparency = 0..1 (1 = sem cor) }
-- Profundidade 0 fica parada; quanto maior, mais anda e mais à frente é desenhada.
local PARALLAX_SPEED = 5 -- quão rápido a câmera alcança o mouse (o mesmo valor da referência)
CW.MaxLayers = MAX_LAYERS

-- Quanto a camada anda (fração da janela) com a câmera no limite.
local function travel(layer, strength) return strength * layer.Depth / 5 end
-- Uma camada que cobre a janela inteira cresce o quanto anda, para a borda nunca aparecer.
local function coversWindow(l) return l.X <= 0 and l.Y <= 0 and l.X + l.W >= 1 and l.Y + l.H >= 1 end

function Window:SetBackgroundLayers(list)
	self._layers = normalizeLayers(list)
	syncLayerLabels(self._layerLabels, self._layers, self._backdrop, 0)
	self._backdrop.Visible = #self._layers > 0
	self:_sizeLayers()
end

-- Tamanho (só muda com as camadas ou a força) e posição com a câmera atual.
function Window:_sizeLayers()
	local p = self._parallax
	p.maxTravel = 0
	for i, layer in ipairs(self._layers) do
		layer.travel = p.enabled and travel(layer, p.strength) or 0
		layer.grow = coversWindow(layer) and layer.travel or 0
		p.maxTravel = math.max(p.maxTravel, layer.travel)
		self._layerLabels[i].Size = UDim2.fromScale(layer.W + 2 * layer.grow, layer.H + 2 * layer.grow)
	end
	self:_placeLayers()
end

-- Sem arredondar: posição fracionária evita o "degrau" em movimento lento.
function Window:_placeLayers()
	local p = self._parallax
	for i, layer in ipairs(self._layers) do
		self._layerLabels[i].Position = UDim2.fromScale(
			layer.X - layer.grow - p.x * layer.travel, layer.Y - layer.grow - p.y * layer.travel)
	end
	p.shownX, p.shownY = p.x, p.y
end

-- strength = quanto uma camada de profundidade 5 anda, em fração da janela (0 a 0.1).
-- hoverOnly = a câmera volta ao centro quando o mouse sai da janela.
function Window:SetParallax(enabled, strength, hoverOnly)
	local p = self._parallax
	p.enabled = enabled == true
	p.hoverOnly = hoverOnly == true
	if strength then p.strength = math.clamp(strength, 0, 0.1) end
	if not p.enabled then p.x, p.y = 0, 0 end
	self:_sizeLayers()
end

function Window:_stepParallax(dt)
	local p = self._parallax
	if not (p.enabled and p.maxTravel > 0 and self._backdrop.Visible and self._shell.Visible) then return end
	local pos, size = self._shell.AbsolutePosition, self._shell.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then return end
	local mouse = UserInputService:GetMouseLocation()
	local tx, ty = (mouse.X - pos.X) / size.X * 2 - 1, (mouse.Y - pos.Y) / size.Y * 2 - 1
	if p.hoverOnly and (math.abs(tx) > 1 or math.abs(ty) > 1) then
		tx, ty = 0, 0
	end
	tx, ty = math.clamp(tx, -1, 1), math.clamp(ty, -1, 1)
	local follow = 1 - math.exp(-PARALLAX_SPEED * math.min(dt, 0.05)) -- dt limitado: sem salto após um travamento
	p.x += (tx - p.x) * follow
	p.y += (ty - p.y) * follow
	-- Menos de 1/20 de pixel na camada que mais anda: não escreve (o CanvasGroup não redesenha à toa).
	local limit = 0.05 / math.max(size.X, size.Y) / p.maxTravel
	if math.abs(p.x - p.shownX) < limit and math.abs(p.y - p.shownY) < limit then return end
	self:_placeLayers()
end

function Window:Destroy()
	self._destroyed = true
	if self._dialog then self._dialog.close() end -- its blur is on the camera, outside the window's GUI
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
	if protectGui then pcall(protectGui, gui) end
	-- The first container that takes it: the executor's hidden one, CoreGui, then the player's own.
	local containers = {}
	if gethui then
		local ok, hidden = pcall(gethui)
		if ok and typeof(hidden) == "Instance" then table.insert(containers, hidden) end
	end
	table.insert(containers, CoreGui)
	local localPlayer = game:GetService("Players").LocalPlayer
	local playerGui = localPlayer and localPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then table.insert(containers, playerGui) end
	for _, container in ipairs(containers) do
		if pcall(function() gui.Parent = container end) and gui.Parent == container then break end
	end
	if not gui.Parent then error("no container accepted the window", 0) end
	self._gui = gui

	local WIN_R, SIDEBAR_W, LOGO_H, FOOTER_H, INSET = 6, 164, 72, 58, 6
	local baseSize = cfg.Size or UDim2.fromOffset(712, 500)

	-- Active = true: clicar na janela não "atravessa" para o jogo (não atira).
	local window = new("Frame", {
		Name = "Window", Active = true, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5),
		Size = baseSize, Surface = "Background", BackgroundColor3 = "Content", BorderSizePixel = 0, Parent = gui,
	}, { corner(WIN_R) })
	self._shell = window

	-- Camadas de fundo (opcionais), entre a cor da janela e o conteúdo. O CanvasGroup é o único contêiner que
	-- recorta com cantos arredondados, e com parallax as camadas passam das bordas da janela.
	self._backdrop = new("CanvasGroup", {
		Name = "Backdrop", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 0,
		Parent = window,
	}, { corner(WIN_R) })
	self._layers, self._layerLabels = {}, {}
	self._parallax = { enabled = false, hoverOnly = false, strength = 0.03, x = 0, y = 0, shownX = 0, shownY = 0, maxTravel = 0 }
	self:_connect(RunService.PreRender, function(dt) self:_stepParallax(dt) end)

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
	self._sidebarW = SIDEBAR_W

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
