--[[
	LibreMusePro.lua — Roblox Studio plugin (PRO edition)
	Everything in LibreMuse, plus PRO-only tools:

	  • Prompt Library — built-in templates + your own saved prompts (persisted)
	  • Debug mode — select a script, paste the error, get the fixed script back
	  • Explain mode — plain-English explanation of any selected script
	  • Optimize mode — performance refactor (+ --!strict & types), behavior kept
	  • Prompt history — your last 20 prompts, one click to re-run

	How it works:
	  Same bridge as the base edition: this plugin talks to bridge.py on your
	  own PC (http://127.0.0.1:8765), which forwards prompts to `opencode run`
	  using your opencode.json config. No API keys leave your computer.

	Install:
	  1. If you have the base LibreMuse plugin, remove it first (Plugins folder).
	  2. Copy this file to:  %LOCALAPPDATA%\Roblox\Plugins\
	  3. Run bridge/bridge.py on your PC (keep it open).
	  4. Restart Roblox Studio. A new "LibreMuse Pro" toolbar button appears.
	  5. First HTTP request: Studio asks permission for localhost — Allow it.
	  6. Activation: paste the license key from your Whop purchase
	     (find it at whop.com/hub → LibreMuse Pro). One key per machine.
]]

local BRIDGE_BASE = "http://127.0.0.1:8765"
local PRO_VERSION = "1.0.0"

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")

-- ============ System prompts ============

local SYSTEM_PROMPT = table.concat({
	"You are an expert Roblox Luau programmer working inside Roblox Studio.",
	"Write clean, working Luau code. Prefer --!strict where sensible.",
	"The user may attach Studio context (selected script sources, place hierarchy).",
	"Use that context so your code fits their existing game: reference their actual",
	"instance names, RemoteEvents, and script structure instead of inventing new ones.",
	"RULES:",
	"1. Put the main code FIRST inside one ```lua fenced code block.",
	"2. After the code block, give a SHORT (2-4 sentence) explanation in plain text.",
	"3. Never put explanations inside the code block. No markdown outside except the one fence.",
}, "\n")

local BUILD_SYSTEM = table.concat({
	"You are an expert Roblox Luau programmer working inside Roblox Studio.",
	"The user may attach Studio context (selected script sources, place hierarchy).",
	"Use that context so your code fits their existing game.",
	"Output ONLY one ```lua fenced code block containing the complete, working Luau code.",
	"No explanations. No text outside the fence.",
}, "\n")

local DEBUG_SYSTEM = table.concat({
	"You are a Roblox Luau debugging expert working inside Roblox Studio.",
	"The user gives you a full script plus an error message (or a description of the bug).",
	"Find the bug and return the COMPLETE fixed script.",
	"RULES:",
	"1. Output ONLY one ```lua fenced code block with the complete, working script.",
	"2. Keep everything that already works; change only what is needed to fix the bug.",
	"3. After the code block, give a SHORT (2-4 sentence) explanation of what was wrong and what you changed.",
	"4. No text inside the code block except code. No markdown outside except the one fence.",
}, "\n")

local EXPLAIN_SYSTEM = table.concat({
	"You are a patient Roblox Luau teacher working inside Roblox Studio.",
	"The user gives you a script. Explain it in plain, friendly English.",
	"Cover: what the script does overall, then walk through it section by section",
	"(services, variables, functions, events, loops), then flag any bugs, risks,",
	"or performance issues you spot.",
	"Keep it readable for a beginner-to-intermediate scripter. Short code snippets",
	"are fine to illustrate a point, but do NOT dump the whole script back.",
}, "\n")

local OPTIMIZE_SYSTEM = table.concat({
	"You are a Roblox Luau performance expert working inside Roblox Studio.",
	"The user gives you a script. Refactor it for performance and quality while",
	"keeping its behavior IDENTICAL: remove wasteful loops, cache services and",
	"GetService calls, avoid per-frame allocations, disconnect unused connections,",
	"use task.wait/task.spawn instead of legacy wait/spawn, add --!strict and",
	"sensible type annotations.",
	"RULES:",
	"1. Output ONLY one ```lua fenced code block with the complete refactored script.",
	"2. After the code block, list the changes you made as short bullet points.",
	"3. No text inside the code block except code. No markdown outside except the one fence.",
}, "\n")

local VALID_CLASSES = { Script = true, LocalScript = true, ModuleScript = true }
local VALID_PARENTS = {
	ServerScriptService = true,
	ServerStorage = true,
	ReplicatedStorage = true,
	StarterPlayerScripts = true,
	StarterCharacterScripts = true,
	Workspace = true,
}

-- Context limits (keep prompts within model limits)
local MAX_SCRIPT_CHARS = 8000
local MAX_SCRIPT_FILES = 5
local MAX_TREE_DEPTH = 4
local PER_ROOT_TREE_LINES = 60
local MAX_CHILDREN_DESCEND = 300

-- Pro persistence
local SET_TEMPLATES = "LibreMusePro_Templates_v1"
local SET_HISTORY = "LibreMusePro_History_v1"
local HISTORY_MAX = 20

-- ============ Built-in prompt library ============

local BUILTIN_TEMPLATES = {
	{ name = "🌀 Double jump", mode = "generate",
		text = "Add a double-jump to the player character: pressing Space while mid-air grants one extra jump with a small particle puff. Put the logic in StarterCharacterScripts." },
	{ name = "⚡ Sprint + stamina", mode = "generate",
		text = "Add shift-to-sprint with a stamina bar GUI: stamina drains while sprinting, refills when idle, and sprint stops at 0 stamina. Smooth FOV kick while sprinting." },
	{ name = "💾 Leaderstats + DataStore", mode = "generate",
		text = "Create a leaderstats system with Coins and Wins, saved per player with DataStoreService using pcall and UpdateAsync. Grant 10 coins every 60 seconds of playtime." },
	{ name = "🌙 Day/night cycle", mode = "generate",
		text = "Make a smooth day/night cycle: Lighting.ClockTime loops 0-24 over 10 minutes, tweening ambient and outdoor ambient colors between day and night palettes." },
	{ name = "🐞 Fix this script", mode = "debug",
		text = "" },
	{ name = "💬 Comment my code", mode = "generate",
		text = "Add clear comments to the attached script explaining each section: what each service, variable, function, and event connection does. Do not change the logic." },
}

-- ============ Settings helpers (JSON in plugin settings) ============

local function loadTableSetting(key)
	local ok, raw = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and type(raw) == "string" and raw ~= "" then
		local dok, val = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		if dok and type(val) == "table" then
			return val
		end
	end
	return {}
end

local function saveTableSetting(key, tbl)
	pcall(function()
		plugin:SetSetting(key, HttpService:JSONEncode(tbl))
	end)
end

-- ============ License gate ============
-- Buyers activate with the license key Whop issues on purchase
-- (whop.com/hub → product). The key is validated through bridge.py
-- against Whop's API and bound to the first machine that uses it.

local SET_LICENSE = "LibreMusePro_License_v1"
local licenseKey = ""
local licenseOverlay = nil

local function getStoredLicense()
	local ok, raw = pcall(function()
		return plugin:GetSetting(SET_LICENSE)
	end)
	if ok and type(raw) == "string" and raw ~= "" then
		return raw
	end
	return ""
end

-- cb(valid, message)
local function validateLicenseKey(key, cb)
	task.spawn(function()
		local data, err = bridgeRequest("POST", "/validate", { license_key = key })
		if not data then
			cb(false, err)
		else
			cb(data.valid == true, data.text)
		end
	end)
end

-- ============ Toolbar / Widget ============

local toolbar = plugin:CreateToolbar("LibreMuse Pro")
local toggleBtn = toolbar:CreateButton(
	"LibreMuseProToggle",
	"Open LibreMuse Pro (powered by your opencode setup)",
	""
)
toggleBtn.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false,
	false,
	400, 720,
	320, 480
)
local widget = plugin:CreateDockWidgetPluginGui("LibreMuseProWidget", widgetInfo)
widget.Title = "LibreMuse Pro"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

toggleBtn.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

-- ============ UI helpers ============

local PAD = 10

local function styleInput(inst)
	inst.Font = Enum.Font.SourceSans
	inst.TextSize = 14
	inst.BackgroundColor3 = Color3.fromRGB(32, 32, 38)
	inst.TextColor3 = Color3.fromRGB(235, 235, 240)
	inst.BorderSizePixel = 0
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = inst
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, 8)
	p.PaddingRight = UDim.new(0, 8)
	p.PaddingTop = UDim.new(0, 6)
	p.PaddingBottom = UDim.new(0, 6)
	p.Parent = inst
	return inst
end

local function styleButton(btn, color)
	btn.Font = Enum.Font.SourceSansBold
	btn.TextSize = 15
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.BackgroundColor3 = color
	btn.AutoButtonColor = true
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = btn
	return btn
end

local function makeListPanel(name)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = name
	scroll.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.fromScale(0, 0)
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Size = UDim2.new(1, -PAD * 2, 0, 120)
	scroll.Position = UDim2.new(0, PAD, 0, PAD + 294)
	scroll.Visible = false
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = scroll
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = scroll
	scroll.Parent = widget
	return scroll
end

-- ============ Mode state ============

local currentMode = "generate" -- generate | debug | explain | optimize
local lastCode = "" -- last extracted code (for insert/replace)
local lastHadFence = true
local lastTarget = nil -- script the last debug/explain/optimize ran on

local MODE_HINTS = {
	generate = "Describe what to build — e.g. 'add a double-jump to my character'...",
	debug = "Select a script, then paste the error message (or describe the bug)...",
	explain = "Select a script — optional: ask about one part of it...",
	optimize = "Select a script — optional: name a goal, e.g. 'reduce lag in the loop'...",
}

local MODE_SYSTEMS = {
	generate = SYSTEM_PROMPT,
	debug = DEBUG_SYSTEM,
	explain = EXPLAIN_SYSTEM,
	optimize = OPTIMIZE_SYSTEM,
}

-- ============ UI: mode tabs ============

local modeRow = Instance.new("Frame")
modeRow.Name = "ModeRow"
modeRow.BackgroundTransparency = 1
modeRow.Size = UDim2.new(1, -PAD * 2, 0, 30)
modeRow.Position = UDim2.new(0, PAD, 0, PAD)
modeRow.Parent = widget

local MODES = { "generate", "debug", "explain", "optimize" }
local MODE_LABELS = { generate = "✨ Generate", debug = "🐞 Debug", explain = "💬 Explain", optimize = "🚀 Optimize" }
local modeButtons = {}

for i, mode in ipairs(MODES) do
	local b = Instance.new("TextButton")
	b.Name = "Mode_" .. mode
	b.Text = MODE_LABELS[mode]
	b.Font = Enum.Font.SourceSansBold
	b.TextSize = 12
	b.TextColor3 = Color3.fromRGB(220, 220, 230)
	b.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
	b.Size = UDim2.new(1 / 4, -4, 1, 0)
	b.Position = UDim2.new((i - 1) / 4, (i - 1) * 2, 0, 0)
	b.AutoButtonColor = true
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	b.Parent = modeRow
	modeButtons[mode] = b
end

local proBadge = Instance.new("TextLabel")
proBadge.Text = "PRO v" .. PRO_VERSION
proBadge.Font = Enum.Font.SourceSansBold
proBadge.TextSize = 11
proBadge.TextColor3 = Color3.fromRGB(20, 20, 20)
proBadge.BackgroundColor3 = Color3.fromRGB(255, 200, 60)
proBadge.Size = UDim2.new(0, 64, 0, 18)
proBadge.Position = UDim2.new(1, -74, 0, PAD + 6)
local bc = Instance.new("UICorner")
bc.CornerRadius = UDim.new(0, 9)
bc.Parent = proBadge
proBadge.Parent = widget

local promptBox = styleInput(Instance.new("TextBox"))
promptBox.Name = "PromptBox"
promptBox.PlaceholderText = MODE_HINTS.generate
promptBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 140)
promptBox.Text = ""
promptBox.TextWrapped = true
promptBox.MultiLine = true
promptBox.ClearTextOnFocus = false
promptBox.TextXAlignment = Enum.TextXAlignment.Left
promptBox.TextYAlignment = Enum.TextYAlignment.Top
promptBox.Size = UDim2.new(1, -PAD * 2, 0, 80)
promptBox.Position = UDim2.new(0, PAD, 0, PAD + 56)
promptBox.Parent = widget

local generateBtn = styleButton(Instance.new("TextButton"), Color3.fromRGB(0, 150, 90))
generateBtn.Name = "GenerateBtn"
generateBtn.Text = "Generate Code"
generateBtn.Size = UDim2.new(1, -PAD * 2, 0, 34)
generateBtn.Position = UDim2.new(0, PAD, 0, PAD + 142)
generateBtn.Parent = widget

local buildBtn = styleButton(Instance.new("TextButton"), Color3.fromRGB(110, 70, 180))
buildBtn.Name = "BuildBtn"
buildBtn.Text = "Build Game (multi-step)"
buildBtn.Size = UDim2.new(1, -PAD * 2, 0, 34)
buildBtn.Position = UDim2.new(0, PAD, 0, PAD + 182)
buildBtn.Parent = widget

-- Context toggles row
local ctxRow = Instance.new("Frame")
ctxRow.Name = "CtxRow"
ctxRow.BackgroundTransparency = 1
ctxRow.Size = UDim2.new(1, -PAD * 2, 0, 30)
ctxRow.Position = UDim2.new(0, PAD, 0, PAD + 222)
ctxRow.Parent = widget

local attachScripts = false
local attachTree = false

local function makeToggle(text, order, parent)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Font = Enum.Font.SourceSans
	b.TextSize = 13
	b.TextColor3 = Color3.fromRGB(220, 220, 230)
	b.BackgroundColor3 = Color3.fromRGB(55, 55, 65)
	b.Size = UDim2.new(1 / 2, -4, 1, 0)
	b.Position = UDim2.new((order - 1) / 2, (order - 1) * 4, 0, 0)
	b.AutoButtonColor = true
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	b.Parent = parent
	return b
end

local scriptsToggle = makeToggle("📎 Selected scripts: OFF", 1, ctxRow)
local treeToggle = makeToggle("📎 Hierarchy: OFF", 2, ctxRow)

local function refreshToggles()
	scriptsToggle.Text = "📎 Selected scripts: " .. (attachScripts and "ON" or "OFF")
	treeToggle.Text = "📎 Hierarchy: " .. (attachTree and "ON" or "OFF")
	scriptsToggle.BackgroundColor3 = attachScripts and Color3.fromRGB(40, 110, 180) or Color3.fromRGB(55, 55, 65)
	treeToggle.BackgroundColor3 = attachTree and Color3.fromRGB(40, 110, 180) or Color3.fromRGB(55, 55, 65)
end

scriptsToggle.MouseButton1Click:Connect(function()
	attachScripts = not attachScripts
	refreshToggles()
end)
treeToggle.MouseButton1Click:Connect(function()
	attachTree = not attachTree
	refreshToggles()
end)

-- Pro row: templates + history toggles
local proRow = Instance.new("Frame")
proRow.Name = "ProRow"
proRow.BackgroundTransparency = 1
proRow.Size = UDim2.new(1, -PAD * 2, 0, 30)
proRow.Position = UDim2.new(0, PAD, 0, PAD + 258)
proRow.Parent = widget

local templatesToggle = makeToggle("📚 Templates", 1, proRow)
local historyToggle = makeToggle("🕘 History", 2, proRow)

local templatePanel = makeListPanel("TemplatePanel")
local historyPanel = makeListPanel("HistoryPanel")

-- Forward declaration: assigned after the output UI below is built
-- (it repositions statusLabel/outputScroll/btnRow, which don't exist yet here).
local layoutPanels
local licenseBtn -- small footer button that reopens the license overlay

templatesToggle.MouseButton1Click:Connect(function()
	templatePanel.Visible = not templatePanel.Visible
	if templatePanel.Visible then
		historyPanel.Visible = false
	end
	layoutPanels()
end)
historyToggle.MouseButton1Click:Connect(function()
	historyPanel.Visible = not historyPanel.Visible
	if historyPanel.Visible then
		templatePanel.Visible = false
	end
	layoutPanels()
end)

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "StatusLabel"
statusLabel.Text = "Ready. Start bridge.py, then type a prompt."
statusLabel.Font = Enum.Font.SourceSansItalic
statusLabel.TextSize = 13
statusLabel.TextColor3 = Color3.fromRGB(150, 200, 255)
statusLabel.BackgroundTransparency = 1
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
statusLabel.Size = UDim2.new(1, -PAD * 2, 0, 20)
statusLabel.Position = UDim2.new(0, PAD, 0, PAD + 294)
statusLabel.Parent = widget

local outputScroll = Instance.new("ScrollingFrame")
outputScroll.Name = "OutputScroll"
outputScroll.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
outputScroll.BorderSizePixel = 0
outputScroll.ScrollBarThickness = 6
outputScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
outputScroll.CanvasSize = UDim2.fromScale(0, 0)
outputScroll.ScrollingDirection = Enum.ScrollingDirection.Y
outputScroll.Size = UDim2.new(1, -PAD * 2, 0, 170)
outputScroll.Position = UDim2.new(0, PAD, 0, PAD + 318)
local oc = Instance.new("UICorner")
oc.CornerRadius = UDim.new(0, 6)
oc.Parent = outputScroll
outputScroll.Parent = widget

local outputLabel = Instance.new("TextLabel")
outputLabel.Name = "OutputLabel"
outputLabel.Text = "-- output appears here --"
outputLabel.Font = Enum.Font.Code
outputLabel.TextSize = 13
outputLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
outputLabel.BackgroundTransparency = 1
outputLabel.TextWrapped = true
outputLabel.TextXAlignment = Enum.TextXAlignment.Left
outputLabel.TextYAlignment = Enum.TextYAlignment.Top
outputLabel.AutomaticSize = Enum.AutomaticSize.Y
outputLabel.Size = UDim2.fromScale(1, 0)
local op = Instance.new("UIPadding")
op.PaddingLeft = UDim.new(0, 8)
op.PaddingRight = UDim.new(0, 8)
op.PaddingTop = UDim.new(0, 8)
op.PaddingBottom = UDim.new(0, 8)
op.Parent = outputLabel
outputLabel.Parent = outputScroll

-- Action buttons row
local btnRow = Instance.new("Frame")
btnRow.Name = "BtnRow"
btnRow.BackgroundTransparency = 1
btnRow.Size = UDim2.new(1, -PAD * 2, 0, 36)
btnRow.Position = UDim2.new(0, PAD, 0, PAD + 494)
btnRow.Parent = widget

local actionButtons = {}

local function makeActionButton(text, order)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Font = Enum.Font.SourceSansBold
	b.TextSize = 13
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.BackgroundColor3 = Color3.fromRGB(60, 90, 160)
	b.Size = UDim2.new(1 / 3, -6, 1, 0)
	b.Position = UDim2.new((order - 1) / 3, (order - 1) * 3, 0, 0)
	b.AutoButtonColor = true
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	b.Parent = btnRow
	table.insert(actionButtons, b)
	return b
end

local insertScriptBtn = makeActionButton("Insert Script", 1)
local insertModuleBtn = makeActionButton("Insert Module", 2)
local replaceBtn = makeActionButton("Replace Selected", 3)

-- Small footer button to view/change the license key
licenseBtn = Instance.new("TextButton")
licenseBtn.Name = "LicenseBtn"
licenseBtn.Text = "🔑 License"
licenseBtn.Font = Enum.Font.SourceSans
licenseBtn.TextSize = 12
licenseBtn.TextColor3 = Color3.fromRGB(170, 170, 180)
licenseBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
licenseBtn.AutoButtonColor = true
licenseBtn.Size = UDim2.new(1, -PAD * 2, 0, 24)
licenseBtn.Position = UDim2.new(0, PAD, 0, PAD + 536)
local lbc = Instance.new("UICorner")
lbc.CornerRadius = UDim.new(0, 6)
lbc.Parent = licenseBtn
licenseBtn.Parent = widget
licenseBtn.MouseButton1Click:Connect(function()
	showLicenseOverlay(true)
end)

-- ============ Layout (assigned here, after the UI above exists) ============

layoutPanels = function()
	local shift = 0
	if templatePanel.Visible or historyPanel.Visible then
		shift = 126
	end
	statusLabel.Position = UDim2.new(0, PAD, 0, PAD + 294 + shift)
	outputScroll.Position = UDim2.new(0, PAD, 0, PAD + 318 + shift)
	btnRow.Position = UDim2.new(0, PAD, 0, PAD + 494 + shift)
	licenseBtn.Position = UDim2.new(0, PAD, 0, PAD + 536 + shift)
end

local function setStatus(text, color)
	statusLabel.Text = text
	statusLabel.TextColor3 = color or Color3.fromRGB(150, 200, 255)
end

local function setOutput(text)
	outputLabel.Text = text
	outputScroll.CanvasPosition = Vector2.new(0, 0)
end

local function setActionsEnabled(enabled)
	for _, b in ipairs(actionButtons) do
		b.AutoButtonColor = enabled
		b.BackgroundColor3 = enabled and Color3.fromRGB(60, 90, 160) or Color3.fromRGB(70, 70, 78)
		b.TextColor3 = enabled and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(150, 150, 160)
	end
end

-- ============ Studio context ============

local function getSelectedScriptsContext()
	local parts = {}
	local count = 0
	for _, inst in ipairs(Selection:Get()) do
		if inst:IsA("LuaSourceContainer") then
			count += 1
			if count > MAX_SCRIPT_FILES then
				table.insert(parts, "-- ... (more selected scripts omitted)")
				break
			end
			local src = inst.Source
			if #src > MAX_SCRIPT_CHARS then
				src = src:sub(1, MAX_SCRIPT_CHARS) .. "\n-- (truncated)"
			end
			table.insert(parts, "-- ===== " .. inst:GetFullName() .. " =====\n" .. src)
		end
	end
	if #parts == 0 then
		return ""
	end
	return "SELECTED SCRIPTS:\n" .. table.concat(parts, "\n\n") .. "\n"
end

local function getFirstSelectedScript()
	for _, inst in ipairs(Selection:Get()) do
		if inst:IsA("LuaSourceContainer") then
			return inst
		end
	end
	return nil
end

local function getHierarchyContext()
	local lines = {}
	local roots = {
		"ServerScriptService",
		"ServerStorage",
		"ReplicatedStorage",
		"StarterGui",
		"StarterPack",
		"StarterPlayer",
		"Workspace",
	}
	for _, svcName in ipairs(roots) do
		local ok, root = pcall(function()
			return game:GetService(svcName)
		end)
		if ok and root then
			local count = 0
			local function walk(inst, depth)
				if count >= PER_ROOT_TREE_LINES or depth > MAX_TREE_DEPTH then
					return
				end
				count += 1
				table.insert(lines, string.rep("  ", depth) .. svcName .. " / " .. inst.ClassName .. ": " .. inst.Name)
				if depth < MAX_TREE_DEPTH then
					local children = inst:GetChildren()
					if #children > MAX_CHILDREN_DESCEND then
						count += 1
						table.insert(lines, string.rep("  ", depth + 1)
							.. "-- (+" .. #children .. " children not listed)")
						return
					end
					for _, child in ipairs(children) do
						if count >= PER_ROOT_TREE_LINES then
							break
						end
						walk(child, depth + 1)
					end
				end
			end
			walk(root, 0)
			if count >= PER_ROOT_TREE_LINES then
				table.insert(lines, "-- (" .. svcName .. " truncated)")
			end
			table.insert(lines, "")
		end
	end
	return "PLACE HIERARCHY (Service / ClassName: Name):\n" .. table.concat(lines, "\n") .. "\n"
end

local function buildContext()
	local ctx = {}
	if attachScripts then
		local s = getSelectedScriptsContext()
		if s == "" then
			setStatus("No script selected — attach skipped.", Color3.fromRGB(255, 180, 80))
		else
			table.insert(ctx, s)
		end
	end
	if attachTree then
		table.insert(ctx, getHierarchyContext())
	end
	if #ctx == 0 then
		return ""
	end
	return "CONTEXT FROM THE USER'S OPEN PLACE:\n" .. table.concat(ctx, "\n") .. "\n---\n"
end

-- ============ Bridge calls ============

local function bridgeRequest(method, path, body)
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = BRIDGE_BASE .. path,
			Method = method,
			Headers = { ["Content-Type"] = "application/json" },
			Body = body and HttpService:JSONEncode(body) or nil,
		})
	end)
	if not ok then
		return nil, "Bridge not reachable. Is bridge.py running? (" .. tostring(res) .. ")"
	end
	if not res.Success then
		return nil, "Bridge error (HTTP " .. tostring(res.StatusCode) .. "): " .. tostring(res.Body):sub(1, 200)
	end
	local dok, data = pcall(function()
		return HttpService:JSONDecode(res.Body)
	end)
	if not dok then
		return nil, "Bad response from bridge."
	end
	return data, nil
end

local function pollJob(jobId, onTick)
	local tries = 0
	while tries < 150 do -- ~5 minutes max
		task.wait(2)
		tries += 1
		local r, rerr = bridgeRequest("GET", "/result?id=" .. jobId)
		if not r then
			return nil, rerr
		end
		if r.status == "done" then
			return r, nil
		elseif r.status == "error" then
			return nil, tostring(r.text or r.error or "unknown error"):sub(1, 300)
		end
		if onTick and tries % 10 == 0 then
			onTick(tries * 2)
		end
	end
	return nil, "Timed out waiting for opencode."
end

local function startJob(path, body)
	local data, err = bridgeRequest("POST", path, body)
	if not data then
		return nil, err
	end
	if not data.job_id then
		return nil, "Bridge didn't return a job id."
	end
	return data.job_id, nil
end

local function extractCode(text)
	local code = text:match("```%w*\n(.-)```")
	if code then
		return code:gsub("^%s+", ""):gsub("%s+$", ""), true
	end
	return (text or ""):gsub("^%s+", ""):gsub("%s+$", ""), false
end

local function sanitizeName(name)
	local clean = tostring(name or ""):gsub("[^%w ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if clean == "" then
		clean = "LibreMuseGenerated"
	end
	return clean:sub(1, 40)
end

-- ============ Prompt history ============

local function refreshHistory()
	for _, child in ipairs(historyPanel:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local history = loadTableSetting(SET_HISTORY)
	for i, item in ipairs(history) do
		local b = Instance.new("TextButton")
		b.Name = "Hist" .. i
		b.LayoutOrder = i
		b.Text = "🕘 [" .. tostring(item.mode or "?") .. "] "
			.. tostring(item.prompt or ""):sub(1, 52)
		b.Font = Enum.Font.SourceSans
		b.TextSize = 12
		b.TextColor3 = Color3.fromRGB(220, 220, 230)
		b.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.TextTruncate = Enum.TextTruncate.AtEnd
		b.AutomaticSize = Enum.AutomaticSize.Y
		b.Size = UDim2.new(1, -12, 0, 26)
		b.AutoButtonColor = true
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = b
		local p = Instance.new("UIPadding")
		p.PaddingLeft = UDim.new(0, 8)
		p.Parent = b
		b.Parent = historyPanel
		local mode = item.mode
		local prompt = item.prompt
		b.MouseButton1Click:Connect(function()
			if mode and MODE_SYSTEMS[mode] then
				setMode(mode)
			end
			promptBox.Text = prompt or ""
			setStatus("Loaded from history.", Color3.fromRGB(150, 200, 255))
		end)
	end
	if #history == 0 then
		local l = Instance.new("TextLabel")
		l.Text = "No history yet — your prompts will appear here."
		l.Font = Enum.Font.SourceSansItalic
		l.TextSize = 12
		l.TextColor3 = Color3.fromRGB(130, 130, 140)
		l.BackgroundTransparency = 1
		l.Size = UDim2.new(1, -12, 0, 26)
		l.Parent = historyPanel
	end
end

local function addToHistory(mode, prompt)
	prompt = tostring(prompt or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if prompt == "" then
		return
	end
	local history = loadTableSetting(SET_HISTORY)
	-- drop duplicates of the same prompt
	for i = #history, 1, -1 do
		if history[i].prompt == prompt then
			table.remove(history, i)
		end
	end
	table.insert(history, 1, { mode = mode, prompt = prompt, time = os.time() })
	while #history > HISTORY_MAX do
		table.remove(history)
	end
	saveTableSetting(SET_HISTORY, history)
	refreshHistory()
end

-- ============ Prompt library ============

local function getUserTemplates()
	return loadTableSetting(SET_TEMPLATES)
end

local function refreshTemplates()
	for _, child in ipairs(templatePanel:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local order = 0
	local function addRow(name, text, mode, isBuiltin)
		order += 1
		local b = Instance.new("TextButton")
		b.Name = "Tpl" .. order
		b.LayoutOrder = order
		b.Text = (isBuiltin and "" or "⭐ ") .. name
		b.Font = Enum.Font.SourceSans
		b.TextSize = 13
		b.TextColor3 = Color3.fromRGB(235, 235, 240)
		b.BackgroundColor3 = isBuiltin and Color3.fromRGB(45, 45, 55) or Color3.fromRGB(70, 55, 25)
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.TextTruncate = Enum.TextTruncate.AtEnd
		b.AutomaticSize = Enum.AutomaticSize.Y
		b.Size = UDim2.new(1, -12, 0, 28)
		b.AutoButtonColor = true
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = b
		local p = Instance.new("UIPadding")
		p.PaddingLeft = UDim.new(0, 8)
		p.Parent = b
		b.Parent = templatePanel
		b.MouseButton1Click:Connect(function()
			if mode and MODE_SYSTEMS[mode] then
				setMode(mode)
			end
			promptBox.Text = text or ""
			setStatus("Template loaded: " .. name, Color3.fromRGB(150, 200, 255))
		end)
	end
	for _, t in ipairs(BUILTIN_TEMPLATES) do
		addRow(t.name, t.text, t.mode, true)
	end
	for _, t in ipairs(getUserTemplates()) do
		addRow(t.name, t.text, t.mode, false)
	end
	-- Save-current row
	order += 1
	local saveBtn = Instance.new("TextButton")
	saveBtn.Name = "TplSave"
	saveBtn.LayoutOrder = order
	saveBtn.Text = "＋ Save current prompt as template"
	saveBtn.Font = Enum.Font.SourceSansBold
	saveBtn.TextSize = 12
	saveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	saveBtn.BackgroundColor3 = Color3.fromRGB(40, 110, 70)
	saveBtn.AutomaticSize = Enum.AutomaticSize.Y
	saveBtn.Size = UDim2.new(1, -12, 0, 28)
	saveBtn.AutoButtonColor = true
	local sc = Instance.new("UICorner")
	sc.CornerRadius = UDim.new(0, 5)
	sc.Parent = saveBtn
	saveBtn.Parent = templatePanel
	saveBtn.MouseButton1Click:Connect(function()
		local text = promptBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if text == "" then
			setStatus("Type a prompt first, then save it.", Color3.fromRGB(255, 180, 80))
			return
		end
		local user = getUserTemplates()
		local name = text:sub(1, 32)
		if #text > 32 then
			name ..= "..."
		end
		table.insert(user, { name = name, text = text, mode = currentMode })
		saveTableSetting(SET_TEMPLATES, user)
		refreshTemplates()
		setStatus("Template saved.", Color3.fromRGB(140, 255, 170))
	end)
	-- Clear-custom row
	order += 1
	local clearBtn = Instance.new("TextButton")
	clearBtn.Name = "TplClear"
	clearBtn.LayoutOrder = order
	clearBtn.Text = "Clear my saved templates"
	clearBtn.Font = Enum.Font.SourceSans
	clearBtn.TextSize = 12
	clearBtn.TextColor3 = Color3.fromRGB(200, 120, 120)
	clearBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
	clearBtn.AutomaticSize = Enum.AutomaticSize.Y
	clearBtn.Size = UDim2.new(1, -12, 0, 24)
	clearBtn.AutoButtonColor = true
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 5)
	cc.Parent = clearBtn
	clearBtn.Parent = templatePanel
	clearBtn.MouseButton1Click:Connect(function()
		saveTableSetting(SET_TEMPLATES, {})
		refreshTemplates()
		setStatus("Saved templates cleared.", Color3.fromRGB(150, 200, 255))
	end)
end

-- ============ Modes ============

function setMode(mode)
	if not MODE_SYSTEMS[mode] then
		return
	end
	currentMode = mode
	for m, b in pairs(modeButtons) do
		local active = (m == mode)
		b.BackgroundColor3 = active and Color3.fromRGB(255, 170, 40) or Color3.fromRGB(55, 55, 65)
		b.TextColor3 = active and Color3.fromRGB(25, 25, 25) or Color3.fromRGB(220, 220, 230)
	end
	promptBox.PlaceholderText = MODE_HINTS[mode]
	generateBtn.Text = ({
		generate = "Generate Code",
		debug = "🐞 Fix My Script",
		explain = "💬 Explain Script",
		optimize = "🚀 Optimize Script",
	})[mode]
	-- Insert/replace only make sense when the output is code
	setActionsEnabled(mode ~= "explain")
end

for m, b in pairs(modeButtons) do
	b.MouseButton1Click:Connect(function()
		setMode(m)
	end)
end

local busy = false

-- Shared runner for generate/debug/explain/optimize via /chat
local function runChatMode()
	if busy then
		return
	end
	local promptText = promptBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
	local context = buildContext()
	local fullPrompt, needsScript, target

	if currentMode == "generate" then
		if promptText == "" then
			setStatus("Type a prompt first.", Color3.fromRGB(255, 180, 80))
			return
		end
		fullPrompt = context .. promptText
	else
		target = getFirstSelectedScript()
		if not target then
			setStatus("Select a script in the Explorer first.", Color3.fromRGB(255, 180, 80))
			return
		end
		lastTarget = target
		local src = target.Source
		if #src > MAX_SCRIPT_CHARS then
			src = src:sub(1, MAX_SCRIPT_CHARS) .. "\n-- (truncated)"
		end
		if currentMode == "debug" then
			if promptText == "" then
				setStatus("Paste the error message (or describe the bug).", Color3.fromRGB(255, 180, 80))
				return
			end
			fullPrompt = context .. "SCRIPT TO FIX (" .. target:GetFullName() .. "):\n```lua\n"
				.. src .. "\n```\n\nERROR / BUG DESCRIPTION:\n" .. promptText
		elseif currentMode == "explain" then
			fullPrompt = context .. "EXPLAIN THIS SCRIPT (" .. target:GetFullName() .. "):\n```lua\n"
				.. src .. "\n```"
			if promptText ~= "" then
				fullPrompt ..= "\n\nFOCUS ON: " .. promptText
			end
		else -- optimize
			fullPrompt = context .. "OPTIMIZE THIS SCRIPT, keeping behavior identical ("
				.. target:GetFullName() .. "):\n```lua\n" .. src .. "\n```"
			if promptText ~= "" then
				fullPrompt ..= "\n\nEXTRA GOAL: " .. promptText
			end
		end
	end

	busy = true
	local oldText = generateBtn.Text
	generateBtn.Text = "Working..."
	generateBtn.AutoButtonColor = false

	task.spawn(function()
		setStatus("Sending to opencode (" .. currentMode .. ")...")
		local jobId, err = startJob("/chat", { prompt = fullPrompt, system = MODE_SYSTEMS[currentMode] })
		if not jobId then
			setStatus(err, Color3.fromRGB(255, 120, 120))
		else
			setStatus("opencode is thinking... (job " .. jobId:sub(1, 8) .. ")")
			local r, rerr = pollJob(jobId, function(secs)
				setStatus("Still thinking... (" .. secs .. "s)")
			end)
			if not r then
				setStatus(rerr, Color3.fromRGB(255, 120, 120))
			else
				local text = r.text or ""
				if currentMode == "explain" then
					setOutput(text ~= "" and text or "-- (empty response) --")
					lastCode = ""
					setStatus("Done. Explanation above.", Color3.fromRGB(140, 255, 170))
				else
					local code, hadFence = extractCode(text)
					lastCode = code
					lastHadFence = hadFence
					setOutput((text ~= "" and text) or "-- (empty response) --")
					if code == "" then
						setStatus("Empty response. Try again.", Color3.fromRGB(255, 180, 80))
					else
						addToHistory(currentMode, promptText ~= "" and promptText
							or ("[" .. currentMode .. " on " .. (target and target.Name or "?") .. "]"))
						local warn = hadFence and "" or " (No code block in reply — used full text.)"
						if currentMode == "debug" then
							setStatus("Fix ready. Review it, then Replace Selected." .. warn,
								Color3.fromRGB(140, 255, 170))
						elseif currentMode == "optimize" then
							setStatus("Optimized. Review it, then Replace Selected." .. warn,
								Color3.fromRGB(140, 255, 170))
						else
							setStatus("Done. Review the code, then insert it." .. warn,
								Color3.fromRGB(140, 255, 170))
						end
					end
				end
			end
		end
		busy = false
		generateBtn.Text = oldText
		generateBtn.AutoButtonColor = true
	end)
end

generateBtn.MouseButton1Click:Connect(runChatMode)

-- ============ Multi-step game builder ============

local buildState = "idle" -- idle | planned | building
local buildSteps = {}
local planPrompt = ""
local stopRequested = false

local function setBuildBtn()
	if buildState == "idle" then
		buildBtn.Text = "Build Game (multi-step)"
	elseif buildState == "planned" then
		buildBtn.Text = "Start Build (" .. #buildSteps .. " steps)"
	elseif buildState == "building" then
		buildBtn.Text = "Stop Build"
	end
end

local function insertBuiltStep(step, code)
	local className = VALID_CLASSES[step.class] and step.class or "Script"
	local parentName = VALID_PARENTS[step.parent] and step.parent or "ServerScriptService"
	local inst = Instance.new(className)
	inst.Name = sanitizeName(step.name)
	local ok, err = pcall(function()
		inst.Source = code
	end)
	if not ok then
		inst:Destroy()
		return nil, "Couldn't set source: " .. tostring(err):sub(1, 120)
	end
	inst.Parent = game:GetService(parentName)
	return inst, nil
end

local function runBuild()
	buildState = "building"
	stopRequested = false
	setBuildBtn()
	generateBtn.AutoButtonColor = false

	local context = buildContext()
	local inserted = {}
	task.spawn(function()
		for i, step in ipairs(buildSteps) do
			if stopRequested then
				setStatus("Build stopped by user.", Color3.fromRGB(255, 180, 80))
				break
			end
			setStatus("Step " .. i .. "/" .. #buildSteps .. ": " .. tostring(step.name))
			local jobId, err = startJob("/chat",
				{ prompt = context .. tostring(step.prompt), system = BUILD_SYSTEM })
			if not jobId then
				setStatus("Step " .. i .. " failed: " .. err, Color3.fromRGB(255, 120, 120))
				break
			end
			local r, rerr = pollJob(jobId)
			if not r then
				setStatus("Step " .. i .. " failed: " .. rerr, Color3.fromRGB(255, 120, 120))
				break
			end
			local code, hadFence = extractCode(r.text or "")
			if code == "" then
				setStatus("Step " .. i .. " returned empty code.", Color3.fromRGB(255, 120, 120))
				break
			end
			local inst, ierr = insertBuiltStep(step, code)
			if not inst then
				setStatus("Step " .. i .. " failed: " .. ierr, Color3.fromRGB(255, 120, 120))
				break
			end
			table.insert(inserted, inst)
			setOutput("Built " .. i .. "/" .. #buildSteps .. ": " .. inst:GetFullName()
				.. (hadFence and "" or " (no code block in reply — used full text)"))
		end
		if #inserted > 0 then
			Selection:Set(inserted)
		end
		if not stopRequested then
			setStatus("Build complete! " .. #inserted .. "/" .. #buildSteps .. " systems inserted.",
				Color3.fromRGB(140, 255, 170))
		end
		buildState = "idle"
		buildSteps = {}
		setBuildBtn()
		generateBtn.AutoButtonColor = true
	end)
end

local function onBuildBtn()
	if buildState == "building" then
		stopRequested = true
		setStatus("Stopping after current step...", Color3.fromRGB(255, 180, 80))
		return
	end
	if buildState == "planned" then
		local current = promptBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
		if current ~= "" and current ~= planPrompt then
			buildState = "idle"
			buildSteps = {}
		else
			runBuild()
			return
		end
	end
	if busy then
		return
	end
	local prompt = promptBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
	if prompt == "" then
		setStatus("Describe the game first.", Color3.fromRGB(255, 180, 80))
		return
	end
	planPrompt = prompt
	busy = true
	buildBtn.Text = "Planning..."
	buildBtn.AutoButtonColor = false

	task.spawn(function()
		local context = buildContext()
		setStatus("Asking opencode to plan the game"
			.. (context ~= "" and " (with Studio context)" or "") .. "...")
		local jobId, err = startJob("/plan", { prompt = context .. prompt })
		if not jobId then
			setStatus(err, Color3.fromRGB(255, 120, 120))
		else
			local r, rerr = pollJob(jobId, function(secs)
				setStatus("Planning... (" .. secs .. "s)")
			end)
			if not r then
				setStatus(rerr, Color3.fromRGB(255, 120, 120))
			elseif not r.steps or #r.steps == 0 then
				setStatus("Planner returned no steps. Try rephrasing.", Color3.fromRGB(255, 180, 80))
			else
				buildSteps = r.steps
				local lines = { "Plan (" .. #buildSteps .. " steps):" }
				for i, s in ipairs(buildSteps) do
					table.insert(lines, i .. ". [" .. tostring(s.class) .. " → " .. tostring(s.parent) .. "] "
						.. tostring(s.name))
				end
				table.insert(lines, "")
				table.insert(lines, 'Click "Start Build" to generate & insert each step.')
				table.insert(lines, "Tip: edit the description and click Build Game again to re-plan.")
				setOutput(table.concat(lines, "\n"))
				buildState = "planned"
				setStatus("Plan ready. Review it, then start the build.", Color3.fromRGB(140, 255, 170))
			end
		end
		busy = false
		setBuildBtn()
		buildBtn.AutoButtonColor = true
	end)
end

buildBtn.MouseButton1Click:Connect(onBuildBtn)

-- ============ Insert actions ============

local function insertAs(className, parentServiceName)
	if lastCode == "" then
		setStatus("Generate code first.", Color3.fromRGB(255, 180, 80))
		return
	end
	local inst = Instance.new(className)
	inst.Name = "LibreMuseProGenerated"
	local ok, err = pcall(function()
		inst.Source = lastCode
	end)
	if not ok then
		setStatus("Couldn't set source: " .. tostring(err):sub(1, 120), Color3.fromRGB(255, 120, 120))
		inst:Destroy()
		return
	end
	inst.Parent = game:GetService(parentServiceName)
	Selection:Set({ inst })
	setStatus("Inserted " .. className .. " into " .. parentServiceName .. "."
		.. (lastHadFence and "" or " (No code block in reply — used the full response text.)"),
		lastHadFence and Color3.fromRGB(140, 255, 170) or Color3.fromRGB(255, 180, 80))
end

insertScriptBtn.MouseButton1Click:Connect(function()
	insertAs("Script", "ServerScriptService")
end)

insertModuleBtn.MouseButton1Click:Connect(function()
	insertAs("ModuleScript", "ServerStorage")
end)

replaceBtn.MouseButton1Click:Connect(function()
	if lastCode == "" then
		setStatus("Generate code first.", Color3.fromRGB(255, 180, 80))
		return
	end
	-- Prefer the script the mode ran on; fall back to current selection.
	local target = lastTarget
	if not target or not target.Parent then
		local sel = Selection:Get()
		target = sel[1]
	end
	if not target or not target:IsA("LuaSourceContainer") then
		setStatus("Select a script in the Explorer first.", Color3.fromRGB(255, 180, 80))
		return
	end
	local ok, err = pcall(function()
		target.Source = lastCode
	end)
	if not ok then
		setStatus("Couldn't replace source: " .. tostring(err):sub(1, 120), Color3.fromRGB(255, 120, 120))
		return
	end
	setStatus("Replaced source of " .. target:GetFullName() .. "."
		.. (lastHadFence and "" or " (No code block in reply — used the full response text.)"),
		lastHadFence and Color3.fromRGB(140, 255, 170) or Color3.fromRGB(255, 180, 80))
end)

-- ============ License overlay ============

function showLicenseOverlay(canClose)
	if licenseOverlay then
		licenseOverlay:Destroy()
		licenseOverlay = nil
	end
	local ov = Instance.new("Frame")
	ov.Name = "LicenseOverlay"
	ov.Size = UDim2.fromScale(1, 1)
	ov.BackgroundColor3 = Color3.fromRGB(10, 10, 14)
	ov.BorderSizePixel = 0
	ov.ZIndex = 100
	ov.Parent = widget

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.45)
	card.Size = UDim2.new(0, 300, 0, 300)
	card.BackgroundColor3 = Color3.fromRGB(28, 28, 36)
	card.BorderSizePixel = 0
	card.ZIndex = 101
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0, 10)
	cc.Parent = card
	card.Parent = ov

	local title = Instance.new("TextLabel")
	title.Text = "🔑 LibreMuse Pro"
	title.Font = Enum.Font.SourceSansBold
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -20, 0, 30)
	title.Position = UDim2.new(0, 10, 0, 12)
	title.ZIndex = 102
	title.Parent = card

	local info = Instance.new("TextLabel")
	info.Text = "Paste the license key from your Whop purchase to activate.\nFind it at whop.com/hub → LibreMuse Pro.\nOne key works on one machine."
	info.Font = Enum.Font.SourceSans
	info.TextSize = 13
	info.TextColor3 = Color3.fromRGB(180, 180, 190)
	info.BackgroundTransparency = 1
	info.TextWrapped = true
	info.Size = UDim2.new(1, -20, 0, 60)
	info.Position = UDim2.new(0, 10, 0, 46)
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.ZIndex = 102
	info.Parent = card

	local keyBox = styleInput(Instance.new("TextBox"))
	keyBox.Name = "KeyBox"
	keyBox.PlaceholderText = "Paste license key here..."
	keyBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 140)
	keyBox.Text = ""
	keyBox.ClearTextOnFocus = false
	keyBox.Size = UDim2.new(1, -20, 0, 36)
	keyBox.Position = UDim2.new(0, 10, 0, 112)
	keyBox.ZIndex = 102
	keyBox.Parent = card

	local ovStatus = Instance.new("TextLabel")
	ovStatus.Name = "OvStatus"
	ovStatus.Text = ""
	ovStatus.Font = Enum.Font.SourceSansItalic
	ovStatus.TextSize = 12
	ovStatus.TextColor3 = Color3.fromRGB(255, 150, 150)
	ovStatus.BackgroundTransparency = 1
	ovStatus.TextWrapped = true
	ovStatus.Size = UDim2.new(1, -20, 0, 36)
	ovStatus.Position = UDim2.new(0, 10, 0, 152)
	ovStatus.TextXAlignment = Enum.TextXAlignment.Left
	ovStatus.ZIndex = 102
	ovStatus.Parent = card

	local activateBtn = styleButton(Instance.new("TextButton"), Color3.fromRGB(0, 150, 90))
	activateBtn.Name = "ActivateBtn"
	activateBtn.Text = "Activate"
	activateBtn.Size = UDim2.new(1, -20, 0, 38)
	activateBtn.Position = UDim2.new(0, 10, 0, 192)
	activateBtn.ZIndex = 102
	activateBtn.Parent = card

	if canClose then
		local closeBtn = Instance.new("TextButton")
		closeBtn.Text = "Close"
		closeBtn.Font = Enum.Font.SourceSans
		closeBtn.TextSize = 13
		closeBtn.TextColor3 = Color3.fromRGB(180, 180, 190)
		closeBtn.BackgroundTransparency = 1
		closeBtn.Size = UDim2.new(1, -20, 0, 28)
		closeBtn.Position = UDim2.new(0, 10, 0, 238)
		closeBtn.ZIndex = 102
		closeBtn.Parent = card
		closeBtn.MouseButton1Click:Connect(function()
			ov:Destroy()
			licenseOverlay = nil
		end)
	end

	activateBtn.MouseButton1Click:Connect(function()
		local key = keyBox.Text:gsub("%s+", "")
		if key == "" then
			ovStatus.Text = "Paste your license key first."
			return
		end
		activateBtn.Text = "Checking..."
		activateBtn.AutoButtonColor = false
		ovStatus.TextColor3 = Color3.fromRGB(150, 200, 255)
		ovStatus.Text = "Validating with Whop..."
		validateLicenseKey(key, function(ok, msg)
			activateBtn.Text = "Activate"
			activateBtn.AutoButtonColor = true
			if ok then
				licenseKey = key
				pcall(function()
					plugin:SetSetting(SET_LICENSE, key)
				end)
				ov:Destroy()
				licenseOverlay = nil
				setStatus("Activated. Welcome to LibreMuse Pro!", Color3.fromRGB(140, 255, 170))
			else
				ovStatus.TextColor3 = Color3.fromRGB(255, 150, 150)
				ovStatus.Text = msg or "Invalid license key."
			end
		end)
	end)

	licenseOverlay = ov
end

-- ============ Init ============

setMode("generate")
refreshToggles()
refreshTemplates()
refreshHistory()

-- License gate: block the UI until a valid key is stored
licenseKey = getStoredLicense()
if licenseKey == "" then
	setStatus("Activation required — paste your license key.", Color3.fromRGB(255, 180, 80))
	showLicenseOverlay(false)
end

task.spawn(function()
	local data, err = bridgeRequest("GET", "/ping")
	if data and data.ok then
		setStatus("Ready. Bridge connected — type a prompt.")
	else
		setStatus("Bridge not running. Start bridge.py first.", Color3.fromRGB(255, 180, 80))
	end
end)

print("[LibreMuse Pro v" .. PRO_VERSION .. "] plugin loaded. Waiting for bridge at " .. BRIDGE_BASE)
