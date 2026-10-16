--[[
	LibreMuse.lua — Roblox Studio plugin
	AI chat + multi-step game builder inside Studio, powered by YOUR local opencode setup.

	What the AI can "see":
	  By default the AI only sees your typed prompt. Toggle the context buttons
	  to also attach: (1) the source of scripts selected in the Explorer,
	  (2) a truncated tree of your place hierarchy — so the AI writes code
	  that fits your existing game.

	How it works:
	  This plugin talks to a tiny bridge server on your own PC
	  (http://127.0.0.1:8765, see bridge/bridge.py). The bridge forwards
	  prompts to `opencode run` using your opencode.json config, then
	  returns the answer. No API keys leave your computer.

	Install:
	  1. Copy this file to:  %LOCALAPPDATA%\Roblox\Plugins\
	  2. Run bridge/bridge.py on your PC (keep it open).
	  3. Restart Roblox Studio. A new "LibreMuse" toolbar button appears.
	  4. First HTTP request: Studio asks permission for localhost — Allow it.
	  5. Activation: paste the license key from your Whop purchase
	     (find it at whop.com/hub → LibreMuse). One key per machine.
]]

local BRIDGE_BASE = "http://127.0.0.1:8765"

local HttpService = game:GetService("HttpService")
local Selection = game:GetService("Selection")

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

-- Strict code-only prompt used for each build step (easier to extract reliably)
local BUILD_SYSTEM = table.concat({
	"You are an expert Roblox Luau programmer working inside Roblox Studio.",
	"The user may attach Studio context (selected script sources, place hierarchy).",
	"Use that context so your code fits their existing game.",
	"Output ONLY one ```lua fenced code block containing the complete, working Luau code.",
	"No explanations. No text outside the fence.",
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
local PER_ROOT_TREE_LINES = 60 -- per service: one giant folder can no longer eat the whole budget
local MAX_CHILDREN_DESCEND = 300 -- don't descend into folders bigger than this (voxel terrain, forests, ...)

-- ============ Toolbar / Widget ============

local toolbar = plugin:CreateToolbar("LibreMuse")
local toggleBtn = toolbar:CreateButton(
	"LibreMuseToggle",
	"Open the LibreMuse chat (powered by your opencode setup)",
	""
)
toggleBtn.ClickableWhenViewportHidden = true

local widgetInfo = DockWidgetPluginGuiInfo.new(
	Enum.InitialDockState.Right,
	false, -- initially disabled
	false, -- don't override previous state
	360, 620, -- default width, height
	280, 420 -- min width, height
)
local widget = plugin:CreateDockWidgetPluginGui("LibreMuseWidget", widgetInfo)
widget.Title = "LibreMuse"
widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

toggleBtn.Click:Connect(function()
	widget.Enabled = not widget.Enabled
end)

-- ============ UI ============

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

local promptBox = styleInput(Instance.new("TextBox"))
promptBox.Name = "PromptBox"
promptBox.PlaceholderText = "Describe what to build — e.g. 'add a double-jump to my character'..."
promptBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 140)
promptBox.Text = ""
promptBox.TextWrapped = true
promptBox.MultiLine = true
promptBox.ClearTextOnFocus = false
promptBox.TextXAlignment = Enum.TextXAlignment.Left
promptBox.TextYAlignment = Enum.TextYAlignment.Top
promptBox.Size = UDim2.new(1, -PAD * 2, 0, 90)
promptBox.Position = UDim2.new(0, PAD, 0, PAD)
promptBox.Parent = widget

local generateBtn = styleButton(Instance.new("TextButton"), Color3.fromRGB(0, 150, 90))
generateBtn.Name = "GenerateBtn"
generateBtn.Text = "Generate Code"
generateBtn.Size = UDim2.new(1, -PAD * 2, 0, 34)
generateBtn.Position = UDim2.new(0, PAD, 0, PAD + 98)
generateBtn.Parent = widget

local buildBtn = styleButton(Instance.new("TextButton"), Color3.fromRGB(110, 70, 180))
buildBtn.Name = "BuildBtn"
buildBtn.Text = "Build Game (multi-step)"
buildBtn.Size = UDim2.new(1, -PAD * 2, 0, 34)
buildBtn.Position = UDim2.new(0, PAD, 0, PAD + 138)
buildBtn.Parent = widget

-- Context toggles row
local ctxRow = Instance.new("Frame")
ctxRow.Name = "CtxRow"
ctxRow.BackgroundTransparency = 1
ctxRow.Size = UDim2.new(1, -PAD * 2, 0, 30)
ctxRow.Position = UDim2.new(0, PAD, 0, PAD + 178)
ctxRow.Parent = widget

local attachScripts = false
local attachTree = false

local function makeToggle(text, order)
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
	b.Parent = ctxRow
	return b
end

local scriptsToggle = makeToggle("📎 Selected scripts: OFF", 1)
local treeToggle = makeToggle("📎 Hierarchy: OFF", 2)

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
statusLabel.Position = UDim2.new(0, PAD, 0, PAD + 214)
statusLabel.Parent = widget

local outputScroll = Instance.new("ScrollingFrame")
outputScroll.Name = "OutputScroll"
outputScroll.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
outputScroll.BorderSizePixel = 0
outputScroll.ScrollBarThickness = 6
outputScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
outputScroll.CanvasSize = UDim2.fromScale(0, 0)
outputScroll.ScrollingDirection = Enum.ScrollingDirection.Y
outputScroll.Size = UDim2.new(1, -PAD * 2, 0, 200)
outputScroll.Position = UDim2.new(0, PAD, 0, PAD + 238)
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

-- Action buttons row (for single-generate mode)
local btnRow = Instance.new("Frame")
btnRow.Name = "BtnRow"
btnRow.BackgroundTransparency = 1
btnRow.Size = UDim2.new(1, -PAD * 2, 0, 36)
btnRow.Position = UDim2.new(0, PAD, 0, PAD + 446)
btnRow.Parent = widget

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
	return b
end

local insertScriptBtn = makeActionButton("Insert Script", 1)
local insertModuleBtn = makeActionButton("Insert Module", 2)
local replaceBtn = makeActionButton("Replace Selected", 3)

-- Small footer button to view/change the license key
local licenseBtn = Instance.new("TextButton")
licenseBtn.Name = "LicenseBtn"
licenseBtn.Text = "🔑 License"
licenseBtn.Font = Enum.Font.SourceSans
licenseBtn.TextSize = 12
licenseBtn.TextColor3 = Color3.fromRGB(170, 170, 180)
licenseBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
licenseBtn.AutoButtonColor = true
licenseBtn.Size = UDim2.new(1, -PAD * 2, 0, 24)
licenseBtn.Position = UDim2.new(0, PAD, 0, PAD + 490)
local lbc = Instance.new("UICorner")
lbc.CornerRadius = UDim.new(0, 6)
lbc.Parent = licenseBtn
licenseBtn.Parent = widget
licenseBtn.MouseButton1Click:Connect(function()
	showLicenseOverlay(true)
end)

local function setStatus(text, color)
	statusLabel.Text = text
	statusLabel.TextColor3 = color or Color3.fromRGB(150, 200, 255)
end

local function setOutput(text)
	outputLabel.Text = text
	outputScroll.CanvasPosition = Vector2.new(0, 0)
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

local function getHierarchyContext()
	local lines = {}
	-- Script services first: the AI needs scripts/remotes before it sees geometry.
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
						-- Giant container (voxel terrain, model forests...): list it, skip its children.
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

-- Poll a job until done/error/timeout. Returns the full result table.
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

-- Returns code, hadFence. When the model skips the fence, callers still get the
-- raw text but can warn the user instead of silently inserting prose.
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

-- ============ License gate ============
-- Buyers activate with the license key Whop issues on purchase
-- (whop.com/hub → product). The key is validated through bridge.py
-- against Whop's API and bound to the first machine that uses it.

local SET_LICENSE = "LibreMuse_License_v1"
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
	title.Text = "🔑 LibreMuse"
	title.Font = Enum.Font.SourceSansBold
	title.TextSize = 20
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, -20, 0, 30)
	title.Position = UDim2.new(0, 10, 0, 12)
	title.ZIndex = 102
	title.Parent = card

	local info = Instance.new("TextLabel")
	info.Text = "Paste the license key from your Whop purchase to activate.\nFind it at whop.com/hub → LibreMuse.\nOne key works on one machine."
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
				setStatus("Activated. Welcome to LibreMuse!", Color3.fromRGB(140, 255, 170))
			else
				ovStatus.TextColor3 = Color3.fromRGB(255, 150, 150)
				ovStatus.Text = msg or "Invalid license key."
			end
		end)
	end)

	licenseOverlay = ov
end

-- ============ Single-generate mode ============

local busy = false

local function onGenerate()
	if busy then
		return
	end
	local prompt = promptBox.Text:gsub("^%s+", ""):gsub("%s+$", "")
	if prompt == "" then
		setStatus("Type a prompt first.", Color3.fromRGB(255, 180, 80))
		return
	end
	busy = true
	generateBtn.Text = "Working..."
	generateBtn.AutoButtonColor = false

	task.spawn(function()
		local context = buildContext()
		setStatus("Sending to opencode" .. (context ~= "" and " (with Studio context)" or "") .. "...")
		local jobId, err = startJob("/chat", { prompt = context .. prompt, system = SYSTEM_PROMPT })
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
				setOutput((r.text ~= "" and r.text) or "-- (empty response) --")
				setStatus("Done. Review the code, then insert it.", Color3.fromRGB(140, 255, 170))
			end
		end
		busy = false
		generateBtn.Text = "Generate Code"
		generateBtn.AutoButtonColor = true
	end)
end

generateBtn.MouseButton1Click:Connect(onGenerate)

-- ============ Multi-step game builder ============

local buildState = "idle" -- idle | planned | building
local buildSteps = {}
local planPrompt = "" -- description the current plan was made from
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
			-- User edited the description after planning: drop the old plan, make a new one.
			buildState = "idle"
			buildSteps = {}
		else
			runBuild()
			return
		end
	end
	-- idle -> request a plan
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

-- ============ Insert actions (single mode) ============

local function insertAs(className, parentServiceName)
	local code, hadFence = extractCode(outputLabel.Text)
	if code == "" or code:find("^%-%- output appears here") then
		setStatus("Generate code first.", Color3.fromRGB(255, 180, 80))
		return
	end
	local inst = Instance.new(className)
	inst.Name = "LibreMuseGenerated"
	local ok, err = pcall(function()
		inst.Source = code
	end)
	if not ok then
		setStatus("Couldn't set source: " .. tostring(err):sub(1, 120), Color3.fromRGB(255, 120, 120))
		inst:Destroy()
		return
	end
	inst.Parent = game:GetService(parentServiceName)
	Selection:Set({ inst })
	setStatus("Inserted " .. className .. " into " .. parentServiceName .. "."
		.. (hadFence and "" or " (No code block in reply — used the full response text.)"),
		hadFence and Color3.fromRGB(140, 255, 170) or Color3.fromRGB(255, 180, 80))
end

insertScriptBtn.MouseButton1Click:Connect(function()
	insertAs("Script", "ServerScriptService")
end)

insertModuleBtn.MouseButton1Click:Connect(function()
	insertAs("ModuleScript", "ServerStorage")
end)

replaceBtn.MouseButton1Click:Connect(function()
	local code, hadFence = extractCode(outputLabel.Text)
	if code == "" or code:find("^%-%- output appears here") then
		setStatus("Generate code first.", Color3.fromRGB(255, 180, 80))
		return
	end
	local sel = Selection:Get()
	local target = sel[1]
	if not target or not target:IsA("LuaSourceContainer") then
		setStatus("Select a script in the Explorer first.", Color3.fromRGB(255, 180, 80))
		return
	end
	local ok, err = pcall(function()
		target.Source = code
	end)
	if not ok then
		setStatus("Couldn't replace source: " .. tostring(err):sub(1, 120), Color3.fromRGB(255, 120, 120))
		return
	end
	setStatus("Replaced source of " .. target:GetFullName() .. "."
		.. (hadFence and "" or " (No code block in reply — used the full response text.)"),
		hadFence and Color3.fromRGB(140, 255, 170) or Color3.fromRGB(255, 180, 80))
end)

-- License gate: block the UI until a valid key is stored
licenseKey = getStoredLicense()
if licenseKey == "" then
	setStatus("Activation required — paste your license key.", Color3.fromRGB(255, 180, 80))
	showLicenseOverlay(false)
end

-- Ping the bridge once at startup so the user sees the status immediately
task.spawn(function()
	local data, err = bridgeRequest("GET", "/ping")
	if data and data.ok then
		setStatus("Ready. Bridge connected — type a prompt.")
	else
		setStatus("Bridge not running. Start bridge.py first.", Color3.fromRGB(255, 180, 80))
	end
end)

print("[LibreMuse] plugin loaded. Waiting for bridge at " .. BRIDGE_BASE)
