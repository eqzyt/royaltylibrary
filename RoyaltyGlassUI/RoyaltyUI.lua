-- ============================================================================
-- Royalty Glass UI (standalone Luau executor library) - liquid glass shell with chroma waves.
-- Pages: Access Key (name + owner-issued key) <-> Register, then an expanded member workspace.
-- Works in an executor or as a LocalScript (falls back to PlayerGui).
--
-- Owner hooks (see CONFIG): OnAuthenticated(name), Backend (swap the local store for your server),
-- getgenv().GlassUI.Notify(kind, text, seconds), getgenv().GlassUI_User (name after a successful entry).
-- Runtime extension API: getgenv().GlassUI.UI (CreatePage, CreateSection, CreateButton, CreateToggle,
-- CreateDropdown/CreateSelect, CreateSlider, CreateTextBox and CreateLabel).
-- ============================================================================

local USE_SCREEN_BLUR = true -- BlurEffect on the 3D scene behind the panel
local CHROMA_IN_PANEL = true -- chroma waves inside the panel, replacing the white frosted fill
local CLOSE_ICON_AS_X = true -- true: the circle-plus is pre-rotated 45deg so it reads as an X; false: the exact plus
local CLOSE_SIZE = 34 -- pixels (the original Uiverse button is 50)

local CONFIG = {
	StoreFile = "GlassUI_Accounts.json", -- local demo store (executor writefile); in-memory otherwise
	PrefsFile = "GlassUI_Prefs.json", -- last name + chroma color
	BindToRobloxAccount = true, -- a key only works for the Roblox account that registered it
	MinNameLength = 3,
	MaxNameLength = 20,
	MinKeyLength = 4,
	MaxAttempts = 5, -- wrong entries before the lockout
	LockoutSeconds = 30,
	CloseOnSuccess = false, -- close the panel after a successful entry (false while you test the look)
	OnAuthenticated = function(name)
		print("[GlassUI] authenticated:", name) -- plug your loader here
	end,
}

-- Chroma waves settings. Approximation: the original is a paywalled shader, only its description and
-- prop defaults (white waves on #8B5CF6, speed 0.5, chroma shift 0.25) were visible.
local BG = {
	BackgroundColor = Color3.fromHex("#8B5CF6"), -- changed live from the Settings page
	WaveColor = Color3.fromHex("#FFFFFF"),
	Speed = 0.5,
	WaveCount = 1.6, -- wave cycles across the panel width
	Amplitude = 0.2, -- fraction of the field height
	Distortion = 1.5,
	ChromaShift = 0.25,
	Opacity = 1, -- master opacity of the waves
	Columns = 96, -- horizontal resolution of the waves (lower = faster, steppier)
	UpdateHz = 30,
	FrostTop = 0.80, -- transparency of the white frost overlay at the top of the panel (lower = more frost)
	FrostBottom = 0.94, -- ... and at the bottom
}
local DEFAULT_CHROMA = Color3.fromHex("#8B5CF6")

local PANEL_W = 400
local MAIN_W, MAIN_H = 860, 530
local HEIGHTS = { access = 300, register = 370, settings = 420, loading = MAIN_H, dashboard = MAIN_H }

local genv = (getgenv and getgenv()) or _G
if genv.GlassUI_Destroy then
	pcall(genv.GlassUI_Destroy)
end

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local HttpService = game:GetService("HttpService")
local LocalPlayer = Players.LocalPlayer

local oldBlur = Lighting:FindFirstChild("GlassUIBlur")
if oldBlur then oldBlur:Destroy() end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local ERROR_COLOR = Color3.fromRGB(255, 120, 120)
local OK_COLOR = Color3.fromRGB(140, 255, 180)
local FAST = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local QUICK = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local activeTweens = setmetatable({}, { __mode = "k" })
local transitionToken = 0
local loadingToken = 0

local function cancelTweenConflicts(obj, props)
	local running = activeTweens[obj]
	if not running then return end
	for index = #running, 1, -1 do
		local item = running[index]
		local conflicts = false
		for property in pairs(props) do
			if item.properties[property] ~= nil then conflicts = true; break end
		end
		if conflicts then
			pcall(function() item.tween:Cancel() end)
			local currentIndex = table.find(running, item)
			if currentIndex then table.remove(running, currentIndex) end
		end
	end
	if #running == 0 then activeTweens[obj] = nil end
end

local function tween(obj, info, props)
	cancelTweenConflicts(obj, props)
	local running = activeTweens[obj]
	local t = TweenService:Create(obj, info, props)
	running = running or {}
	activeTweens[obj] = running
	local item = { tween = t, properties = props }
	table.insert(running, item)
	local completedConnection
	completedConnection = t.Completed:Connect(function()
		if completedConnection then completedConnection:Disconnect() end
		local currentItems = activeTweens[obj]
		if currentItems then
			local index = table.find(currentItems, item)
			if index then table.remove(currentItems, index) end
			if #currentItems == 0 then activeTweens[obj] = nil end
		end
	end)
	t:Play()
	return t
end

local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
	return c
end

local function stroke(parent, transparency, thickness, color)
	local s = Instance.new("UIStroke")
	s.Color = color or WHITE
	s.Transparency = transparency
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function trim(s)
	return string.match(tostring(s or ""), "^%s*(.-)%s*$")
end

-- ---------------------------------------------------------------------------
-- Local store (demo backend) + preferences
-- ---------------------------------------------------------------------------
local function readJson(path)
	if not (readfile and isfile) then return nil end
	local ok, data = pcall(function()
		if isfile(path) then
			return HttpService:JSONDecode(readfile(path))
		end
	end)
	if ok and type(data) == "table" then return data end
	return nil
end

local function writeJson(path, data)
	if not writefile then return false end
	local ok = pcall(function()
		writefile(path, HttpService:JSONEncode(data))
	end)
	return ok
end

local accounts = readJson(CONFIG.StoreFile) or {}
local prefs = readJson(CONFIG.PrefsFile) or {}
local toggleKey = Enum.KeyCode.RightShift
if type(prefs.toggleKey) == "string" and Enum.KeyCode[prefs.toggleKey] then
	toggleKey = Enum.KeyCode[prefs.toggleKey]
end
local keyCaptureActive = false
local keybindButton = nil

local function isUnitNumber(value)
	return type(value) == "number" and value == value and value >= 0 and value <= 1
end
if type(prefs.chroma) == "table"
	and isUnitNumber(prefs.chroma.r)
	and isUnitNumber(prefs.chroma.g)
	and isUnitNumber(prefs.chroma.b) then
	BG.BackgroundColor = Color3.new(prefs.chroma.r, prefs.chroma.g, prefs.chroma.b)
end

local function savePrefs()
	writeJson(CONFIG.PrefsFile, prefs)
end

-- Backend contract (swap this table for your server calls, same signatures):
--   register(name, key)     -> true | false, errorMessage
--   authenticate(name, key) -> true, displayName | false, errorMessage
-- The local version is a demo: anything stored or checked on the client can be bypassed,
-- so a real key system has to verify on the server.
local Backend = {}

function Backend.register(name, key)
	if type(name) ~= "string" or type(key) ~= "string" then
		return false, "Name and key must be text"
	end
	name = trim(name)
	key = trim(key)
	if name == "" or key == "" then return false, "Name and key are required" end
	if #name < CONFIG.MinNameLength or #name > CONFIG.MaxNameLength or not name:match("^[%w_%-]+$") then
		return false, "Invalid name format"
	end
	if #key < CONFIG.MinKeyLength or key:find("%s") then return false, "Invalid key format" end
	local id = name:lower()
	if accounts[id] then
		return false, "Name already taken"
	end
	accounts[id] = {
		name = name,
		key = key,
		userId = LocalPlayer and LocalPlayer.UserId or 0,
		created = os.time(),
	}
	writeJson(CONFIG.StoreFile, accounts)
	return true
end

function Backend.authenticate(name, key)
	if type(name) ~= "string" or type(key) ~= "string" then
		return false, "Name and key must be text"
	end
	name = trim(name)
	local acc = accounts[name:lower()]
	if type(acc) ~= "table" or type(acc.key) ~= "string" or acc.key ~= key or type(acc.name) ~= "string" then
		return false, "Invalid name or key"
	end
	if CONFIG.BindToRobloxAccount and LocalPlayer and acc.userId ~= LocalPlayer.UserId then
		return false, "This key belongs to another Roblox account"
	end
	return true, acc.name
end

-- ---------------------------------------------------------------------------
-- ScreenGui
-- ---------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "RoyaltyGlassUI"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true -- keeps GetMouseLocation() aligned with AbsolutePosition
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function()
	gui.Parent = (gethui and gethui()) or game:GetService("CoreGui")
end)
if not gui.Parent then
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local connections = {}
local destroyed = false

local blur
if USE_SCREEN_BLUR then
	blur = Instance.new("BlurEffect")
	blur.Name = "GlassUIBlur"
	blur.Size = 0
	blur.Parent = Lighting
	tween(blur, TweenInfo.new(0.4), { Size = 14 })
end

local function destroy()
	if destroyed then return end
	destroyed = true
	transitionToken += 1
	loadingToken += 1
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	local tweenSnapshot = {}
	for _, running in pairs(activeTweens) do
		for _, item in ipairs(running) do tweenSnapshot[#tweenSnapshot + 1] = item end
	end
	for _, item in ipairs(tweenSnapshot) do pcall(function() item.tween:Cancel() end) end
	table.clear(activeTweens)
	if blur then blur:Destroy() end
	if gui.Parent then gui:Destroy() end
	genv.GlassUI_Destroy = nil
	genv.GlassUI = nil
	genv.GlassUI_PrefillAccess = nil
end
genv.GlassUI_Destroy = destroy

-- ---------------------------------------------------------------------------
-- Notifications (bottom-right pop-ups): ERROR, OK, INFO, DANGER
-- ---------------------------------------------------------------------------
local TOAST = {
	INFO = { color = Color3.fromRGB(96, 165, 250), bg = Color3.fromRGB(14, 18, 28), seconds = 4 },
	OK = { color = Color3.fromRGB(74, 222, 128), bg = Color3.fromRGB(12, 26, 18), seconds = 3.5 },
	ERROR = { color = Color3.fromRGB(251, 146, 60), bg = Color3.fromRGB(30, 18, 10), seconds = 5 },
	DANGER = { color = Color3.fromRGB(239, 68, 68), bg = Color3.fromRGB(40, 10, 12), seconds = 6 },
}
local MAX_TOASTS = 4

local toastHolder = Instance.new("Frame")
toastHolder.Name = "Toasts"
toastHolder.AnchorPoint = Vector2.new(1, 1)
toastHolder.Position = UDim2.new(1, -20, 1, -20)
toastHolder.Size = UDim2.fromOffset(300, 0)
toastHolder.AutomaticSize = Enum.AutomaticSize.Y
toastHolder.BackgroundTransparency = 1
toastHolder.ZIndex = 50
toastHolder.Parent = gui
do
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.VerticalAlignment = Enum.VerticalAlignment.Bottom
	list.Padding = UDim.new(0, 8)
	list.Parent = toastHolder
end

local toastCounter = 0
local activeToasts = {}

local function notify(kind, text, seconds)
	if destroyed then return nil end
	kind = string.upper(tostring(kind))
	local style = TOAST[kind]
	if not style then
		kind = "INFO"
		style = TOAST.INFO
	end
	seconds = tonumber(seconds) or style.seconds
	seconds = math.clamp(seconds, 0.1, 60)
	toastCounter += 1

	while #activeToasts >= MAX_TOASTS do
		local oldest = table.remove(activeToasts, 1)
		oldest.dismiss(true)
	end

	local slot = Instance.new("Frame")
	slot.LayoutOrder = toastCounter
	slot.Size = UDim2.new(1, 0, 0, 0)
	slot.AutomaticSize = Enum.AutomaticSize.Y
	slot.BackgroundTransparency = 1
	slot.ZIndex = 50
	slot.Parent = toastHolder

	-- CanvasGroup: fades as one piece and clips the accent bar to the rounded corners
	local toast = Instance.new("CanvasGroup")
	toast.Size = UDim2.new(1, 0, 0, 0)
	toast.AutomaticSize = Enum.AutomaticSize.Y
	toast.Position = UDim2.fromOffset(40, 0)
	toast.BackgroundColor3 = style.bg
	toast.BackgroundTransparency = 0.12
	toast.BorderSizePixel = 0
	toast.GroupTransparency = 1
	toast.ZIndex = 50
	toast.Parent = slot
	corner(toast, 12)

	local accent = Instance.new("Frame")
	accent.Size = UDim2.new(0, 4, 1, 0)
	accent.BackgroundColor3 = style.color
	accent.BorderSizePixel = 0
	accent.ZIndex = 51
	accent.Parent = toast

	local content = Instance.new("Frame")
	content.Position = UDim2.fromOffset(4, 0)
	content.Size = UDim2.new(1, -4, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	content.ZIndex = 51
	content.Parent = toast
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 10)
	pad.PaddingBottom = UDim.new(0, 13)
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = content
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 2)
	layout.Parent = content

	local title = Instance.new("TextLabel")
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 12
	title.TextColor3 = style.color
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = kind
	title.ZIndex = 52
	title.Parent = content

	local msg = Instance.new("TextLabel")
	msg.LayoutOrder = 2
	msg.Size = UDim2.new(1, 0, 0, 0)
	msg.AutomaticSize = Enum.AutomaticSize.Y
	msg.BackgroundTransparency = 1
	msg.Font = Enum.Font.Gotham
	msg.TextSize = 13
	msg.TextColor3 = WHITE
	msg.TextWrapped = true
	msg.TextXAlignment = Enum.TextXAlignment.Left
	msg.TextYAlignment = Enum.TextYAlignment.Top
	msg.Text = tostring(text)
	msg.ZIndex = 52
	msg.Parent = content

	-- time-left bar
	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 0, 1, 0)
	bar.Size = UDim2.new(1, 0, 0, 2)
	bar.BackgroundColor3 = style.color
	bar.BackgroundTransparency = 0.35
	bar.BorderSizePixel = 0
	bar.ZIndex = 53
	bar.Parent = toast

	local entry = {}
	local dismissed = false
	function entry.dismiss(instant)
		if dismissed then return end
		dismissed = true
		local idx = table.find(activeToasts, entry)
		if idx then table.remove(activeToasts, idx) end
		if instant or destroyed or not slot.Parent then
			if slot.Parent then slot:Destroy() end
			return
		end
		local t = tween(toast, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			GroupTransparency = 1,
			Position = UDim2.fromOffset(40, 0),
		})
		t.Completed:Connect(function()
			slot:Destroy()
		end)
	end
	table.insert(activeToasts, entry)

	local click = Instance.new("TextButton")
	click.Size = UDim2.fromScale(1, 1)
	click.BackgroundTransparency = 1
	click.Text = ""
	click.ZIndex = 54
	click.Parent = toast
	click.MouseButton1Click:Connect(function() entry.dismiss(false) end)

	tween(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		GroupTransparency = 0,
		Position = UDim2.fromOffset(0, 0),
	})
	tween(bar, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 2) })
	task.delay(seconds, function() entry.dismiss(false) end)
	return entry
end

genv.GlassUI = { Notify = notify, Destroy = destroy, Backend = Backend }

-- ---------------------------------------------------------------------------
-- Panel: shadow + chroma/glass body + edge highlight + mouse specular.
-- CanvasGroup is needed because UICorner alone does not clip child layers to rounded corners.
-- ---------------------------------------------------------------------------
local root = Instance.new("Frame")
root.Name = "Root"
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.fromScale(0.5, 0.5)
root.Size = UDim2.fromOffset(PANEL_W, HEIGHTS.access)
root.BackgroundTransparency = 1
root.ZIndex = 1
root.Parent = gui

local panelScale = Instance.new("UIScale")
panelScale.Scale = 0.96
panelScale.Parent = root
local panelOpen = true

local function makeShadow(extra, offsetY, transparency, radius)
	local s = Instance.new("Frame")
	s.AnchorPoint = Vector2.new(0.5, 0.5)
	s.Position = UDim2.new(0.5, 0, 0.5, offsetY)
	s.Size = UDim2.new(1, extra, 1, extra)
	s.BackgroundColor3 = BLACK
	s.BackgroundTransparency = transparency
	s.BorderSizePixel = 0
	s.ZIndex = 1
	s.Parent = root
	corner(s, radius)
end
makeShadow(28, 10, 0.94, 34)
makeShadow(10, 6, 0.86, 26)

-- CanvasGroup clips every child layer (chroma, frost, glow and page content) to the rounded shell.
local panel = Instance.new("CanvasGroup")
panel.Name = "Panel"
panel.Size = UDim2.fromScale(1, 1)
panel.BackgroundColor3 = WHITE
panel.BackgroundTransparency = CHROMA_IN_PANEL and 1 or 0.75 -- 0.75 = rgba(255,255,255,0.25), the plain frosted fill
panel.GroupTransparency = 1
panel.BorderSizePixel = 0
panel.ZIndex = 2
panel.Parent = root
corner(panel, 20)

local function togglePanelVisibility()
	if panelOpen then
		panelOpen = false
		if blur then tween(blur, QUICK, { Size = 0 }) end
		local focused = UserInputService:GetFocusedTextBox()
		if focused then focused:ReleaseFocus() end
		tween(panel, QUICK, { GroupTransparency = 1 })
		tween(panelScale, QUICK, { Scale = 0.96 })
		task.delay(0.16, function()
			if not panelOpen then
				root.Visible = false
				toastHolder.Visible = false
			end
		end)
	else
		panelOpen = true
		root.Visible = true
		toastHolder.Visible = true
		if blur then tween(blur, QUICK, { Size = 14 }) end
		panelScale.Scale = 0.96
		tween(panel, QUICK, { GroupTransparency = 0 })
		tween(panelScale, QUICK, { Scale = 1 })
	end
end

if not CHROMA_IN_PANEL then
	local tint = Instance.new("UIGradient")
	tint.Color = ColorSequence.new(WHITE, Color3.fromRGB(215, 225, 255))
	tint.Rotation = 45
	tint.Parent = panel
end

-- inset 1px highlight: bright on the top-left, fading to the bottom-right
local edge = stroke(panel, 0, 1.5)
local edgeGradient = Instance.new("UIGradient")
edgeGradient.Rotation = 45
edgeGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.15),
	NumberSequenceKeypoint.new(0.45, 0.85),
	NumberSequenceKeypoint.new(1, 0.5),
})
edgeGradient.Parent = edge

-- ---------------------------------------------------------------------------
-- Chroma waves inside the panel: soft white ridges flowing over a base color. Each ridge is a white
-- core plus a warm and a cool band offset in Y (the chromatic shimmer). A ridge is made of vertical
-- columns, each one a soft vertical gradient band whose Y follows the wave function.
-- The field fills the existing panel. Wave columns use scale-based coordinates so the chroma
-- stretches with the same rounded glass surface when the authenticated view expands.
-- ---------------------------------------------------------------------------
local setChromaColor = function() end

if CHROMA_IN_PANEL then
	-- CanvasGroup clips its children to the rounded corners
	local canvas = Instance.new("CanvasGroup")
	canvas.Name = "ChromaFill"
	canvas.Size = UDim2.fromScale(1, 1)
	canvas.BackgroundTransparency = 1
	canvas.BorderSizePixel = 0
	canvas.ZIndex = 1
	canvas.Parent = panel
	corner(canvas, 20)

	local base = Instance.new("Frame")
	base.Name = "Base"
	base.Size = UDim2.fromScale(1, 1)
	base.BackgroundColor3 = WHITE -- the color comes from the gradient below
	base.BorderSizePixel = 0
	base.Parent = canvas
	local baseGradient = Instance.new("UIGradient")
	baseGradient.Rotation = 35
	baseGradient.Parent = base

	setChromaColor = function(color)
		BG.BackgroundColor = color
		baseGradient.Color = ColorSequence.new(color:Lerp(WHITE, 0.05), color:Lerp(BLACK, 0.35))
	end
	setChromaColor(BG.BackgroundColor)

	local field = Instance.new("Frame")
	field.Name = "Field"
	field.Position = UDim2.fromScale(0, 0)
	field.Size = UDim2.fromScale(1, 1)
	field.BackgroundTransparency = 1
	field.Parent = canvas

	-- soft cos^2 falloff, peak in the middle, fully transparent at both ends
	local function bandSequence(peakAlpha)
		local points = {}
		local steps = 10
		for i = 0, steps do
			local u = i / steps
			local s = math.cos((u - 0.5) * math.pi) ^ 2
			points[#points + 1] = NumberSequenceKeypoint.new(u, 1 - peakAlpha * s * BG.Opacity)
		end
		return NumberSequence.new(points)
	end

	local RIDGES = {
		{ base = 0.62, amp = BG.Amplitude * 0.8, phase = 2.1, speedMul = 0.8, alpha = 0.6, countMul = 1.15 },
		{ base = 0.38, amp = BG.Amplitude, phase = 0, speedMul = 1, alpha = 1, countMul = 1 },
	}
	local LAYERS = {
		{ color = Color3.fromRGB(255, 120, 150), shift = -1, height = 0.50, peak = 0.28 }, -- warm fringe
		{ color = Color3.fromRGB(110, 190, 255), shift = 1, height = 0.50, peak = 0.28 }, -- cool fringe
		{ color = BG.WaveColor, shift = 0, height = 0.40, peak = 0.42 }, -- white core
	}

	-- Normalized columns keep the wave field aligned with the panel at either login or dashboard size.
	local cols = BG.Columns
	local grid = {}
	for r, ridge in ipairs(RIDGES) do
		grid[r] = {}
		for i = 1, cols do
			grid[r][i] = { x = (i - 0.5) / cols, bars = {} }
		end
		for l, layer in ipairs(LAYERS) do
			local seq = bandSequence(layer.peak * ridge.alpha)
			for i = 1, cols do
				local c = grid[r][i]
				local f = Instance.new("Frame")
				f.BackgroundColor3 = layer.color
				f.BorderSizePixel = 0
				f.ZIndex = (r - 1) * #LAYERS + l
				f.Position = UDim2.new((i - 1) / cols, 0, 0, 0)
				f.Size = UDim2.new(1 / cols, 1, layer.height, 0)
				local g = Instance.new("UIGradient")
				g.Rotation = 90
				g.Transparency = seq
				g.Parent = f
				f.Parent = field
				c.bars[l] = f
			end
		end
	end

	local TAU = math.pi * 2
	local function update(t)
		for r, ridge in ipairs(RIDGES) do
			for i = 1, cols do
				local c = grid[r][i]
				local x = c.x
				local warp = BG.Distortion * 0.06 * math.sin(TAU * 1.3 * x + t * 0.7 + ridge.phase * 2)
				local w = TAU * (BG.WaveCount * ridge.countMul * x + warp) + t * BG.Speed * ridge.speedMul + ridge.phase
				local y = ridge.base + ridge.amp * (math.sin(w) + 0.35 * math.sin(2 * w + t * 0.4))
				for l, layer in ipairs(LAYERS) do
					local yy = y + layer.shift * BG.ChromaShift * 0.12
					c.bars[l].Position = UDim2.new((i - 1) / cols, 0, yy - layer.height * 0.5, 0)
				end
			end
		end
	end

	local startClock = os.clock()
	local accum = 0
	local interval = 1 / BG.UpdateHz
	update(0)
	table.insert(connections, RunService.RenderStepped:Connect(function(dt)
		accum += dt
		if accum >= interval then
			accum = 0
			update(os.clock() - startClock)
		end
	end))

	-- light frost over the waves: brighter at the top, almost clear at the bottom (liquid-glass sheen)
	local frost = Instance.new("Frame")
	frost.Name = "Frost"
	frost.Size = UDim2.fromScale(1, 1)
	frost.BackgroundColor3 = WHITE
	frost.BackgroundTransparency = 0
	frost.BorderSizePixel = 0
	frost.ZIndex = 2
	frost.Parent = panel
	corner(frost, 20)
	local frostGradient = Instance.new("UIGradient")
	frostGradient.Rotation = 90
	frostGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, BG.FrostTop),
		NumberSequenceKeypoint.new(0.6, BG.FrostBottom),
		NumberSequenceKeypoint.new(1, BG.FrostBottom),
	})
	frostGradient.Parent = frost
end

-- specular glow that follows the mouse. CanvasGroup clips to the rounded corners.
local glowClip = Instance.new("CanvasGroup")
glowClip.Name = "GlowClip"
glowClip.Size = UDim2.fromScale(1, 1)
glowClip.BackgroundTransparency = 1
glowClip.BorderSizePixel = 0
glowClip.GroupTransparency = 1
glowClip.ZIndex = 3
glowClip.Parent = panel
corner(glowClip, 20)

local GLOW_SIZE = 280
local glow = Instance.new("Frame")
glow.Name = "Glow"
glow.AnchorPoint = Vector2.new(0.5, 0.5)
glow.Size = UDim2.fromOffset(GLOW_SIZE, GLOW_SIZE)
glow.BackgroundTransparency = 1
glow.Parent = glowClip

-- UIGradient has no radial mode, so the falloff is stacked concentric circles
local GLOW_LAYERS = 12
for i = 1, GLOW_LAYERS do
	local d = GLOW_SIZE * (1 - (i - 1) / GLOW_LAYERS)
	local c = Instance.new("Frame")
	c.AnchorPoint = Vector2.new(0.5, 0.5)
	c.Position = UDim2.fromScale(0.5, 0.5)
	c.Size = UDim2.fromOffset(d, d)
	c.BackgroundColor3 = WHITE
	c.BackgroundTransparency = 0.985
	c.BorderSizePixel = 0
	c.Parent = glow
	corner(c, d)
end

do
	local glowPos = Vector2.zero
	local wasInside = false
	table.insert(connections, RunService.RenderStepped:Connect(function(dt)
		local mouse = UserInputService:GetMouseLocation()
		local rel = mouse - panel.AbsolutePosition
		local size = panel.AbsoluteSize
		local inside = rel.X >= 0 and rel.Y >= 0 and rel.X <= size.X and rel.Y <= size.Y

		if inside ~= wasInside then
			wasInside = inside
			if inside then glowPos = rel end
			tween(glowClip, QUICK, { GroupTransparency = inside and 0 or 1 })
		end

		if inside then
			glowPos = glowPos:Lerp(rel, math.clamp(dt * 14, 0, 1))
			glow.Position = UDim2.fromOffset(glowPos.X, glowPos.Y)
		end
	end))
end

-- ---------------------------------------------------------------------------
-- Draggable panel: grab the top area (the pill is the visual cue)
-- ---------------------------------------------------------------------------
local offset = Vector2.zero -- panel offset from the screen center, in pixels

local function setOffset(v)
	local vp = gui.AbsoluteSize
	local sz = root.AbsoluteSize
	local maxX = math.max(0, (vp.X - sz.X) / 2)
	local maxY = math.max(0, (vp.Y - sz.Y) / 2)
	offset = Vector2.new(math.clamp(v.X, -maxX, maxX), math.clamp(v.Y, -maxY, maxY))
	cancelTweenConflicts(root, { Position = true })
	root.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
end

do
	local dragRegion = Instance.new("Frame")
	dragRegion.Name = "DragRegion"
	dragRegion.Size = UDim2.new(1, 0, 0, 72)
	dragRegion.BackgroundTransparency = 1
	dragRegion.Active = true
	dragRegion.ZIndex = 9
	dragRegion.Parent = panel

	local pill = Instance.new("Frame")
	pill.Name = "DragPill"
	pill.AnchorPoint = Vector2.new(0.5, 0)
	pill.Position = UDim2.new(0.5, 0, 0, 9)
	pill.Size = UDim2.fromOffset(40, 4)
	pill.BackgroundColor3 = WHITE
	pill.BackgroundTransparency = 0.6
	pill.BorderSizePixel = 0
	pill.ZIndex = 9
	pill.Parent = panel
	corner(pill, 2)

	local dragging, hovering = false, false
	local dragStart, startOffset = Vector3.zero, Vector2.zero

	local function refresh()
		local transparency, width = 0.6, 40
		if dragging then
			transparency, width = 0.15, 56
		elseif hovering then
			transparency, width = 0.35, 52
		end
		tween(pill, QUICK, { BackgroundTransparency = transparency, Size = UDim2.fromOffset(width, 4) })
		tween(edge, QUICK, { Thickness = dragging and 2.4 or 1.5 })
	end

	dragRegion.MouseEnter:Connect(function() hovering = true refresh() end)
	dragRegion.MouseLeave:Connect(function() hovering = false refresh() end)
	dragRegion.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			dragStart = input.Position
			startOffset = offset
			refresh()
		end
	end)
	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			setOffset(startOffset + Vector2.new(delta.X, delta.Y))
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			refresh()
		end
	end))
end

-- ---------------------------------------------------------------------------
-- Close button: copy of the Uiverse "Add New" button (circle + plus), in black. It is drawn with
-- frames, so it does not depend on any font glyph. Hover rotates it 90deg and fills the circle,
-- pressing switches the colors instantly (duration 0 in the original).
-- ---------------------------------------------------------------------------
do
	local C_BASE = Color3.fromRGB(10, 10, 12) -- stroke (orange-400 in the original)
	local C_HOVER_FILL = Color3.fromRGB(36, 36, 42) -- hover fill (orange-800)
	local C_ACTIVE_STROKE = Color3.fromRGB(120, 120, 130) -- pressed stroke (orange-200)
	local C_ACTIVE_FILL = Color3.fromRGB(64, 64, 72) -- pressed fill (orange-600)
	local EASE = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out) -- approximates CSS "ease"

	local size = CLOSE_SIZE
	local unit = size / 24 -- the SVG viewBox is 24x24
	local thick = math.max(1, 1.5 * unit) -- stroke-width 1.5
	local baseRot = CLOSE_ICON_AS_X and 45 or 0

	local hit = Instance.new("TextButton")
	hit.Name = "Close"
	hit.AnchorPoint = Vector2.new(1, 0)
	hit.Position = UDim2.new(1, -10, 0, 10)
	hit.Size = UDim2.fromOffset(size, size)
	hit.BackgroundTransparency = 1
	hit.AutoButtonColor = false
	hit.Text = ""
	hit.ZIndex = 10
	hit.Parent = panel

	-- the hit area stays still, only this inner frame rotates
	local icon = Instance.new("Frame")
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromScale(1, 1)
	icon.BackgroundTransparency = 1
	icon.Rotation = baseRot
	icon.ZIndex = 10
	icon.Parent = hit

	-- circle: r=10 in the viewBox. UIStroke draws outside the frame, the SVG stroke is centered on the path.
	local diameter = 20 * unit - thick
	local circle = Instance.new("Frame")
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromOffset(diameter, diameter)
	circle.BackgroundColor3 = C_HOVER_FILL
	circle.BackgroundTransparency = 1 -- fill-none
	circle.BorderSizePixel = 0
	circle.ZIndex = 10
	circle.Parent = icon
	local circleCorner = Instance.new("UICorner")
	circleCorner.CornerRadius = UDim.new(0.5, 0)
	circleCorner.Parent = circle
	local circleStroke = Instance.new("UIStroke")
	circleStroke.Color = C_BASE
	circleStroke.Thickness = thick
	circleStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	circleStroke.Parent = circle

	-- plus: M8 12H16 and M12 16V8, each 8 units long
	local function bar(w, h)
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Size = UDim2.fromOffset(w, h)
		f.BackgroundColor3 = C_BASE
		f.BorderSizePixel = 0
		f.ZIndex = 11
		f.Parent = icon
		return f
	end
	local barH = bar(8 * unit, thick)
	local barV = bar(thick, 8 * unit)

	local hovered, pressed = false, false
	local colorTweens = {}
	local rotTween

	local function setColors(strokeColor, fillColor, fillTransparency, instant)
		for _, t in ipairs(colorTweens) do t:Cancel() end
		table.clear(colorTweens)
		local targets = {
			{ circleStroke, { Color = strokeColor } },
			{ circle, { BackgroundColor3 = fillColor, BackgroundTransparency = fillTransparency } },
			{ barH, { BackgroundColor3 = strokeColor } },
			{ barV, { BackgroundColor3 = strokeColor } },
		}
		for _, entry in ipairs(targets) do
			if instant then
				for prop, value in pairs(entry[2]) do
					entry[1][prop] = value
				end
			else
				table.insert(colorTweens, tween(entry[1], EASE, entry[2]))
			end
		end
	end

	local function setRotation()
		if rotTween then rotTween:Cancel() end
		rotTween = tween(icon, EASE, { Rotation = baseRot + (hovered and 90 or 0) })
	end

	local function settle()
		if hovered then
			setColors(C_BASE, C_HOVER_FILL, 0, false) -- group-hover fill
		else
			setColors(C_BASE, C_HOVER_FILL, 1, false) -- fill-none
		end
	end

	hit.MouseEnter:Connect(function()
		hovered = true
		setRotation()
		if not pressed then settle() end
	end)
	hit.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		setRotation()
		settle()
	end)
	hit.MouseButton1Down:Connect(function()
		pressed = true
		setColors(C_ACTIVE_STROKE, C_ACTIVE_FILL, 0, true) -- group-active, duration-0
	end)
	hit.MouseButton1Up:Connect(function()
		pressed = false
		settle()
	end)
	hit.MouseButton1Click:Connect(destroy)
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------
local busyButtons = {}

local function makeText(parent, text, size, y, transparency)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromOffset(30, y)
	l.Size = UDim2.new(1, -60, 0, size + 8)
	l.Font = Enum.Font.Gotham
	l.TextSize = size
	l.TextColor3 = WHITE
	l.TextTransparency = transparency or 0
	l.Text = text
	l.ZIndex = 5
	l.Parent = parent
	return l
end

local function addTitle(parent, text, leftInset)
	leftInset = leftInset or 30
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromOffset(leftInset, 28)
	t.Size = UDim2.new(1, -(leftInset + 30), 0, 36)
	t.Font = Enum.Font.GothamBold
	t.TextSize = 28
	t.TextColor3 = WHITE
	t.Text = text
	t.ZIndex = 5
	t.Parent = parent
end

local function makeMessage(parent, y)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Position = UDim2.fromOffset(30, y)
	l.Size = UDim2.new(1, -60, 0, 18)
	l.Font = Enum.Font.Gotham
	l.TextSize = 13
	l.TextColor3 = ERROR_COLOR
	l.Text = ""
	l.ZIndex = 5
	l.Parent = parent
	return function(text, color)
		l.Text = text or ""
		if color then l.TextColor3 = color end
	end
end

-- Key masking: Roblox TextBox has no password mode. The real characters are kept in a table and
-- the box only shows bullets (unless "visible"). Prefix/suffix diffing and caret position handle
-- insertions, replacements and deletions in the middle of a key as well as edits at the end.
local BULLET_CP = 0x2022
local function attachMask(box)
	local chars = {}
	local busy = false
	local visible = false
	local bullet = utf8.char(BULLET_CP)

	local function splitCodepoints(value)
		local result = {}
		for _, cp in utf8.codes(value) do
			result[#result + 1] = utf8.char(cp)
		end
		return result
	end

	local function isBulletString(tokens)
		for _, token in ipairs(tokens) do
			if token ~= bullet then return false end
		end
		return true
	end

	box:GetPropertyChangedSignal("Text"):Connect(function()
		if busy then return end
		local tokens = splitCodepoints(box.Text)
		if visible then
			chars = tokens
			return
		end

		local oldLength, newLength = #chars, #tokens
		if newLength < oldLength and isBulletString(tokens) then
			-- Use the caret/selection to remove from the actual key, including edits in the middle.
			local cursor, selection = box.CursorPosition, box.SelectionStart
			local removeStart
			if selection >= 1 and selection ~= cursor then
				removeStart = math.min(selection, cursor)
			elseif cursor >= 1 then
				removeStart = cursor <= newLength and cursor or cursor - 1
			else
				removeStart = newLength + 1
			end
			removeStart = math.clamp(removeStart, 1, oldLength)
			local removeCount = oldLength - newLength
			local nextChars = {}
			for index = 1, oldLength do
				if index < removeStart or index >= removeStart + removeCount then
					nextChars[#nextChars + 1] = chars[index]
				end
			end
			chars = nextChars
		else
			-- Match the unchanged masked prefix/suffix and treat the middle as inserted/replaced text.
			local prefix = 0
			while prefix < oldLength and prefix < newLength and tokens[prefix + 1] == bullet do
				prefix += 1
			end
			local suffix = 0
			while suffix < oldLength - prefix and suffix < newLength - prefix
				and tokens[newLength - suffix] == bullet do
				suffix += 1
			end
			local nextChars = {}
			for index = 1, prefix do nextChars[#nextChars + 1] = chars[index] end
			for index = prefix + 1, newLength - suffix do nextChars[#nextChars + 1] = tokens[index] end
			for index = oldLength - suffix + 1, oldLength do nextChars[#nextChars + 1] = chars[index] end
			chars = nextChars
		end

		local cursor = box.CursorPosition
		busy = true
		box.Text = string.rep(bullet, #chars)
		if cursor >= 1 then box.CursorPosition = math.clamp(cursor, 1, #chars + 1) end
		busy = false
	end)

	local api = {}
	function api.get()
		return table.concat(chars)
	end
	function api.reset()
		chars = {}
		box.Text = ""
	end
	function api.set(text)
		chars = splitCodepoints(tostring(text or ""))
		busy = true
		box.Text = visible and table.concat(chars) or string.rep(bullet, #chars)
		busy = false
	end
	function api.setVisible(flag)
		visible = flag
		busy = true
		box.Text = flag and table.concat(chars) or string.rep("•", #chars)
		busy = false
	end
	return api
end

-- Input area: black glass (still see-through, so the chroma shows faintly behind it).
-- opts.masked: key masking. opts.reveal: adds a Show/Hide toggle (needs masked).
local function makeInput(parent, icon, placeholder, y, opts)
	opts = opts or {}
	local holder = Instance.new("Frame")
	holder.Position = UDim2.fromOffset(30, y)
	holder.Size = UDim2.new(1, -60, 0, 44)
	holder.BackgroundColor3 = BLACK
	holder.BackgroundTransparency = 0.72
	holder.BorderSizePixel = 0
	holder.ZIndex = 5
	holder.Parent = parent
	corner(holder, 10)
	local st = stroke(holder, 0.6, 1, BLACK)

	local ic = Instance.new("TextLabel")
	ic.BackgroundTransparency = 1
	ic.Position = UDim2.fromOffset(14, 0)
	ic.Size = UDim2.fromOffset(24, 44)
	ic.Font = Enum.Font.Gotham
	ic.TextSize = 16
	ic.TextColor3 = WHITE
	ic.TextTransparency = 0.2
	ic.Text = icon or ""
	ic.Visible = ic.Text ~= ""
	ic.ZIndex = 6
	ic.Parent = holder

	local rightPad = opts.rightPad or ((opts.masked and opts.reveal) and 62 or 12)
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	local textInset = (icon and icon ~= "") and 46 or 14
	box.Position = UDim2.fromOffset(textInset, 0)
	box.Size = UDim2.new(1, -(textInset + rightPad), 1, 0)
	box.Font = Enum.Font.Gotham
	box.TextSize = 16
	box.TextColor3 = WHITE
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Color3.fromRGB(170, 170, 182)
	box.Text = ""
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ZIndex = 6
	box.Parent = holder

	local mask
	if opts.masked then
		mask = attachMask(box)
		if opts.reveal then
			local reveal = Instance.new("TextButton")
			reveal.AnchorPoint = Vector2.new(1, 0.5)
			reveal.Position = UDim2.new(1, -8, 0.5, 0)
			reveal.Size = UDim2.fromOffset(50, 28)
			reveal.BackgroundTransparency = 1
			reveal.AutoButtonColor = false
			reveal.Font = Enum.Font.GothamBold
			reveal.TextSize = 11
			reveal.TextColor3 = WHITE
			reveal.TextTransparency = 0.35
			reveal.Text = "Show"
			reveal.ZIndex = 7
			reveal.Parent = holder
			local shown = false
			reveal.MouseEnter:Connect(function() tween(reveal, QUICK, { TextTransparency = 0 }) end)
			reveal.MouseLeave:Connect(function() tween(reveal, QUICK, { TextTransparency = 0.35 }) end)
			reveal.MouseButton1Click:Connect(function()
				shown = not shown
				mask.setVisible(shown)
				reveal.Text = shown and "Hide" or "Show"
			end)
		end
	end

	local focused, errored = false, false
	local function refresh()
		local sc, stt, bg = BLACK, 0.6, 0.72
		if errored then
			sc, stt, bg = ERROR_COLOR, 0.2, 0.68
		elseif focused then
			sc, stt, bg = BLACK, 0.2, 0.6
		end
		tween(st, QUICK, { Color = sc, Transparency = stt })
		tween(holder, QUICK, { BackgroundTransparency = bg })
	end
	box.Focused:Connect(function() focused = true refresh() end)
	box.FocusLost:Connect(function() focused = false refresh() end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if errored then
			errored = false
			refresh()
		end
	end)

	local api = { box = box, holder = holder }
	function api.get()
		return trim(mask and mask.get() or box.Text)
	end
	function api.reset()
		if mask then mask.reset() else box.Text = "" end
	end
	function api.set(text)
		if mask then mask.set(text) else box.Text = text end
	end
	function api.setVisible(flag)
		if mask then mask.setVisible(flag) end
	end
	function api.setError(flag)
		errored = flag
		refresh()
	end
	return api
end

-- optional x / width (pixels) let two buttons share a row
local function makeButton(parent, text, y, x, width)
	local btn = Instance.new("TextButton")
	btn.Position = UDim2.fromOffset(x or 30, y)
	btn.Size = width and UDim2.fromOffset(width, 44) or UDim2.new(1, -60, 0, 44)
	btn.AutoButtonColor = false
	btn.BackgroundColor3 = WHITE
	btn.BackgroundTransparency = 0.8
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 16
	btn.TextColor3 = WHITE
	btn.Text = text
	btn.ZIndex = 5
	btn.Parent = parent
	corner(btn, 10)
	local st = stroke(btn, 0.7, 1)

	local function look(bg, stt)
		if busyButtons[btn] then return end
		tween(btn, QUICK, { BackgroundTransparency = bg })
		tween(st, QUICK, { Transparency = stt })
	end
	btn.MouseEnter:Connect(function() look(0.7, 0.55) end)
	btn.MouseLeave:Connect(function() look(0.8, 0.7) end)
	btn.MouseButton1Down:Connect(function() look(0.6, 0.45) end)
	btn.MouseButton1Up:Connect(function() look(0.7, 0.55) end)
	return btn
end

local function flashSuccess(btn, original, onDone)
	if busyButtons[btn] then return end
	busyButtons[btn] = true
	btn.Text = "Success!"
	tween(btn, QUICK, { BackgroundColor3 = OK_COLOR, BackgroundTransparency = 0.6 })
	task.delay(2, function()
		if destroyed or not btn.Parent then return end
		btn.Text = original
		tween(btn, QUICK, { BackgroundColor3 = WHITE, BackgroundTransparency = 0.8 })
		busyButtons[btn] = nil
		if onDone then onDone() end
	end)
end

local function makeSwitchLink(parent, y, text)
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundTransparency = 1
	b.Position = UDim2.fromOffset(30, y)
	b.Size = UDim2.new(1, -60, 0, 20)
	b.Font = Enum.Font.Gotham
	b.TextSize = 14
	b.TextColor3 = WHITE
	b.TextTransparency = 0.2
	b.RichText = true
	b.Text = text
	b.ZIndex = 5
	b.Parent = parent
	return b
end

-- ---------------------------------------------------------------------------
-- Screens (CanvasGroup so the whole page can fade with GroupTransparency)
-- ---------------------------------------------------------------------------
local screens = {}
local current = nil
local lastMain = "access" -- the page the Settings "Back" button returns to
local switching = false
local pendingScreen = nil
local authenticated = false
local showMemberTab = nil
local settingsButton = nil

local function createScreen(name, height, width)
	local group = Instance.new("CanvasGroup")
	group.Name = name
	group.Size = UDim2.fromScale(1, 1)
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.Visible = false
	group.GroupTransparency = 1
	group.ZIndex = 5
	group.Parent = panel
	screens[name] = { group = group, height = height, width = width or PANEL_W }
	return group
end

local function showScreen(name)
	local to = screens[name]
	if destroyed or not to then return false end
	if switching then
		pendingScreen = name
		return false
	end
	if current == name then return false end
	switching = true
	transitionToken += 1
	local thisTransition = transitionToken

	local from = current and screens[current]
	if name ~= "settings" then lastMain = name end

	local function enterTarget()
		if destroyed or thisTransition ~= transitionToken then return end
		if from then from.group.Visible = false end
		tween(root, FAST, { Size = UDim2.fromOffset(to.width or PANEL_W, to.height) })
		to.group.Position = UDim2.fromOffset(20, 0)
		to.group.GroupTransparency = 1
		to.group.Visible = true
		task.delay(0.05, function()
			if destroyed or thisTransition ~= transitionToken then return end
			tween(to.group, FAST, { GroupTransparency = 0, Position = UDim2.fromOffset(0, 0) })
		end)
		current = name
		task.delay(FAST.Time * 2 + 0.05, function()
			if destroyed or thisTransition ~= transitionToken then return end
			-- Clamp the dragged window after the resize animation has settled.
			setOffset(offset)
			switching = false
			local queued = pendingScreen
			pendingScreen = nil
			if queued and queued ~= current then task.defer(showScreen, queued) end
		end)
	end

	if from then
		tween(from.group, FAST, { GroupTransparency = 1, Position = UDim2.fromOffset(-20, 0) })
		task.delay(FAST.Time, enterTarget)
	else
		enterTarget()
	end
	return true
end

local shakeToken = 0
local function shake()
	shakeToken += 1
	local thisShake = shakeToken
	local ox, oy = offset.X, offset.Y
	local offsets = { 10, -10, 6, -6, 0 }
	local function step(index)
		if destroyed or thisShake ~= shakeToken then return end
		local dx = offsets[index]
		if dx == nil then return end
		tween(root, TweenInfo.new(0.05), { Position = UDim2.new(0.5, ox + dx, 0.5, oy) })
		task.delay(0.05, function() step(index + 1) end)
	end
	step(1)
end

local enterMemberArea

-- Settings button: Roblox approximation of the supplied Uiverse CSS button.
if CHROMA_IN_PANEL then
	local C_GEAR = WHITE
	local EASE = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	local hit = Instance.new("TextButton")
	settingsButton = hit
	hit.Name = "SettingsButton"
	hit.Position = UDim2.fromOffset(10, 10)
	hit.Size = UDim2.fromOffset(CLOSE_SIZE, CLOSE_SIZE)
	hit.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	hit.BackgroundTransparency = 0
	hit.BorderSizePixel = 0
	hit.AutoButtonColor = false
	hit.Text = ""
	hit.ZIndex = 10
	hit.Parent = panel
	corner(hit, 10)
	local hitStroke = stroke(hit, 0.48, 1, WHITE)

	local tooltip = Instance.new("TextLabel")
	tooltip.Name = "Tooltip"
	tooltip.AnchorPoint = Vector2.new(0.5, 1)
	tooltip.Position = UDim2.new(0.5, 0, 0, -7)
	tooltip.Size = UDim2.fromOffset(86, 24)
	tooltip.BackgroundColor3 = Color3.fromRGB(8, 8, 10)
	tooltip.BackgroundTransparency = 1
	tooltip.BorderSizePixel = 0
	tooltip.Font = Enum.Font.GothamMedium
	tooltip.Text = "Settings"
	tooltip.TextColor3 = WHITE
	tooltip.TextTransparency = 1
	tooltip.TextSize = 11
	tooltip.Visible = false
	tooltip.ZIndex = 12
	tooltip.Parent = hit
	corner(tooltip, 5)

	local icon = Instance.new("Frame")
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.Position = UDim2.fromScale(0.5, 0.5)
	icon.Size = UDim2.fromOffset(CLOSE_SIZE * 0.68, CLOSE_SIZE * 0.68)
	icon.BackgroundTransparency = 1
	icon.ZIndex = 10
	icon.Parent = hit

	local iconSize = CLOSE_SIZE * 0.68
	for k = 0, 7 do
		local spoke = Instance.new("Frame")
		spoke.AnchorPoint = Vector2.new(0.5, 0.5)
		spoke.Position = UDim2.fromScale(0.5, 0.5)
		spoke.Size = UDim2.fromScale(1, 1)
		spoke.BackgroundTransparency = 1
		spoke.Rotation = k * 45
		spoke.ZIndex = 10
		spoke.Parent = icon
		local tooth = Instance.new("Frame")
		tooth.AnchorPoint = Vector2.new(0.5, 0)
		tooth.Position = UDim2.fromScale(0.5, 0)
		tooth.Size = UDim2.fromOffset(iconSize * 0.2, iconSize * 0.24)
		tooth.BackgroundColor3 = C_GEAR
		tooth.BorderSizePixel = 0
		tooth.ZIndex = 10
		tooth.Parent = spoke
	end
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(iconSize * 0.52, iconSize * 0.52)
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.ZIndex = 10
	ring.Parent = icon
	local ringCorner = Instance.new("UICorner")
	ringCorner.CornerRadius = UDim.new(0.5, 0)
	ringCorner.Parent = ring
	stroke(ring, 0, math.max(2, iconSize * 0.13), C_GEAR)

	local rotTween
	local spinConnection
	local hovering = false
	local pressed = false
	local function rotateTo(angle)
		if rotTween then rotTween:Cancel() end
		rotTween = tween(icon, EASE, { Rotation = angle })
	end
	local function stopSpin()
		pressed = false
		if spinConnection then
			spinConnection:Disconnect()
			spinConnection = nil
		end
		rotateTo(hovering and 60 or 0)
	end
	hit.MouseEnter:Connect(function()
		hovering = true
		tween(hit, QUICK, { BackgroundColor3 = Color3.fromRGB(53, 53, 53) })
		tween(hitStroke, QUICK, { Transparency = 0.25 })
		tooltip.Visible = true
		tween(tooltip, QUICK, { BackgroundTransparency = 0.08, TextTransparency = 0 })
		if not pressed then rotateTo(60) end
	end)
	hit.MouseLeave:Connect(function()
		hovering = false
		tween(hit, QUICK, { BackgroundColor3 = Color3.fromRGB(30, 30, 30) })
		tween(hitStroke, QUICK, { Transparency = 0.48 })
		tween(tooltip, QUICK, { BackgroundTransparency = 1, TextTransparency = 1 })
		task.delay(0.16, function() if tooltip.Parent and not hovering then tooltip.Visible = false end end)
		if not pressed then rotateTo(0) end
	end)
	hit.MouseButton1Down:Connect(function()
		pressed = true
		if rotTween then rotTween:Cancel() end
		icon.Rotation = -100
		if spinConnection then spinConnection:Disconnect() end
		spinConnection = RunService.RenderStepped:Connect(function(deltaTime)
			if pressed and icon.Parent then
				icon.Rotation = (icon.Rotation + 280 * deltaTime) % 360
			end
		end)
		table.insert(connections, spinConnection)
	end)
	hit.MouseButton1Up:Connect(stopSpin)
	local releaseConnection = UserInputService.InputEnded:Connect(function(input)
		if pressed and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			stopSpin()
		end
	end)
	table.insert(connections, releaseConnection)
	hit.MouseButton1Click:Connect(function()
		if authenticated then
			if showMemberTab then showMemberTab("Settings") end
			return
		end
		task.spawn(showScreen, current == "settings" and lastMain or "settings")
	end)
end

-- ---- Access Key page: name + key ----
do
	local g = createScreen("access", HEIGHTS.access)
	addTitle(g, "Access Key", 58)
	makeText(g, "Enter your name and key", 14, 67, 0.25)
	local nameInput = makeInput(g, "", "Name", 99, {})
	local keyInput = makeInput(g, "", "Key", 150, { masked = true, reveal = true })
	local setMsg = makeMessage(g, 198)
	local btn = makeButton(g, "Enter", 218)
	local link = makeSwitchLink(g, 268, "No key yet? <b>Register</b>")

	if prefs.lastName then nameInput.set(prefs.lastName) end

	local attempts, lockedUntil = 0, 0
	local function remaining()
		return math.max(0, math.ceil(lockedUntil - os.clock()))
	end

	local function runLockout()
		busyButtons[btn] = true
		task.spawn(function()
			while not destroyed and remaining() > 0 do
				btn.Text = string.format("Locked (%ds)", remaining())
				task.wait(0.25)
			end
			if destroyed then return end
			busyButtons[btn] = nil
			btn.Text = "Enter"
			setMsg("", nil)
		end)
	end

	local function submit()
		if remaining() > 0 then
			notify("DANGER", string.format("Locked. Try again in %ds.", remaining()))
			return
		end
		if busyButtons[btn] then return end
		setMsg("", nil)

		local nm, key = nameInput.get(), keyInput.get()
		local ok = true
		if nm == "" then nameInput.setError(true) ok = false end
		if key == "" then keyInput.setError(true) ok = false end
		if not ok then
			setMsg("Enter your name and key", ERROR_COLOR)
			return
		end

		local success, result = Backend.authenticate(nm, key)
		if success then
			attempts = 0
			authenticated = true
			if settingsButton then settingsButton.Visible = false end
			prefs.lastName = result
			savePrefs()
			genv.GlassUI_User = result
			notify("OK", "Welcome, " .. result)
			flashSuccess(btn, "Enter", nil)
			task.spawn(enterMemberArea, result)
		else
			attempts += 1
			nameInput.setError(true)
			keyInput.setError(true)
			setMsg(result, ERROR_COLOR)
			task.spawn(shake)
			notify("ERROR", string.format("%s (%d/%d)", result, attempts, CONFIG.MaxAttempts))
			if attempts >= CONFIG.MaxAttempts then
				attempts = 0
				lockedUntil = os.clock() + CONFIG.LockoutSeconds
				notify("DANGER", string.format("Too many attempts. Locked for %ds.", CONFIG.LockoutSeconds))
				runLockout()
			end
		end
	end

	btn.MouseButton1Click:Connect(submit)
	nameInput.box.FocusLost:Connect(function(enter)
		if enter then keyInput.box:CaptureFocus() end
	end)
	keyInput.box.FocusLost:Connect(function(enter)
		if enter then submit() end
	end)
	link.MouseButton1Click:Connect(function() task.spawn(showScreen, "register") end)

	-- used by the Register page after a successful registration
	genv.GlassUI_PrefillAccess = function(name)
		nameInput.set(name)
		keyInput.reset()
		keyInput.setVisible(false)
	end
end

-- ---- Register page: name + key supplied by the owner ----
do
	local g = createScreen("register", HEIGHTS.register)
	addTitle(g, "Register", 58)
	makeText(g, "Create your account with the key you received", 14, 70, 0.25)
	local nameInput = makeInput(g, "", "Name", 108, {})
	local keyInput = makeInput(g, "", "Access key", 164, { masked = true, reveal = true })
	makeText(g, "Use the access key supplied by the owner.", 11, 214, 0.35)

	local setMsg = makeMessage(g, 238)
	local btn = makeButton(g, "Create account", 262)
	local link = makeSwitchLink(g, 318, "Already registered? <b>Enter</b>")

	local function submit()
		if busyButtons[btn] then return end
		setMsg("", nil)
		local nm, key = nameInput.get(), keyInput.get()

		if #nm < CONFIG.MinNameLength or #nm > CONFIG.MaxNameLength or not nm:match("^[%w_%-]+$") then
			nameInput.setError(true)
			setMsg(string.format("Name: %d-%d letters, numbers, _ or -", CONFIG.MinNameLength, CONFIG.MaxNameLength), ERROR_COLOR)
			return
		end
		if #key < CONFIG.MinKeyLength or key:find("%s") then
			keyInput.setError(true)
			setMsg(string.format("Key: at least %d characters, no spaces", CONFIG.MinKeyLength), ERROR_COLOR)
			return
		end

		local ok, err = Backend.register(nm, key)
		if not ok then
			nameInput.setError(true)
			setMsg(err, ERROR_COLOR)
			notify("ERROR", err)
			return
		end

		prefs.lastName = nm
		savePrefs()
		notify("OK", "Account created for " .. nm)
		notify("INFO", "Use the access key supplied by the owner to sign in.")
		flashSuccess(btn, "Create account", nil)
		task.delay(1.4, function()
			if destroyed then return end
			genv.GlassUI_PrefillAccess(nm)
			nameInput.reset()
			keyInput.reset()
			keyInput.setVisible(false)
			showScreen("access")
			notify("INFO", "Now enter with your name and key.")
		end)
	end
	btn.MouseButton1Click:Connect(submit)
	keyInput.box.FocusLost:Connect(function(enter) if enter then submit() end end)
	nameInput.box.FocusLost:Connect(function(enter)
		if enter then keyInput.box:CaptureFocus() end
	end)
	link.MouseButton1Click:Connect(function() task.spawn(showScreen, "access") end)
end

-- ---- Settings page: chroma color ----
if CHROMA_IN_PANEL then
	local g = createScreen("settings", HEIGHTS.settings)
	addTitle(g, "Settings", 58)
	makeText(g, "Chroma color", 14, 70, 0.25)

	local PICK_W = PANEL_W - 60
	local h, s, v = BG.BackgroundColor:ToHSV()

	-- saturation / value map
	local svMap = Instance.new("TextButton")
	svMap.Position = UDim2.fromOffset(30, 100)
	svMap.Size = UDim2.fromOffset(PICK_W, 110)
	svMap.AutoButtonColor = false
	svMap.Text = ""
	svMap.BorderSizePixel = 0
	svMap.ZIndex = 5
	svMap.Parent = g
	corner(svMap, 8)

	local satOverlay = Instance.new("Frame")
	satOverlay.Size = UDim2.fromScale(1, 1)
	satOverlay.BackgroundColor3 = WHITE
	satOverlay.BorderSizePixel = 0
	satOverlay.Active = false
	satOverlay.ZIndex = 6
	satOverlay.Parent = svMap
	corner(satOverlay, 8)
	local satGradient = Instance.new("UIGradient")
	satGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	satGradient.Parent = satOverlay

	local valOverlay = Instance.new("Frame")
	valOverlay.Size = UDim2.fromScale(1, 1)
	valOverlay.BackgroundColor3 = BLACK
	valOverlay.BorderSizePixel = 0
	valOverlay.Active = false
	valOverlay.ZIndex = 7
	valOverlay.Parent = svMap
	corner(valOverlay, 8)
	local valGradient = Instance.new("UIGradient")
	valGradient.Rotation = 90
	valGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	valGradient.Parent = valOverlay

	local svCursor = Instance.new("Frame")
	svCursor.AnchorPoint = Vector2.new(0.5, 0.5)
	svCursor.Size = UDim2.fromOffset(12, 12)
	svCursor.BackgroundTransparency = 1
	svCursor.BorderSizePixel = 0
	svCursor.ZIndex = 8
	svCursor.Parent = svMap
	local cursorCorner = Instance.new("UICorner")
	cursorCorner.CornerRadius = UDim.new(0.5, 0)
	cursorCorner.Parent = svCursor
	stroke(svCursor, 0, 2, WHITE)

	-- hue bar
	local hueBar = Instance.new("TextButton")
	hueBar.Position = UDim2.fromOffset(30, 222)
	hueBar.Size = UDim2.fromOffset(PICK_W, 14)
	hueBar.AutoButtonColor = false
	hueBar.Text = ""
	hueBar.BackgroundColor3 = WHITE
	hueBar.BorderSizePixel = 0
	hueBar.ZIndex = 5
	hueBar.Parent = g
	corner(hueBar, 7)
	local hueGradient = Instance.new("UIGradient")
	hueGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
		ColorSequenceKeypoint.new(0.167, Color3.fromRGB(255, 255, 0)),
		ColorSequenceKeypoint.new(0.333, Color3.fromRGB(0, 255, 0)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
		ColorSequenceKeypoint.new(0.667, Color3.fromRGB(0, 0, 255)),
		ColorSequenceKeypoint.new(0.833, Color3.fromRGB(255, 0, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
	})
	hueGradient.Parent = hueBar
	local hueCursor = Instance.new("Frame")
	hueCursor.AnchorPoint = Vector2.new(0.5, 0.5)
	hueCursor.Size = UDim2.fromOffset(6, 20)
	hueCursor.BackgroundColor3 = WHITE
	hueCursor.BorderSizePixel = 0
	hueCursor.ZIndex = 6
	hueCursor.Parent = hueBar
	corner(hueCursor, 3)
	stroke(hueCursor, 0.3, 1, BLACK)

	-- hex input with a preview swatch
	local hexInput = makeInput(g, "#", "8B5CF6", 246, { rightPad = 48 })
	local swatch = Instance.new("Frame")
	swatch.AnchorPoint = Vector2.new(1, 0.5)
	swatch.Position = UDim2.new(1, -10, 0.5, 0)
	swatch.Size = UDim2.fromOffset(24, 24)
	swatch.BorderSizePixel = 0
	swatch.ZIndex = 7
	swatch.Parent = hexInput.holder
	corner(swatch, 6)
	stroke(swatch, 0.5, 1, WHITE)

	local function toHex(c)
		return string.format("%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
	end

	local saveToken = 0
	local function scheduleSave(color)
		saveToken += 1
		local token = saveToken
		task.delay(0.6, function()
			if destroyed or token ~= saveToken then return end
			prefs.chroma = { r = color.R, g = color.G, b = color.B }
			savePrefs()
		end)
	end

	local function applyColor()
		local c = Color3.fromHSV(h, s, v)
		svMap.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svCursor.Position = UDim2.fromScale(s, 1 - v)
		hueCursor.Position = UDim2.fromScale(h, 0.5)
		swatch.BackgroundColor3 = c
		hexInput.box.Text = toHex(c)
		setChromaColor(c)
		scheduleSave(c)
	end

	local function setFromColor(c)
		h, s, v = c:ToHSV()
		applyColor()
	end

	local draggingSV, draggingHue = false, false
	local function updateSV(pointer)
		pointer = pointer or UserInputService:GetMouseLocation()
		local size = svMap.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return end
		local rel = pointer - svMap.AbsolutePosition
		s = math.clamp(rel.X / size.X, 0, 1)
		v = 1 - math.clamp(rel.Y / size.Y, 0, 1)
		applyColor()
	end
	local function updateHue(pointer)
		pointer = pointer or UserInputService:GetMouseLocation()
		local width = hueBar.AbsoluteSize.X
		if width <= 0 then return end
		local rel = pointer - hueBar.AbsolutePosition
		h = math.clamp(rel.X / width, 0, 0.999)
		applyColor()
	end

	local function isPress(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end
	svMap.InputBegan:Connect(function(input)
		if isPress(input) then
			draggingSV = true
			updateSV(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	hueBar.InputBegan:Connect(function(input)
		if isPress(input) then
			draggingHue = true
			updateHue(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local pointer = input.UserInputType == Enum.UserInputType.Touch
				and Vector2.new(input.Position.X, input.Position.Y) or UserInputService:GetMouseLocation()
			if draggingSV then
				updateSV(pointer)
			elseif draggingHue then
				updateHue(pointer)
			end
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			draggingSV, draggingHue = false, false
		end
	end))

	hexInput.box.FocusLost:Connect(function()
		local hex = hexInput.box.Text:match("^#?(%x%x%x%x%x%x)$")
		if hex then
			setFromColor(Color3.fromRGB(
				tonumber(hex:sub(1, 2), 16),
				tonumber(hex:sub(3, 4), 16),
				tonumber(hex:sub(5, 6), 16)
			))
		else
			hexInput.setError(true)
			notify("ERROR", "Invalid hex color. Use 6 digits, like 8B5CF6.")
		end
	end)

	-- presets
	local PRESETS = { "#8B5CF6", "#3B82F6", "#06B6D4", "#10B981", "#EC4899", "#F97316", "#EF4444" }
	local SWATCH, GAP = 26, 10
	local startX = (PANEL_W - (#PRESETS * SWATCH + (#PRESETS - 1) * GAP)) / 2
	for i, hex in ipairs(PRESETS) do
		local b = Instance.new("TextButton")
		b.Position = UDim2.fromOffset(startX + (i - 1) * (SWATCH + GAP), 302)
		b.Size = UDim2.fromOffset(SWATCH, SWATCH)
		b.AutoButtonColor = false
		b.Text = ""
		b.BackgroundColor3 = Color3.fromHex(hex)
		b.BorderSizePixel = 0
		b.ZIndex = 5
		b.Parent = g
		corner(b, 8)
		local st = stroke(b, 0.55, 1, WHITE)
		b.MouseEnter:Connect(function() tween(st, QUICK, { Transparency = 0 }) end)
		b.MouseLeave:Connect(function() tween(st, QUICK, { Transparency = 0.55 }) end)
		b.MouseButton1Click:Connect(function()
			setFromColor(Color3.fromHex(hex))
		end)
	end

	local halfW = (PANEL_W - 60 - 10) / 2
	local resetBtn = makeButton(g, "Reset", 346, 30, halfW)
	local backBtn = makeButton(g, "Back", 346, 30 + halfW + 10, halfW)
	resetBtn.MouseButton1Click:Connect(function()
		setFromColor(DEFAULT_CHROMA)
		notify("INFO", "Chroma color reset.")
	end)
	backBtn.MouseButton1Click:Connect(function()
		task.spawn(showScreen, lastMain)
	end)

	applyColor()
end

-- ---------------------------------------------------------------------------
-- Expanded member pages: same Panel, ChromaFill, frost, rim and glass language.
-- This is an in-panel page set, not a second ScreenGui or a second visual shell.
-- ---------------------------------------------------------------------------
local loadingPage = createScreen("loading", MAIN_H, MAIN_W)
local loadingCard = Instance.new("CanvasGroup")
loadingCard.AnchorPoint = Vector2.new(0.5, 0.5)
loadingCard.Position = UDim2.fromScale(0.5, 0.5)
loadingCard.Size = UDim2.fromOffset(280, 118)
loadingCard.BackgroundColor3 = BLACK
loadingCard.BackgroundTransparency = 0.56
loadingCard.BorderSizePixel = 0
loadingCard.ZIndex = 6
loadingCard.Parent = loadingPage
corner(loadingCard, 12)
stroke(loadingCard, 0.48, 1, WHITE)

local loadingTitle = Instance.new("TextLabel")
loadingTitle.Position = UDim2.fromOffset(0, 20)
loadingTitle.Size = UDim2.new(1, 0, 0, 26)
loadingTitle.BackgroundTransparency = 1
loadingTitle.Font = Enum.Font.GothamBold
loadingTitle.Text = "Loading..."
loadingTitle.TextColor3 = WHITE
loadingTitle.TextSize = 18
loadingTitle.TextXAlignment = Enum.TextXAlignment.Center
loadingTitle.ZIndex = 7
loadingTitle.Parent = loadingCard

local loadingDots = {}
for index = 1, 7 do
	local dot = Instance.new("Frame")
	dot.Name = "LoadingDot" .. index
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromOffset(140, 76)
	dot.Size = UDim2.fromOffset(index == 1 and 12 or 10, index == 1 and 12 or 10)
	dot.BackgroundColor3 = WHITE
	dot.BackgroundTransparency = (index - 1) * 0.055
	dot.BorderSizePixel = 0
	dot.ZIndex = 8
	dot.Parent = loadingCard
	corner(dot, 6)
	loadingDots[index] = dot
end

local memberPage = createScreen("member", MAIN_H, MAIN_W)
local memberTint = Instance.new("Frame")
memberTint.Name = "ReadableGlassTint"
memberTint.Size = UDim2.fromScale(1, 1)
memberTint.BackgroundColor3 = BLACK
memberTint.BackgroundTransparency = 0.72
memberTint.BorderSizePixel = 0
memberTint.ZIndex = 6
memberTint.Parent = memberPage
local memberSidebar = Instance.new("CanvasGroup")
memberSidebar.Position = UDim2.fromOffset(18, 18)
memberSidebar.Size = UDim2.new(0, 178, 1, -36)
memberSidebar.BackgroundColor3 = BLACK
memberSidebar.BackgroundTransparency = 0.48
memberSidebar.BorderSizePixel = 0
memberSidebar.ZIndex = 6
memberSidebar.Parent = memberPage
corner(memberSidebar, 12)
stroke(memberSidebar, 0.58, 1, WHITE)

local memberContent = Instance.new("Frame")
memberContent.Position = UDim2.fromOffset(214, 18)
memberContent.Size = UDim2.new(1, -232, 1, -36)
memberContent.BackgroundTransparency = 1
memberContent.ZIndex = 6
memberContent.Parent = memberPage

local memberHeading = Instance.new("TextLabel")
memberHeading.Position = UDim2.fromOffset(0, 3)
memberHeading.Size = UDim2.new(1, -48, 0, 31)
memberHeading.BackgroundTransparency = 1
memberHeading.Font = Enum.Font.GothamBold
memberHeading.Text = "Home"
memberHeading.TextTruncate = Enum.TextTruncate.AtEnd
memberHeading.TextWrapped = false
memberHeading.TextColor3 = WHITE
memberHeading.TextSize = 23
memberHeading.TextXAlignment = Enum.TextXAlignment.Left
memberHeading.ZIndex = 7
memberHeading.Parent = memberContent

local memberSubheading = Instance.new("TextLabel")
memberSubheading.Position = UDim2.fromOffset(1, 35)
memberSubheading.Size = UDim2.new(1, -48, 0, 20)
memberSubheading.BackgroundTransparency = 1
memberSubheading.Font = Enum.Font.Gotham
memberSubheading.Text = "Your account is ready."
memberSubheading.TextColor3 = WHITE
memberSubheading.TextTransparency = 0.08
memberSubheading.TextSize = 12
memberSubheading.TextXAlignment = Enum.TextXAlignment.Left
memberSubheading.ZIndex = 7
memberSubheading.Parent = memberContent

local memberView = Instance.new("Frame")
memberView.Position = UDim2.fromOffset(0, 70)
memberView.Size = UDim2.new(1, 0, 1, -70)
memberView.BackgroundTransparency = 1
memberView.ZIndex = 7
memberView.Parent = memberContent

local memberPages = {}
local memberNavButtons = {}
local memberNavStrokes = {}
local activeMemberTab = nil
local memberTabOrder = {}
local memberTabSubtitles = {
	Home = "Your account is ready.",
	Scripts = "Organize and launch your scripts.",
	Tools = "Quick actions and utilities.",
	Settings = "Tune the panel to your preference.",
}

local function glassCard(parent, name, position, size)
	local card = Instance.new("CanvasGroup")
	card.Name = name
	card.Position = position
	card.Size = size
	card.BackgroundColor3 = BLACK
	card.BackgroundTransparency = 0.46
	card.BorderSizePixel = 0
	card.ZIndex = 7
	card.Parent = parent
	corner(card, 11)
	stroke(card, 0.56, 1, WHITE)
	return card
end

local function memberLabel(parent, text, size, position, color, transparency, bold)
	local label = Instance.new("TextLabel")
	label.Position = position
	label.Size = size
	label.BackgroundTransparency = 1
	label.Font = bold and Enum.Font.GothamSemibold or Enum.Font.Gotham
	label.Text = text
	label.TextColor3 = color or WHITE
	label.TextTransparency = transparency or 0
	label.TextSize = size.Y.Offset <= 20 and 11 or 15
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextWrapped = true
	label.ZIndex = 8
	label.Parent = parent
	return label
end

local function createMemberPage(name)
	local page = Instance.new("CanvasGroup")
	page.Name = name .. "Page"
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.GroupTransparency = 1
	page.Visible = false
	page.ZIndex = 7
	page.Parent = memberView
	memberPages[name] = page
	return page
end

local homePage = createMemberPage("Home")
local hero = glassCard(homePage, "WelcomeCard", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 154))
local memberWelcome = memberLabel(hero, "Welcome back", UDim2.new(1, -40, 0, 34), UDim2.fromOffset(20, 20), WHITE, 0, true)
memberWelcome.TextSize = 22
memberLabel(hero, "Your sign-in is complete. Choose a page from the sidebar to continue.", UDim2.new(1, -40, 0, 38), UDim2.fromOffset(20, 62), WHITE, 0.04, false)
memberLabel(hero, "ACCESS CONFIRMED", UDim2.new(1, -40, 0, 18), UDim2.fromOffset(20, 119), WHITE, 0, true)

local infoCard = glassCard(homePage, "InfoCard", UDim2.fromOffset(0, 170), UDim2.new(1, 0, 0, 96))
memberLabel(infoCard, "Your workspace", UDim2.new(1, -36, 0, 20), UDim2.fromOffset(18, 14), WHITE, 0, true)
memberLabel(infoCard, "Script pages will use this same glass panel, colors, borders and transitions.", UDim2.new(1, -36, 0, 42), UDim2.fromOffset(18, 41), WHITE, 0.04, false)

local scriptsPage = createMemberPage("Scripts")
local scriptsCard = glassCard(scriptsPage, "ScriptsCard", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 120))
memberLabel(scriptsCard, "Scripts", UDim2.new(1, -36, 0, 22), UDim2.fromOffset(18, 15), WHITE, 0, true)
memberLabel(scriptsCard, "No script options are connected yet. This is the page area where they will appear.", UDim2.new(1, -36, 0, 50), UDim2.fromOffset(18, 44), WHITE, 0.04, false)

local toolsPage = createMemberPage("Tools")
local toolsCard = glassCard(toolsPage, "ToolsCard", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 120))
memberLabel(toolsCard, "Tools", UDim2.new(1, -36, 0, 22), UDim2.fromOffset(18, 15), WHITE, 0, true)
memberLabel(toolsCard, "Utilities and tools can be added here without changing the panel shell.", UDim2.new(1, -36, 0, 50), UDim2.fromOffset(18, 44), WHITE, 0.04, false)

-- Full HSV color picker: saturation/value map, hue bar, hex input, presets and reset.
-- Meant for a 628px wide glass card. refresh() re-reads BG.BackgroundColor, so the picker follows
-- changes made elsewhere (for example the pre-login Settings page). The color is saved to prefs.chroma.
local function buildColorPicker(parent)
	local PICK_W, SV_H = 250, 128
	local h, s, v = BG.BackgroundColor:ToHSV()

	-- saturation / value map
	local svMap = Instance.new("TextButton")
	svMap.Name = "SaturationValueMap"
	svMap.Position = UDim2.fromOffset(18, 46)
	svMap.Size = UDim2.fromOffset(PICK_W, SV_H)
	svMap.AutoButtonColor = false
	svMap.Text = ""
	svMap.BorderSizePixel = 0
	svMap.ZIndex = 9
	svMap.Parent = parent
	corner(svMap, 8)

	local satOverlay = Instance.new("Frame")
	satOverlay.Size = UDim2.fromScale(1, 1)
	satOverlay.BackgroundColor3 = WHITE
	satOverlay.BorderSizePixel = 0
	satOverlay.Active = false
	satOverlay.ZIndex = 10
	satOverlay.Parent = svMap
	corner(satOverlay, 8)
	local satGradient = Instance.new("UIGradient")
	satGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	satGradient.Parent = satOverlay

	local valOverlay = Instance.new("Frame")
	valOverlay.Size = UDim2.fromScale(1, 1)
	valOverlay.BackgroundColor3 = BLACK
	valOverlay.BorderSizePixel = 0
	valOverlay.Active = false
	valOverlay.ZIndex = 11
	valOverlay.Parent = svMap
	corner(valOverlay, 8)
	local valGradient = Instance.new("UIGradient")
	valGradient.Rotation = 90
	valGradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	valGradient.Parent = valOverlay

	local svCursor = Instance.new("Frame")
	svCursor.AnchorPoint = Vector2.new(0.5, 0.5)
	svCursor.Size = UDim2.fromOffset(12, 12)
	svCursor.BackgroundTransparency = 1
	svCursor.BorderSizePixel = 0
	svCursor.ZIndex = 12
	svCursor.Parent = svMap
	local cursorCorner = Instance.new("UICorner")
	cursorCorner.CornerRadius = UDim.new(0.5, 0)
	cursorCorner.Parent = svCursor
	stroke(svCursor, 0, 2, WHITE)

	-- hue bar
	local hueBar = Instance.new("TextButton")
	hueBar.Name = "HueBar"
	hueBar.Position = UDim2.fromOffset(18, 184)
	hueBar.Size = UDim2.fromOffset(PICK_W, 14)
	hueBar.AutoButtonColor = false
	hueBar.Text = ""
	hueBar.BackgroundColor3 = WHITE
	hueBar.BorderSizePixel = 0
	hueBar.ZIndex = 9
	hueBar.Parent = parent
	corner(hueBar, 7)
	local hueGradient = Instance.new("UIGradient")
	hueGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
		ColorSequenceKeypoint.new(0.167, Color3.fromRGB(255, 255, 0)),
		ColorSequenceKeypoint.new(0.333, Color3.fromRGB(0, 255, 0)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
		ColorSequenceKeypoint.new(0.667, Color3.fromRGB(0, 0, 255)),
		ColorSequenceKeypoint.new(0.833, Color3.fromRGB(255, 0, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0)),
	})
	hueGradient.Parent = hueBar
	local hueCursor = Instance.new("Frame")
	hueCursor.AnchorPoint = Vector2.new(0.5, 0.5)
	hueCursor.Size = UDim2.fromOffset(6, 20)
	hueCursor.BackgroundColor3 = WHITE
	hueCursor.BorderSizePixel = 0
	hueCursor.ZIndex = 10
	hueCursor.Parent = hueBar
	corner(hueCursor, 3)
	stroke(hueCursor, 0.3, 1, BLACK)

	-- right column: hex input with a preview swatch, presets, reset
	memberLabel(parent, "Hex color", UDim2.new(0, 200, 0, 18), UDim2.fromOffset(288, 46), WHITE, 0.08, false)
	local hexInput = makeInput(parent, "#", "8B5CF6", 66, { rightPad = 48 })
	hexInput.holder.Position = UDim2.fromOffset(288, 66)
	hexInput.holder.Size = UDim2.fromOffset(200, 44)
	local swatch = Instance.new("Frame")
	swatch.AnchorPoint = Vector2.new(1, 0.5)
	swatch.Position = UDim2.new(1, -10, 0.5, 0)
	swatch.Size = UDim2.fromOffset(24, 24)
	swatch.BorderSizePixel = 0
	swatch.ZIndex = 7
	swatch.Parent = hexInput.holder
	corner(swatch, 6)
	stroke(swatch, 0.5, 1, WHITE)

	local function toHex(c)
		return string.format("%02X%02X%02X", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
	end

	-- UI only
	local function paint()
		local c = Color3.fromHSV(h, s, v)
		svMap.BackgroundColor3 = Color3.fromHSV(h, 1, 1)
		svCursor.Position = UDim2.fromScale(s, 1 - v)
		hueCursor.Position = UDim2.fromScale(h, 0.5)
		swatch.BackgroundColor3 = c
		hexInput.box.Text = toHex(c)
	end

	local saveToken = 0
	local function scheduleSave(color)
		saveToken += 1
		local token = saveToken
		task.delay(0.6, function()
			if destroyed or token ~= saveToken then return end
			prefs.chroma = { r = color.R, g = color.G, b = color.B }
			savePrefs()
		end)
	end

	-- UI + panel color + debounced save
	local function applyColor()
		paint()
		local c = Color3.fromHSV(h, s, v)
		setChromaColor(c)
		scheduleSave(c)
	end

	local function setFromColor(c)
		h, s, v = c:ToHSV()
		applyColor()
	end

	local draggingSV, draggingHue = false, false
	local function updateSV(pointer)
		pointer = pointer or UserInputService:GetMouseLocation()
		local size = svMap.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 then return end
		local rel = pointer - svMap.AbsolutePosition
		s = math.clamp(rel.X / size.X, 0, 1)
		v = 1 - math.clamp(rel.Y / size.Y, 0, 1)
		applyColor()
	end
	local function updateHue(pointer)
		pointer = pointer or UserInputService:GetMouseLocation()
		local width = hueBar.AbsoluteSize.X
		if width <= 0 then return end
		local rel = pointer - hueBar.AbsolutePosition
		h = math.clamp(rel.X / width, 0, 0.999)
		applyColor()
	end

	local function isPress(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end
	svMap.InputBegan:Connect(function(input)
		if isPress(input) then
			draggingSV = true
			updateSV(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	hueBar.InputBegan:Connect(function(input)
		if isPress(input) then
			draggingHue = true
			updateHue(Vector2.new(input.Position.X, input.Position.Y))
		end
	end)
	table.insert(connections, UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			local pointer = input.UserInputType == Enum.UserInputType.Touch
				and Vector2.new(input.Position.X, input.Position.Y) or UserInputService:GetMouseLocation()
			if draggingSV then
				updateSV(pointer)
			elseif draggingHue then
				updateHue(pointer)
			end
		end
	end))
	table.insert(connections, UserInputService.InputEnded:Connect(function(input)
		if isPress(input) then
			draggingSV, draggingHue = false, false
		end
	end))

	hexInput.box.FocusLost:Connect(function()
		local hex = hexInput.box.Text:match("^#?(%x%x%x%x%x%x)$")
		if hex then
			setFromColor(Color3.fromRGB(
				tonumber(hex:sub(1, 2), 16),
				tonumber(hex:sub(3, 4), 16),
				tonumber(hex:sub(5, 6), 16)
			))
		else
			hexInput.setError(true)
			notify("ERROR", "Invalid hex color. Use 6 digits, like 8B5CF6.")
		end
	end)

	-- presets
	memberLabel(parent, "Presets", UDim2.new(0, 200, 0, 18), UDim2.fromOffset(288, 120), WHITE, 0.08, false)
	local PRESETS = { "#8B5CF6", "#3B82F6", "#06B6D4", "#10B981", "#EC4899", "#F97316", "#EF4444" }
	for i, hex in ipairs(PRESETS) do
		local b = Instance.new("TextButton")
		b.Position = UDim2.fromOffset(288 + (i - 1) * 36, 142)
		b.Size = UDim2.fromOffset(26, 26)
		b.AutoButtonColor = false
		b.Text = ""
		b.BackgroundColor3 = Color3.fromHex(hex)
		b.BorderSizePixel = 0
		b.ZIndex = 9
		b.Parent = parent
		corner(b, 8)
		local st = stroke(b, 0.55, 1, WHITE)
		b.MouseEnter:Connect(function() tween(st, QUICK, { Transparency = 0 }) end)
		b.MouseLeave:Connect(function() tween(st, QUICK, { Transparency = 0.55 }) end)
		b.MouseButton1Click:Connect(function()
			setFromColor(Color3.fromHex(hex))
		end)
	end

	local resetBtn = makeButton(parent, "Reset", 184, 288, 160)
	resetBtn.MouseButton1Click:Connect(function()
		setFromColor(DEFAULT_CHROMA)
		notify("INFO", "Chroma color reset.")
	end)

	paint()

	return {
		-- call when the tab opens: re-reads BG.BackgroundColor without touching the panel color
		refresh = function()
			h, s, v = BG.BackgroundColor:ToHSV()
			paint()
		end,
	}
end

local memberSettings = createMemberPage("Settings")
local appearanceCard = glassCard(memberSettings, "AppearanceCard", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 244))
memberLabel(appearanceCard, "Appearance", UDim2.new(1, -36, 0, 22), UDim2.fromOffset(18, 14), WHITE, 0, true)
local memberColorPicker = buildColorPicker(appearanceCard)

local interfaceCard = glassCard(memberSettings, "InterfaceCard", UDim2.fromOffset(0, 260), UDim2.new(1, 0, 0, 160))
memberLabel(interfaceCard, "Interface", UDim2.new(1, -36, 0, 22), UDim2.fromOffset(18, 13), WHITE, 0, true)
memberLabel(interfaceCard, "Panel size", UDim2.new(0, 130, 0, 18), UDim2.fromOffset(18, 48), WHITE, 0.08, false)
memberLabel(interfaceCard, "860 × 530", UDim2.new(0, 100, 0, 18), UDim2.new(1, -118, 0, 48), WHITE, 0.02, true).TextXAlignment = Enum.TextXAlignment.Right
memberLabel(interfaceCard, "Open / close key", UDim2.new(0, 170, 0, 20), UDim2.fromOffset(18, 88), WHITE, 0.02, true)
memberLabel(interfaceCard, "Click the key button, then press your preferred key.", UDim2.new(1, -190, 0, 34), UDim2.fromOffset(18, 112), WHITE, 0.10, false)

keybindButton = Instance.new("TextButton")
keybindButton.Name = "PanelToggleKey"
keybindButton.AnchorPoint = Vector2.new(1, 0)
keybindButton.Position = UDim2.new(1, -18, 0, 84)
keybindButton.Size = UDim2.fromOffset(142, 34)
keybindButton.BackgroundColor3 = BLACK
keybindButton.BackgroundTransparency = 0.45
keybindButton.BorderSizePixel = 0
keybindButton.AutoButtonColor = false
keybindButton.Font = Enum.Font.GothamSemibold
keybindButton.Text = toggleKey.Name
keybindButton.TextColor3 = WHITE
keybindButton.TextSize = 12
keybindButton.ZIndex = 9
keybindButton.Parent = interfaceCard
corner(keybindButton, 8)
stroke(keybindButton, 0.42, 1, WHITE)
keybindButton.Activated:Connect(function()
	keyCaptureActive = true
	keybindButton.Text = "Press a key..."
end)

local function addMemberNavigation(tabName)
	if memberNavButtons[tabName] then return memberNavButtons[tabName] end
	if #memberTabOrder >= 8 then return nil, "The sidebar supports up to 8 pages." end
	memberTabOrder[#memberTabOrder + 1] = tabName
	local index = #memberTabOrder
	local nav = Instance.new("TextButton")
	nav.Name = tabName .. "Tab"
	nav.Position = UDim2.fromOffset(10, 18 + (index - 1) * 54)
	nav.Size = UDim2.new(1, -20, 0, 44)
	nav.BackgroundColor3 = BLACK
	nav.BackgroundTransparency = 0.76
	nav.BorderSizePixel = 0
	nav.AutoButtonColor = false
	nav.Font = Enum.Font.GothamSemibold
	nav.Text = tabName
	nav.TextTruncate = Enum.TextTruncate.AtEnd
	nav.TextWrapped = false
	nav.TextColor3 = WHITE
	nav.TextTransparency = 0.08
	nav.TextSize = 14
	nav.TextXAlignment = Enum.TextXAlignment.Left
	nav.ZIndex = 8
	nav.Parent = memberSidebar
	corner(nav, 8)
	local navStroke = stroke(nav, 0.68, 1, WHITE)
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 13)
	padding.Parent = nav
	memberNavButtons[tabName] = nav
	memberNavStrokes[tabName] = navStroke
	nav.Activated:Connect(function()
		if showMemberTab then showMemberTab(tabName) end
	end)
	return nav
end

local defaultTabNames = { "Home", "Scripts", "Tools", "Settings" }
for _, tabName in ipairs(defaultTabNames) do
	addMemberNavigation(tabName)
end

showMemberTab = function(tabName)
	local page = memberPages[tabName]
	if not page or activeMemberTab == tabName then return end
	activeMemberTab = tabName
	if tabName == "Settings" and memberColorPicker then
		memberColorPicker.refresh()
	end
	memberHeading.Text = tabName
	memberSubheading.Text = memberTabSubtitles[tabName] or "A clear workspace with the same visual language."
	for name, frame in pairs(memberPages) do
		frame.Visible = name == tabName
		frame.GroupTransparency = name == tabName and 1 or 0
	end
	for name, nav in pairs(memberNavButtons) do
		local selected = name == tabName
		tween(nav, QUICK, {
			BackgroundTransparency = selected and 0.42 or 0.76,
			TextTransparency = selected and 0 or 0.08,
		})
		local line = memberNavStrokes[name]
		if line then tween(line, QUICK, { Transparency = selected and 0.34 or 0.68 }) end
	end
	tween(page, QUICK, { GroupTransparency = 0 })
end

-- Public extension API. All additions use the same glass tokens and remain children of this ScreenGui.
local function trackConnection(connection)
	connections[#connections + 1] = connection
	return connection
end

local function untrackConnection(connection)
	local index = table.find(connections, connection)
	if index then table.remove(connections, index) end
	pcall(function() connection:Disconnect() end)
end

local function createLibraryButton(parent, title, position, size, callback)
	local parentZ = parent:IsA("GuiObject") and parent.ZIndex or 7
	local button = Instance.new("TextButton")
	button.Name = "ActionButton"
	button.Position = position
	button.Size = size
	button.AutoButtonColor = false
	button.BackgroundColor3 = WHITE
	button.BackgroundTransparency = 0.80
	button.BorderSizePixel = 0
	button.Font = Enum.Font.GothamSemibold
	button.Text = tostring(title)
	button.TextColor3 = WHITE
	button.TextSize = 13
	button.ZIndex = parentZ + 2
	button.Parent = parent
	corner(button, 9)
	local outline = stroke(button, 0.68, 1, WHITE)
	button.MouseEnter:Connect(function()
		tween(button, QUICK, { BackgroundTransparency = 0.68 })
		tween(outline, QUICK, { Transparency = 0.42 })
	end)
	button.MouseLeave:Connect(function()
		tween(button, QUICK, { BackgroundTransparency = 0.80 })
		tween(outline, QUICK, { Transparency = 0.68 })
	end)
	button.Activated:Connect(function()
		if type(callback) == "function" then
			local ok, err = pcall(callback)
			if not ok then warn("[GlassUI] Button callback failed: " .. tostring(err)) end
		end
	end)
	return button
end

local function createLibraryToggle(parent, title, position, width, defaultValue, callback)
	local row = Instance.new("Frame")
	row.Name = "ToggleRow"
	row.Position = position
	row.Size = UDim2.fromOffset(width, 42)
	row.BackgroundColor3 = BLACK
	row.BackgroundTransparency = 0.62
	row.BorderSizePixel = 0
	row.ZIndex = (parent:IsA("GuiObject") and parent.ZIndex or 7) + 1
	row.Parent = parent
	corner(row, 9)
	stroke(row, 0.72, 1, WHITE)
	local label = memberLabel(row, tostring(title), UDim2.new(1, -72, 1, 0), UDim2.fromOffset(12, 0), WHITE, 0.02, false)
	label.ZIndex = row.ZIndex + 1
	label.TextSize = 12
	local hit = Instance.new("TextButton")
	hit.Name = "ToggleHitbox"
	hit.Size = UDim2.fromScale(1, 1)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.ZIndex = row.ZIndex + 3
	hit.Parent = row
	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(1, 0.5)
	track.Position = UDim2.new(1, -11, 0.5, 0)
	track.Size = UDim2.fromOffset(38, 20)
	track.BackgroundColor3 = WHITE
	track.BackgroundTransparency = 0.82
	track.BorderSizePixel = 0
	track.ZIndex = row.ZIndex + 1
	track.Parent = row
	corner(track, 10)
	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0, 0.5)
	knob.Position = UDim2.new(0, 3, 0.5, 0)
	knob.Size = UDim2.fromOffset(14, 14)
	knob.BackgroundColor3 = WHITE
	knob.BorderSizePixel = 0
	knob.ZIndex = track.ZIndex + 1
	knob.Parent = track
	corner(knob, 7)
	local state = defaultValue == true
	local api = { Instance = row }
	function api.SetValue(nextValue, fireCallback)
		state = nextValue == true
		tween(track, QUICK, { BackgroundTransparency = state and 0.18 or 0.82 })
		tween(knob, QUICK, { Position = state and UDim2.new(1, -17, 0.5, 0) or UDim2.new(0, 3, 0.5, 0) })
		if fireCallback ~= false and type(callback) == "function" then
			local ok, err = pcall(callback, state)
			if not ok then warn("[GlassUI] Toggle callback failed: " .. tostring(err)) end
		end
	end
	function api.GetValue() return state end
	hit.Activated:Connect(function() api.SetValue(not state, true) end)
	api.SetValue(state, false)
	return api
end

local function createLibraryDropdown(parent, title, position, width, options, defaultValue, callback)
	assert(type(options) == "table" and #options > 0, "Dropdown expects a non-empty options array")
	local row = Instance.new("Frame")
	row.Name = "Dropdown"
	row.Position = position
	row.Size = UDim2.fromOffset(width, 42 + math.min(#options, 5) * 30 + 8)
	row.BackgroundTransparency = 1
	row.ZIndex = (parent:IsA("GuiObject") and parent.ZIndex or 7) + 1
	row.Parent = parent
	local defaultIndex = table.find(options, defaultValue)
	local currentValue = options[1]
	if defaultIndex then currentValue = options[defaultIndex] end
	local selector = createLibraryButton(row, "", UDim2.fromOffset(0, 0), UDim2.new(1, 0, 0, 38), nil)
	selector.Text = tostring(title) .. "   ·   " .. tostring(currentValue) .. "   ▾"
	selector.TextXAlignment = Enum.TextXAlignment.Left
	local selectorPadding = Instance.new("UIPadding")
	selectorPadding.PaddingLeft = UDim.new(0, 12)
	selectorPadding.PaddingRight = UDim.new(0, 10)
	selectorPadding.Parent = selector
	local popup = Instance.new("CanvasGroup")
	popup.Name = "OptionsClip"
	popup.Position = UDim2.fromOffset(0, 42)
	popup.Size = UDim2.new(1, 0, 0, math.min(#options, 5) * 30 + 6)
	popup.BackgroundColor3 = Color3.fromRGB(18, 19, 24)
	popup.BackgroundTransparency = 0.04
	popup.BorderSizePixel = 0
	popup.GroupTransparency = 1
	popup.Visible = false
	popup.ZIndex = row.ZIndex + 8
	popup.Parent = row
	corner(popup, 9)
	stroke(popup, 0.55, 1, WHITE)
	local list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(3, 3)
	list.Size = UDim2.new(1, -6, 1, -6)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 3
	list.ScrollBarImageColor3 = WHITE
	list.CanvasSize = UDim2.fromOffset(0, #options * 30)
	list.ZIndex = popup.ZIndex + 1
	list.Parent = popup
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local opened = false
	local popupToken = 0
	local function setOpened(nextValue)
		opened = nextValue
		popupToken += 1
		local thisPopup = popupToken
		if opened then
			popup.Visible = true
			tween(popup, QUICK, { GroupTransparency = 0 })
		else
			tween(popup, QUICK, { GroupTransparency = 1 })
			task.delay(QUICK.Time, function()
				if not destroyed and popupToken == thisPopup and popup.Parent then popup.Visible = false end
			end)
		end
	end
	for index, option in ipairs(options) do
		local optionButton = Instance.new("TextButton")
		optionButton.LayoutOrder = index
		optionButton.Size = UDim2.new(1, 0, 0, 28)
		optionButton.BackgroundColor3 = WHITE
		optionButton.BackgroundTransparency = 1
		optionButton.BorderSizePixel = 0
		optionButton.AutoButtonColor = false
		optionButton.Font = Enum.Font.Gotham
		optionButton.Text = tostring(option)
		optionButton.TextColor3 = WHITE
		optionButton.TextSize = 12
		optionButton.TextXAlignment = Enum.TextXAlignment.Left
		optionButton.ZIndex = list.ZIndex + 1
		optionButton.Parent = list
		local padding = Instance.new("UIPadding")
		padding.PaddingLeft = UDim.new(0, 10)
		padding.Parent = optionButton
		optionButton.MouseEnter:Connect(function() tween(optionButton, QUICK, { BackgroundTransparency = 0.88 }) end)
		optionButton.MouseLeave:Connect(function() tween(optionButton, QUICK, { BackgroundTransparency = 1 }) end)
		optionButton.Activated:Connect(function()
			currentValue = option
			selector.Text = tostring(title) .. "   ·   " .. tostring(currentValue) .. "   ▾"
			setOpened(false)
			if type(callback) == "function" then
				local ok, err = pcall(callback, currentValue)
				if not ok then warn("[GlassUI] Dropdown callback failed: " .. tostring(err)) end
			end
		end)
	end
	selector.Activated:Connect(function()
		setOpened(not opened)
	end)
	local api = { Instance = row }
	function api.GetValue() return currentValue end
	function api.SetValue(value, fireCallback)
		if not table.find(options, value) then return false end
		currentValue = value
		selector.Text = tostring(title) .. "   ·   " .. tostring(currentValue) .. "   ▾"
		if fireCallback ~= false and type(callback) == "function" then
			local ok, err = pcall(callback, currentValue)
			if not ok then warn("[GlassUI] Dropdown callback failed: " .. tostring(err)) end
		end
		return true
	end
	return api
end

local function createLibrarySlider(parent, title, position, width, minValue, maxValue, defaultValue, step, callback)
	assert(type(minValue) == "number" and type(maxValue) == "number" and maxValue > minValue, "Slider requires max > min")
	step = type(step) == "number" and step > 0 and step or 1
	local row = Instance.new("Frame")
	row.Name = "Slider"
	row.Position = position
	row.Size = UDim2.fromOffset(width, 58)
	row.BackgroundTransparency = 1
	row.ZIndex = (parent:IsA("GuiObject") and parent.ZIndex or 7) + 1
	row.Parent = parent
	local label = memberLabel(row, tostring(title), UDim2.new(1, -70, 0, 18), UDim2.fromOffset(0, 0), WHITE, 0.02, false)
	label.ZIndex = row.ZIndex + 1
	label.TextSize = 12
	local valueLabel = memberLabel(row, "", UDim2.fromOffset(64, 18), UDim2.new(1, -64, 0, 0), WHITE, 0.02, true)
	valueLabel.ZIndex = row.ZIndex + 1
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	local track = Instance.new("Frame")
	track.Position = UDim2.fromOffset(0, 32)
	track.Size = UDim2.new(1, 0, 0, 5)
	track.BackgroundColor3 = WHITE
	track.BackgroundTransparency = 0.78
	track.BorderSizePixel = 0
	track.ZIndex = row.ZIndex + 1
	track.Parent = row
	corner(track, 4)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(0, 0, 1, 0)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.ZIndex = track.ZIndex + 1
	fill.Parent = track
	corner(fill, 4)
	local thumb = Instance.new("Frame")
	thumb.AnchorPoint = Vector2.new(0.5, 0.5)
	thumb.Position = UDim2.fromScale(0, 0.5)
	thumb.Size = UDim2.fromOffset(13, 13)
	thumb.BackgroundColor3 = WHITE
	thumb.BorderSizePixel = 0
	thumb.ZIndex = track.ZIndex + 2
	thumb.Parent = track
	corner(thumb, 7)
	local hit = Instance.new("TextButton")
	hit.Position = UDim2.new(0, -5, 0, -8)
	hit.Size = UDim2.new(1, 10, 0, 21)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.ZIndex = thumb.ZIndex + 1
	hit.Parent = track
	local value = minValue
	local dragging = false
	local function setValue(nextValue, fireCallback)
		nextValue = math.clamp(nextValue, minValue, maxValue)
		value = math.clamp(minValue + math.floor((nextValue - minValue) / step + 0.5) * step, minValue, maxValue)
		local alpha = (value - minValue) / (maxValue - minValue)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		thumb.Position = UDim2.new(alpha, 0, 0.5, 0)
		valueLabel.Text = tostring(value)
		if fireCallback ~= false and type(callback) == "function" then
			local ok, err = pcall(callback, value)
			if not ok then warn("[GlassUI] Slider callback failed: " .. tostring(err)) end
		end
	end
	local function updateFrom(input)
		local x = input.UserInputType == Enum.UserInputType.Touch and input.Position.X or UserInputService:GetMouseLocation().X
		local widthNow = track.AbsoluteSize.X
		if widthNow <= 0 then return end
		setValue(minValue + math.clamp((x - track.AbsolutePosition.X) / widthNow, 0, 1) * (maxValue - minValue), true)
	end
	hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			updateFrom(input)
		end
	end)
	local changedConnection = trackConnection(UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then updateFrom(input) end
	end))
	local endedConnection = trackConnection(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then dragging = false end
	end))
	setValue(defaultValue or minValue, false)
	local api = { Instance = row }
	function api.GetValue() return value end
	function api.SetValue(nextValue, fireCallback) setValue(nextValue, fireCallback); return value end
	local connectionsReleased = false
	local function releaseConnections()
		if connectionsReleased then return end
		connectionsReleased = true
		untrackConnection(changedConnection)
		untrackConnection(endedConnection)
	end
	function api.Destroy()
		releaseConnections()
		row:Destroy()
	end
	row.Destroying:Connect(releaseConnections)
	return api
end

local function createLibraryTextBox(parent, placeholder, position, size, callback)
	local input = makeInput(parent, "", tostring(placeholder), position.Y.Offset, {})
	input.holder.Position = position
	input.holder.Size = size
	local parentZ = parent:IsA("GuiObject") and parent.ZIndex or 7
	local zOffset = parentZ + 1 - input.holder.ZIndex
	for _, descendant in ipairs(input.holder:GetDescendants()) do
		if descendant:IsA("GuiObject") then descendant.ZIndex += zOffset end
	end
	input.holder.ZIndex += zOffset
	local focusConnection = trackConnection(input.box.FocusLost:Connect(function(enterPressed)
		if type(callback) == "function" then
			local ok, err = pcall(callback, input.box.Text, enterPressed)
			if not ok then warn("[GlassUI] TextBox callback failed: " .. tostring(err)) end
		end
	end))
	local connectionReleased = false
	local function releaseConnection()
		if connectionReleased then return end
		connectionReleased = true
		untrackConnection(focusConnection)
	end
	input.Destroy = function()
		releaseConnection()
		if input.holder.Parent then input.holder:Destroy() end
	end
	input.holder.Destroying:Connect(releaseConnection)
	input.GetValue = function() return input.box.Text end
	input.SetValue = function(value) input.set(tostring(value or "")) end
	input.Instance = input.holder
	return input
end

local GlassUIAPI = {
	Version = "1.0.0",
	CreateSection = function(parent, title, position, size)
		local section = glassCard(parent, tostring(title) .. "Section", position or UDim2.fromOffset(0, 0), size or UDim2.new(1, 0, 0, 120))
		section.ZIndex = (parent:IsA("GuiObject") and parent.ZIndex or 7) + 1
		local titleLabel = memberLabel(section, tostring(title), UDim2.new(1, -32, 0, 22), UDim2.fromOffset(16, 12), WHITE, 0.01, true)
		titleLabel.ZIndex = section.ZIndex + 1
		return section
	end,
	CreateLabel = function(parent, text, position, size, options)
		options = options or {}
		local label = memberLabel(parent, tostring(text), size or UDim2.new(1, -24, 0, 22), position or UDim2.fromOffset(12, 0), options.Color or WHITE, options.Transparency or 0, options.Bold == true)
		label.ZIndex = (parent:IsA("GuiObject") and parent.ZIndex or 7) + 1
		if options.TextSize then label.TextSize = options.TextSize end
		return label
	end,
	CreateButton = createLibraryButton,
	CreateToggle = createLibraryToggle,
	CreateDropdown = createLibraryDropdown,
	CreateSelect = createLibraryDropdown,
	CreateSelector = createLibraryDropdown,
	CreateSlider = createLibrarySlider,
	CreateTextBox = createLibraryTextBox,
	ShowPage = function(name)
		if destroyed or not memberPages[name] then return false end
		showMemberTab(name)
		return true
	end,
}

function GlassUIAPI.CreatePage(name, subtitle)
	if destroyed then return nil, "The UI has already been destroyed." end
	name = trim(name)
	if name == "" or #name > 24 or name:find("[%c]") then return nil, "Use a page name with 1-24 printable characters." end
	if memberPages[name] then return nil, "A page with that name already exists." end
	if #memberTabOrder >= 8 then return nil, "The sidebar supports up to 8 pages." end
	memberTabSubtitles[name] = trim(subtitle or "Custom page")
	local group = createMemberPage(name)
	local page = Instance.new("ScrollingFrame")
	page.Name = "Content"
	page.Size = UDim2.fromScale(1, 1)
	page.BackgroundTransparency = 1
	page.BorderSizePixel = 0
	page.CanvasSize = UDim2.new()
	page.AutomaticCanvasSize = Enum.AutomaticSize.Y
	page.ScrollingDirection = Enum.ScrollingDirection.Y
	page.ScrollBarThickness = 3
	page.ScrollBarImageColor3 = WHITE
	page.ZIndex = group.ZIndex + 1
	page.Parent = group
	addMemberNavigation(name)
	return page
end

function GlassUIAPI.RemovePage(name)
	if destroyed or table.find(defaultTabNames, name) or not memberPages[name] then return false end
	if activeMemberTab == name then showMemberTab("Home") end
	local group = memberPages[name]
	local nav = memberNavButtons[name]
	local outline = memberNavStrokes[name]
	memberPages[name] = nil
	memberNavButtons[name] = nil
	memberNavStrokes[name] = nil
	memberTabSubtitles[name] = nil
	local index = table.find(memberTabOrder, name)
	if index then table.remove(memberTabOrder, index) end
	if outline then outline:Destroy() end
	if nav then nav:Destroy() end
	if group then group:Destroy() end
	for row, tabName in ipairs(memberTabOrder) do
		local remainingNav = memberNavButtons[tabName]
		if remainingNav then remainingNav.Position = UDim2.fromOffset(10, 18 + (row - 1) * 54) end
	end
	return true
end

genv.GlassUI.UI = GlassUIAPI
genv.GlassUI.Version = GlassUIAPI.Version

local loadingAnimation = nil

table.insert(connections, UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if keyCaptureActive then
		if input.UserInputType ~= Enum.UserInputType.Keyboard or input.KeyCode == Enum.KeyCode.Unknown then return end
		keyCaptureActive = false
		if input.KeyCode == Enum.KeyCode.Escape then
			if keybindButton then keybindButton.Text = toggleKey.Name end
			return
		end
		toggleKey = input.KeyCode
		prefs.toggleKey = toggleKey.Name
		savePrefs()
		if keybindButton then keybindButton.Text = toggleKey.Name end
		notify("OK", "Panel shortcut set to " .. toggleKey.Name .. ".")
		return
	end
	if gameProcessed or UserInputService:GetFocusedTextBox() then return end
	if input.UserInputType == Enum.UserInputType.Keyboard and input.KeyCode == toggleKey then
		togglePanelVisibility()
	end
end))

enterMemberArea = function(name)
	if destroyed then return end
	loadingToken += 1
	local thisLoading = loadingToken
	memberWelcome.Text = "Welcome back, " .. name
	showScreen("loading") -- same existing panel animates from 400×300 to 860×530
	if loadingAnimation then loadingAnimation:Disconnect() end
	local started = os.clock()
	loadingAnimation = RunService.RenderStepped:Connect(function()
		local phase = (os.clock() - started) * 2.5
		for index, dot in ipairs(loadingDots) do
			local angle = phase - (index - 1) * 0.34
			dot.Position = UDim2.fromOffset(140 + math.cos(angle) * 55, 76 + math.sin(angle) * 17)
		end
	end)
	table.insert(connections, loadingAnimation)
	task.delay(1.30, function() -- decorative loading; keep the UI event thread non-blocking
		if destroyed or thisLoading ~= loadingToken then return end
		if loadingAnimation then loadingAnimation:Disconnect(); loadingAnimation = nil end
		showScreen("member")
		if showMemberTab then showMemberTab("Home") end
		local okCall, err = pcall(CONFIG.OnAuthenticated, name)
		if not okCall then warn("[GlassUI] OnAuthenticated error: " .. tostring(err)) end
		if CONFIG.CloseOnSuccess then task.delay(1.2, destroy) end
	end)
end

-- show the access page without a transition
do
	local first = screens.access
	first.group.Visible = true
	first.group.GroupTransparency = 0
	current = "access"
end

task.defer(function()
	if destroyed then return end
	tween(panel, FAST, { GroupTransparency = 0 })
	tween(panelScale, FAST, { Scale = 1 })
end)

notify("INFO", "Enter your name and key, or register.")
print("[GlassUI] loaded.")
