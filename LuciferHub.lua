--[[
	LUCIFER HUB
	LocalScript → StarterPlayer › StarterPlayerScripts

	Launcher squircle: tap to open/close the hub, drag to move it. RightShift also toggles it on PC.

	The search bar under the tabs finds any feature and jumps straight to it.

	VISUAL    ESP+ (names, distance, health bars, tracers, team colors, hide teammates, max distance),
	          object ESP (by name), x-ray, custom FOV, zoom unlock, res stretch (7 levels), crosshair,
	          fullbright, no fog, no blur/effects, custom time of day
	MOVE      TPwalk, fly, noclip, infinite jump, custom jump height, freecam, animation player
	          (on phones, UP / DN buttons show up while flying or in freecam)
	PLAYERS   live player list with search, TP, spectate (‹ › flips through players), follow
	WORLD     tap-to-TP, tap-to-hide parts (undo / restore), waypoints with TP or auto-walk
	EXPLORE   browse the game's instances, TP to parts and models
	LOG       chat + join/leave feed
	MISC      AFK mode (anti-AFK + 3D off + FPS cap + timer), anti-AFK, 3D rendering, stats overlay,
	          rejoin, server hop, auto-rejoin on kick, server info, reset character, unload
	SETTINGS  themes (incl. rainbow), keybinds (PC), configs (auto-saved)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")
local StatsService = game:GetService("Stats")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")
local TextChatService = game:GetService("TextChatService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Running it again swaps out the old hub instead of stacking a second one
if type(_G.LuciferHubUnload) == "function" then
	pcall(_G.LuciferHubUnload)
end

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------

local HUB_TITLE = "LUCIFER HUB"
local ICON_IMAGE = "rbxassetid://0" -- paste your launcher image asset ID here
local TOGGLE_KEY = Enum.KeyCode.RightShift

local SCARLET = Color3.fromRGB(230, 24, 60)
local SCARLET_DEEP = Color3.fromRGB(120, 6, 26)
local INK = Color3.fromRGB(20, 5, 9)
local INK_RAISED = Color3.fromRGB(40, 10, 17)
local CREAM = Color3.fromRGB(255, 236, 214)
local MUTED = Color3.fromRGB(196, 150, 150)
local ESP_DEFAULT = Color3.fromRGB(255, 0, 255)
local HEALTH_LOW = Color3.fromRGB(255, 60, 60)
local HEALTH_HIGH = Color3.fromRGB(60, 255, 120)
local FULLBRIGHT_AMBIENT = Color3.fromRGB(178, 178, 178)

local RETRO = Font.fromEnum(Enum.Font.Arcade)
local BODY = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local BODY_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)

local IS_TOUCH = UserInputService.TouchEnabled
local PANEL_W = 320
local PANEL_H = 420
local HEADER_H = 48
local ROW_H = IS_TOUCH and 40 or 34
local LAUNCHER_SIZE = 54

local STRETCH_LEVELS = { 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3 }
local TP_OFFSET = CFrame.new(0, 0, 3) -- land 3 studs behind a player
local ANTI_AFK_JUMP_INTERVAL = 20
local AFK_FPS_CAP = 15
local RENDER_BIND = "LuciferHubCamera"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local running = true
local connections = {}
local ui = {} -- toggle setters, so features can keep their switches in sync

local function track(connection)
	table.insert(connections, connection)
	return connection
end

local function new(className, props)
	local inst = Instance.new(className)
	local parent = props.Parent
	props.Parent = nil
	for key, value in props do
		inst[key] = value
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function corner(inst, radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius), Parent = inst })
end

local function stroke(inst, color, thickness)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = inst,
	})
end

-- Accent gradients follow the theme. ThemeShape nil = accent → deep, "loop" = accent → deep → accent
local function themedSequence(shape, accent, deep)
	if shape == "loop" then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, accent),
			ColorSequenceKeypoint.new(0.5, deep),
			ColorSequenceKeypoint.new(1, accent),
		})
	end
	return ColorSequence.new(accent, deep)
end

local function accentGradient(parent, shape, rotation)
	local gradient = new("UIGradient", {
		Color = themedSequence(shape, SCARLET, SCARLET_DEEP),
		Rotation = rotation or 0,
		Parent = parent,
	})
	if shape then
		gradient:SetAttribute("ThemeShape", shape)
	end
	return gradient
end

-- Shading and fade gradients aren't accent-colored, so theme repaints skip them
local function plainGradient(parent, props)
	props.Parent = parent
	local gradient = new("UIGradient", props)
	gradient:SetAttribute("NoTheme", true)
	return gradient
end

-- Honors Roblox's Reduce Motion setting where the client exposes it
local motion = { Reduced = false }
pcall(function()
	motion.Reduced = GuiService.ReducedMotionEnabled == true
end)

local TWEEN_FAST = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local function tween(inst, goal, info)
	TweenService:Create(inst, info or TWEEN_FAST, goal):Play()
end

local function getCamera()
	return Workspace.CurrentCamera
end

local function getHumanoid()
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local function getRoot()
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart")
end

local function setProp(inst, prop, value)
	if inst[prop] ~= value then
		inst[prop] = value
	end
end

local function formatTime(seconds)
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor((seconds % 3600) / 60), seconds % 60)
end

local function trim(text)
	return (string.gsub(text, "^%s*(.-)%s*$", "%1"))
end

-- Looks up an executor-only function (writefile, setclipboard, setfpscap…); nil in plain Roblox
local function executorFunction(name)
	local ok, fn = pcall(function()
		return getfenv(0)[name]
	end)
	if ok and type(fn) == "function" then
		return fn
	end
	return nil
end

local function getOtherPlayers()
	local list = {}
	for _, plr in Players:GetPlayers() do
		if plr ~= player then
			table.insert(list, plr)
		end
	end
	table.sort(list, function(a, b)
		return string.lower(a.DisplayName) < string.lower(b.DisplayName)
	end)
	return list
end

--------------------------------------------------------------------------------
-- Root GUI + toasts
--------------------------------------------------------------------------------

local gui = new("ScreenGui", {
	Name = "LuciferHub",
	ResetOnSpawn = false,
	IgnoreGuiInset = true,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	DisplayOrder = 100,
	Parent = playerGui,
})

local espFolder = new("Folder", { Name = "LuciferHubESP", Parent = playerGui })

local tracerLayer = new("Frame", {
	Name = "Tracers",
	BackgroundTransparency = 1,
	Size = UDim2.fromScale(1, 1),
	ZIndex = 0,
	Parent = gui,
})

local toastHolder = new("Frame", {
	Name = "Toasts",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -110),
	Size = UDim2.fromOffset(300, 0),
	BackgroundTransparency = 1,
	ZIndex = 70,
	Parent = gui,
})
new("UIListLayout", {
	VerticalAlignment = Enum.VerticalAlignment.Bottom,
	HorizontalAlignment = Enum.HorizontalAlignment.Center,
	Padding = UDim.new(0, 6),
	SortOrder = Enum.SortOrder.LayoutOrder,
	Parent = toastHolder,
})

local toastCount = 0
-- kind: "warn" for problems (amber edge); left out, it's worked out from the wording
local function notify(text, kind)
	toastCount += 1
	if not kind then
		local lower = string.lower(text)
		for _, word in { "fail", "couldn't", "isn't", "stuck", "nothing to" } do
			if string.find(lower, word, 1, true) then
				kind = "warn"
				break
			end
		end
	end

	-- keep at most four on screen
	local live = {}
	for _, child in toastHolder:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(live, child)
		end
	end
	if #live >= 4 then
		table.sort(live, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		live[1]:Destroy()
	end

	local toast = new("TextLabel", {
		AutomaticSize = Enum.AutomaticSize.XY,
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.04,
		FontFace = BODY,
		Text = text,
		TextSize = 13,
		TextColor3 = CREAM,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		LayoutOrder = toastCount,
		Parent = toastHolder,
	})
	new("UISizeConstraint", { MaxSize = Vector2.new(280, math.huge), Parent = toast })
	new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 12),
		Parent = toast,
	})
	corner(toast, 8)
	local toastStroke = stroke(toast, Color3.fromRGB(70, 20, 30), 1)
	local edge = new("Frame", {
		Position = UDim2.new(0, -10, 0, 0),
		Size = UDim2.new(0, 3, 1, 0),
		BackgroundColor3 = if kind == "warn" then Color3.fromRGB(255, 176, 60) else SCARLET,
		BorderSizePixel = 0,
		Parent = toast,
	})
	corner(edge, 2)
	local pop = new("UIScale", { Scale = if motion.Reduced then 1 else 0.88, Parent = toast })
	if not motion.Reduced then
		tween(pop, { Scale = 1 }, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
	end

	task.delay(2.6, function()
		if not toast.Parent then
			return
		end
		local fade = TweenInfo.new(0.3)
		tween(toast, { TextTransparency = 1, BackgroundTransparency = 1 }, fade)
		tween(toastStroke, { Transparency = 1 }, fade)
		tween(edge, { BackgroundTransparency = 1 }, fade)
		task.wait(0.32)
		toast:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- Dragging (mouse + touch, tap vs drag)
--------------------------------------------------------------------------------

local function clampToScreen(frame, sizeOverride)
	local view = getCamera().ViewportSize
	local size = sizeOverride or frame.AbsoluteSize
	local pos = frame.Position
	local x = math.clamp(pos.X.Offset, 4, math.max(4, view.X - size.X - 4))
	local y = math.clamp(pos.Y.Offset, 4, math.max(4, view.Y - size.Y - 4))
	frame.Position = UDim2.fromOffset(x, y)
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function makeDraggable(handle, target, onTap)
	local activeInput, startInputPos, startPos
	local moved = false

	track(handle.InputBegan:Connect(function(input)
		if isPress(input) then
			activeInput = input
			startInputPos = input.Position
			startPos = target.Position
			moved = false
		end
	end))

	track(UserInputService.InputChanged:Connect(function(input)
		if not activeInput then
			return
		end
		local mouseDrag = input.UserInputType == Enum.UserInputType.MouseMovement
			and activeInput.UserInputType == Enum.UserInputType.MouseButton1
		if input ~= activeInput and not mouseDrag then
			return
		end
		local delta = input.Position - startInputPos
		if not moved and delta.Magnitude < 8 then
			return
		end
		moved = true
		target.Position = UDim2.fromOffset(startPos.X.Offset + delta.X, startPos.Y.Offset + delta.Y)
		clampToScreen(target)
	end))

	track(UserInputService.InputEnded:Connect(function(input)
		if not activeInput then
			return
		end
		if input == activeInput or input.UserInputType == activeInput.UserInputType then
			activeInput = nil
			if not moved and onTap then
				onTap()
			end
		end
	end))
end

--------------------------------------------------------------------------------
-- Movement input (keyboard, thumbstick, gamepad)
--------------------------------------------------------------------------------

local controls
task.spawn(function()
	pcall(function()
		local playerScripts = player:WaitForChild("PlayerScripts", 10)
		local playerModule = playerScripts and playerScripts:WaitForChild("PlayerModule", 10)
		if playerModule then
			controls = require(playerModule):GetControls()
		end
	end)
end)

-- Camera-relative move vector: X = right, -Z = forward
local function getMoveVector()
	if controls then
		local ok, vector = pcall(controls.GetMoveVector, controls)
		if ok and vector then
			return vector
		end
	end
	local humanoid = getHumanoid()
	if humanoid and humanoid.MoveDirection.Magnitude > 0 then
		local relative = getCamera().CFrame:VectorToObjectSpace(humanoid.MoveDirection)
		return Vector3.new(relative.X, 0, relative.Z)
	end
	return Vector3.zero
end

local holdVertical = 0 -- set by the on-screen UP / DN buttons
local function verticalInput()
	local value = holdVertical
	if not UserInputService:GetFocusedTextBox() then
		if UserInputService:IsKeyDown(Enum.KeyCode.E) then
			value += 1
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
			value -= 1
		end
	end
	return math.clamp(value, -1, 1)
end

--------------------------------------------------------------------------------
-- HUD pieces (spectate bar, UP/DN buttons, crosshair, stats, AFK overlay)
--------------------------------------------------------------------------------

-- Spectate bar
local spectateBar = new("Frame", {
	Name = "SpectateBar",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -24),
	Size = UDim2.fromOffset(280, 52),
	BackgroundColor3 = INK,
	Visible = false,
	ZIndex = 25,
	Parent = gui,
})
corner(spectateBar, 14)
stroke(spectateBar, SCARLET, 2)

local function barButton(text, anchorX, xOffset)
	local button = new("TextButton", {
		AnchorPoint = Vector2.new(anchorX, 0.5),
		Position = UDim2.new(anchorX, xOffset, 0.5, 0),
		Size = UDim2.fromOffset(38, 38),
		BackgroundColor3 = SCARLET_DEEP,
		FontFace = RETRO,
		Text = text,
		TextSize = 20,
		TextColor3 = CREAM,
		Parent = spectateBar,
	})
	corner(button, 10)
	return button
end

local spectatePrev = barButton("<", 0, 7)
local spectateNext = barButton(">", 1, -51)
local spectateStop = barButton("X", 1, -7)
local spectateAvatar = new("ImageLabel", {
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 52, 0.5, 0),
	Size = UDim2.fromOffset(34, 34),
	BackgroundColor3 = INK_RAISED,
	Image = "",
	Parent = spectateBar,
})
corner(spectateAvatar, 17)
stroke(spectateAvatar, SCARLET, 1.5)
local spectateName = new("TextLabel", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(94, 0),
	Size = UDim2.new(1, -189, 1, 0),
	FontFace = BODY_BOLD,
	RichText = true,
	Text = "",
	TextSize = 13,
	TextColor3 = CREAM,
	TextXAlignment = Enum.TextXAlignment.Left,
	TextTruncate = Enum.TextTruncate.AtEnd,
	Parent = spectateBar,
})

-- UP / DN hold buttons for fly + freecam on touch screens
local holdButtons = new("Frame", {
	Name = "FlyButtons",
	AnchorPoint = Vector2.new(1, 0.5),
	Position = UDim2.new(1, -16, 0.42, 0),
	Size = UDim2.fromOffset(58, 126),
	BackgroundTransparency = 1,
	Visible = false,
	ZIndex = 20,
	Parent = gui,
})

local function holdButton(text, y, value)
	local button = new("TextButton", {
		Position = UDim2.fromOffset(0, y),
		Size = UDim2.fromOffset(58, 58),
		BackgroundColor3 = SCARLET_DEEP,
		BackgroundTransparency = 0.15,
		AutoButtonColor = false,
		FontFace = RETRO,
		Text = text,
		TextSize = 22,
		TextColor3 = CREAM,
		Parent = holdButtons,
	})
	corner(button, 18)
	stroke(button, SCARLET, 2)
	track(button.InputBegan:Connect(function(input)
		if isPress(input) then
			holdVertical = value
			button.BackgroundColor3 = SCARLET
		end
	end))
	track(button.InputEnded:Connect(function(input)
		if isPress(input) then
			if holdVertical == value then
				holdVertical = 0
			end
			button.BackgroundColor3 = SCARLET_DEEP
		end
	end))
end
holdButton("UP", 0, 1)
holdButton("DN", 68, -1)

-- Crosshair
local crosshair = new("Frame", {
	Name = "Crosshair",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(18, 18),
	BackgroundTransparency = 1,
	Visible = false,
	ZIndex = 5,
	Parent = gui,
})
for _, size in { UDim2.fromOffset(18, 2), UDim2.fromOffset(2, 18) } do
	local line = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = size,
		BackgroundColor3 = SCARLET,
		BorderSizePixel = 0,
		Parent = crosshair,
	})
	stroke(line, Color3.new(0, 0, 0), 1)
end

-- Stats overlay
local statsLabel = new("TextLabel", {
	Name = "Stats",
	Position = UDim2.fromOffset(math.max(8, getCamera().ViewportSize.X - 234), 12),
	Size = UDim2.fromOffset(220, 28),
	BackgroundColor3 = INK,
	BackgroundTransparency = 0.12,
	FontFace = BODY_BOLD,
	RichText = true,
	Text = "",
	TextSize = 12,
	TextColor3 = CREAM,
	Visible = false,
	ZIndex = 22,
	Parent = gui,
})
corner(statsLabel, 9)
stroke(statsLabel, SCARLET, 1.5)
makeDraggable(statsLabel, statsLabel)

-- AFK overlay
local afkOverlay = new("Frame", {
	Name = "AFKOverlay",
	BackgroundColor3 = Color3.fromRGB(8, 2, 4),
	Size = UDim2.fromScale(1, 1),
	Visible = false,
	ZIndex = 60,
	Parent = gui,
})
do
	local afkTitle = new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromOffset(320, 44),
		BackgroundTransparency = 1,
		FontFace = RETRO,
		Text = "AFK MODE",
		TextSize = 40,
		TextColor3 = SCARLET,
		Parent = afkOverlay,
	})
	-- slow breathing so a glance tells you the hub is still running
	if not motion.Reduced then
		TweenService:Create(
			afkTitle,
			TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ TextTransparency = 0.45 }
		):Play()
	end
end
local afkTimer = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.48),
	Size = UDim2.fromOffset(320, 36),
	BackgroundTransparency = 1,
	FontFace = RETRO,
	Text = "00:00:00",
	TextSize = 32,
	TextColor3 = CREAM,
	Parent = afkOverlay,
})
local afkInfo = new("TextLabel", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.57),
	Size = UDim2.fromOffset(320, 20),
	BackgroundTransparency = 1,
	FontFace = BODY,
	Text = "Anti-AFK is on and 3D rendering is off",
	TextSize = 13,
	TextColor3 = MUTED,
	Parent = afkOverlay,
})
local afkExit = new("TextButton", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.7),
	Size = UDim2.fromOffset(210, 46),
	BackgroundColor3 = SCARLET_DEEP,
	FontFace = RETRO,
	Text = "EXIT AFK MODE",
	TextSize = 18,
	TextColor3 = CREAM,
	Parent = afkOverlay,
})
corner(afkExit, 14)
stroke(afkExit, SCARLET, 2)

--------------------------------------------------------------------------------
-- Feature state
--------------------------------------------------------------------------------

local esp = {
	Enabled = false,
	Names = true,
	Distance = true,
	Health = true,
	Tracers = false,
	TeamColors = true,
	HideTeam = false,
	MaxDistance = 1500,
	Color = ESP_DEFAULT,
}

local visual = {
	CustomFov = false,
	Fov = 70,
	Stretch = 0,
	Fullbright = false,
	NoFog = false,
	NoEffects = false,
	ZoomUnlock = false,
	CustomTime = false,
	Time = 14,
}

local move = {
	TPWalk = false,
	TPSpeed = 50,
	Fly = false,
	FlySpeed = 60,
	Noclip = false,
	InfJump = false,
	CustomJump = false,
	JumpHeight = 30,
	Freecam = false,
	FreecamSpeed = 40,
}

local world = {
	TapTP = false,
	TapHide = false,
	AutoRejoin = false,
}

local afk = {
	Mode = false,
	AntiAFK = false,
	Render = true,
	Capped = false,
	StartedAt = 0,
}

local stats = {
	Enabled = false,
	Frames = 0,
}

local function updateHoldButtons()
	holdButtons.Visible = IS_TOUCH and (move.Fly or move.Freecam)
	if not holdButtons.Visible then
		holdVertical = 0
	end
end

--------------------------------------------------------------------------------
-- ESP+
--------------------------------------------------------------------------------

local espEntries = {}

local function clearEspVisuals(entry)
	if entry.highlight then
		entry.highlight:Destroy()
		entry.highlight = nil
	end
	if entry.billboard then
		entry.billboard:Destroy()
		entry.billboard = nil
	end
end

local function buildEspVisuals(plr, entry)
	local character = plr.Character
	if not character then
		return
	end
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not root or plr.Character ~= character or espEntries[plr] ~= entry or not running then
		return
	end
	clearEspVisuals(entry)

	entry.highlight = new("Highlight", {
		Name = "LuciferESP",
		Adornee = character,
		DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
		FillColor = esp.Color,
		FillTransparency = 0.72,
		OutlineColor = esp.Color,
		OutlineTransparency = 0,
		Enabled = false,
		Parent = character,
	})

	local billboard = new("BillboardGui", {
		Name = plr.Name,
		Adornee = root,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(156, 44),
		StudsOffset = Vector3.new(0, 3.6, 0),
		Enabled = false,
		Parent = espFolder,
	})
	entry.billboard = billboard

	-- Tag: a dark pill like the hub's rows, outlined in the player's ESP color
	local tag = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.18,
		Parent = billboard,
	})
	corner(tag, 10)
	entry.tag = tag
	entry.tagStroke = stroke(tag, esp.Color, 1.5)

	local avatar = new("ImageLabel", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 7, 0.5, -2),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = INK_RAISED,
		Image = "rbxthumb://type=AvatarHeadShot&id=" .. plr.UserId .. "&w=48&h=48",
		Parent = tag,
	})
	corner(avatar, 13)

	entry.nameLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(40, 5),
		Size = UDim2.new(1, -46, 0, 16),
		FontFace = BODY_BOLD,
		Text = plr.DisplayName,
		TextSize = 13,
		TextColor3 = CREAM,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = tag,
	})
	entry.infoLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(40, 21),
		Size = UDim2.new(1, -46, 0, 13),
		FontFace = BODY,
		Text = "",
		TextSize = 11,
		TextColor3 = MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = tag,
	})
	entry.healthBack = new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 8, 1, -5),
		Size = UDim2.new(1, -16, 0, 3),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Parent = tag,
	})
	corner(entry.healthBack, 2)
	entry.healthFill = new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = HEALTH_HIGH,
		BorderSizePixel = 0,
		Parent = entry.healthBack,
	})
	corner(entry.healthFill, 2)
end

local function trackPlayer(plr)
	if plr == player or espEntries[plr] then
		return
	end
	local entry = {}
	espEntries[plr] = entry
	entry.tracer = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 2),
		Visible = false,
		Parent = tracerLayer,
	})
	entry.characterConnection = plr.CharacterAdded:Connect(function()
		task.spawn(buildEspVisuals, plr, entry)
	end)
	if plr.Character then
		task.spawn(buildEspVisuals, plr, entry)
	end
end

local function untrackPlayer(plr)
	local entry = espEntries[plr]
	if not entry then
		return
	end
	espEntries[plr] = nil
	entry.characterConnection:Disconnect()
	clearEspVisuals(entry)
	entry.tracer:Destroy()
end

local function updateEsp()
	local camera = getCamera()
	local myRoot = getRoot()
	local origin = if myRoot then myRoot.Position else camera.CFrame.Position
	local view = camera.ViewportSize
	local tracerFrom = Vector2.new(view.X / 2, view.Y - 6)

	for plr, entry in espEntries do
		local character = plr.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local show = esp.Enabled and entry.billboard ~= nil and root ~= nil and humanoid ~= nil and humanoid.Health > 0
		local distance = 0

		if show then
			distance = (root.Position - origin).Magnitude
			if distance > esp.MaxDistance then
				show = false
			elseif esp.HideTeam and plr.Team ~= nil and plr.Team == player.Team then
				show = false
			end
		end

		if entry.highlight then
			entry.highlight.Enabled = show
		end
		if entry.billboard then
			entry.billboard.Enabled = show
		end
		if not show then
			entry.tracer.Visible = false
			continue
		end

		local color = if esp.TeamColors and plr.Team then plr.TeamColor.Color else esp.Color
		setProp(entry.highlight, "FillColor", color)
		setProp(entry.highlight, "OutlineColor", color)
		setProp(entry.tagStroke, "Color", color)

		local showName, showDistance = esp.Names, esp.Distance
		entry.tag.Visible = showName or showDistance or esp.Health
		entry.nameLabel.Visible = showName
		entry.infoLabel.Visible = showDistance
		-- with only one line of text, center it beside the avatar
		setProp(entry.nameLabel, "Position", UDim2.fromOffset(40, if showDistance then 5 else 12))
		setProp(entry.infoLabel, "Position", UDim2.fromOffset(40, if showName then 21 else 13))
		entry.infoLabel.Text = string.format("%d studs", math.floor(distance))

		entry.healthBack.Visible = esp.Health
		local health = math.clamp(humanoid.Health / math.max(humanoid.MaxHealth, 1), 0, 1)
		entry.healthFill.Size = UDim2.fromScale(health, 1)
		entry.healthFill.BackgroundColor3 = HEALTH_LOW:Lerp(HEALTH_HIGH, health)

		if esp.Tracers then
			local screenPos, onScreen = camera:WorldToViewportPoint(root.Position)
			if onScreen then
				local to = Vector2.new(screenPos.X, screenPos.Y)
				local delta = to - tracerFrom
				entry.tracer.Position = UDim2.fromOffset((tracerFrom.X + to.X) / 2, (tracerFrom.Y + to.Y) / 2)
				entry.tracer.Size = UDim2.fromOffset(delta.Magnitude, 2)
				entry.tracer.Rotation = math.deg(math.atan2(delta.Y, delta.X))
				entry.tracer.BackgroundColor3 = color
				entry.tracer.Visible = true
			else
				entry.tracer.Visible = false
			end
		else
			entry.tracer.Visible = false
		end
	end
end

--------------------------------------------------------------------------------
-- Visual: FOV + lighting
--------------------------------------------------------------------------------

local originalFov
local function setCustomFov(on)
	visual.CustomFov = on
	local camera = getCamera()
	if on then
		originalFov = originalFov or camera.FieldOfView
		camera.FieldOfView = visual.Fov
	elseif originalFov then
		camera.FieldOfView = originalFov
		originalFov = nil
	end
end

local lightingBackup
local fogBackup
local atmosphereBackup = {}
local effectsBackup = {}

local function enforceLighting()
	if visual.Fullbright then
		setProp(Lighting, "Brightness", 2)
		setProp(Lighting, "ClockTime", 14)
		setProp(Lighting, "GlobalShadows", false)
		setProp(Lighting, "Ambient", FULLBRIGHT_AMBIENT)
		setProp(Lighting, "OutdoorAmbient", FULLBRIGHT_AMBIENT)
	end
	if visual.CustomTime then
		setProp(Lighting, "ClockTime", visual.Time)
	end
	if visual.NoFog then
		setProp(Lighting, "FogStart", 100000)
		setProp(Lighting, "FogEnd", 100000)
		for _, child in Lighting:GetChildren() do
			if child:IsA("Atmosphere") then
				if not atmosphereBackup[child] then
					atmosphereBackup[child] = { Density = child.Density, Haze = child.Haze }
				end
				setProp(child, "Density", 0)
				setProp(child, "Haze", 0)
			end
		end
	end
	if visual.NoEffects then
		for _, container in { Lighting, getCamera() } do
			for _, child in container:GetChildren() do
				if child:IsA("PostEffect") and child.Enabled then
					effectsBackup[child] = true
					child.Enabled = false
				end
			end
		end
	end
end

local function setFullbright(on)
	visual.Fullbright = on
	if on then
		lightingBackup = lightingBackup
			or {
				Brightness = Lighting.Brightness,
				ClockTime = Lighting.ClockTime,
				GlobalShadows = Lighting.GlobalShadows,
				Ambient = Lighting.Ambient,
				OutdoorAmbient = Lighting.OutdoorAmbient,
			}
		enforceLighting()
	elseif lightingBackup then
		for prop, value in lightingBackup do
			Lighting[prop] = value
		end
		lightingBackup = nil
	end
end

local function setNoFog(on)
	visual.NoFog = on
	if on then
		fogBackup = fogBackup or { FogStart = Lighting.FogStart, FogEnd = Lighting.FogEnd }
		enforceLighting()
	else
		if fogBackup then
			Lighting.FogStart = fogBackup.FogStart
			Lighting.FogEnd = fogBackup.FogEnd
			fogBackup = nil
		end
		for atmosphere, saved in atmosphereBackup do
			if atmosphere.Parent then
				atmosphere.Density = saved.Density
				atmosphere.Haze = saved.Haze
			end
		end
		table.clear(atmosphereBackup)
	end
end

local function setNoEffects(on)
	visual.NoEffects = on
	if on then
		enforceLighting()
	else
		for effect in effectsBackup do
			if effect.Parent then
				effect.Enabled = true
			end
		end
		table.clear(effectsBackup)
	end
end

--------------------------------------------------------------------------------
-- Movement: fly, noclip, jump, freecam
--------------------------------------------------------------------------------

local flyParts = {}
local function clearFlyParts()
	for _, inst in flyParts do
		inst:Destroy()
	end
	table.clear(flyParts)
end

local function attachFly()
	clearFlyParts()
	local root, humanoid = getRoot(), getHumanoid()
	if not (root and humanoid) then
		return
	end
	local attachment = new("Attachment", { Name = "LuciferFly", Parent = root })
	flyParts.attachment = attachment
	flyParts.velocity = new("LinearVelocity", {
		Name = "LuciferFlyVelocity",
		Attachment0 = attachment,
		RelativeTo = Enum.ActuatorRelativeTo.World,
		VelocityConstraintMode = Enum.VelocityConstraintMode.Vector,
		MaxForce = math.huge,
		VectorVelocity = Vector3.zero,
		Parent = root,
	})
	flyParts.align = new("AlignOrientation", {
		Name = "LuciferFlyAlign",
		Attachment0 = attachment,
		Mode = Enum.OrientationAlignmentMode.OneAttachment,
		RigidityEnabled = true,
		CFrame = root.CFrame.Rotation,
		Parent = root,
	})
	humanoid.PlatformStand = true
end

local function setFly(on)
	move.Fly = on
	if on then
		attachFly()
	else
		clearFlyParts()
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.PlatformStand = false
		end
	end
	if ui.fly then
		ui.fly(on, true)
	end
	updateHoldButtons()
end

local noclipParts = {}
local function setNoclip(on)
	move.Noclip = on
	if not on then
		for part in noclipParts do
			if part.Parent then
				part.CanCollide = true
			end
		end
		table.clear(noclipParts)
	end
end

local jumpBackup
local function setCustomJump(on)
	move.CustomJump = on
	local humanoid = getHumanoid()
	if on then
		if humanoid and not jumpBackup then
			jumpBackup = {
				humanoid = humanoid,
				UseJumpPower = humanoid.UseJumpPower,
				JumpHeight = humanoid.JumpHeight,
				JumpPower = humanoid.JumpPower,
			}
		end
	elseif jumpBackup then
		local saved = jumpBackup.humanoid
		if saved and saved.Parent then
			saved.UseJumpPower = jumpBackup.UseJumpPower
			saved.JumpHeight = jumpBackup.JumpHeight
			saved.JumpPower = jumpBackup.JumpPower
		end
		jumpBackup = nil
	end
end

-- Spectate (declared before freecam because each one turns the other off)
local spectating
local setFreecam

local function stopSpectate()
	if not spectating then
		spectateBar.Visible = false
		return
	end
	spectating = nil
	spectateBar.Visible = false
	local humanoid = getHumanoid()
	if humanoid then
		getCamera().CameraSubject = humanoid
	end
end

local function spectate(plr)
	local humanoid = plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		notify(plr.DisplayName .. " isn't loaded on your side yet")
		return
	end
	if move.Freecam then
		setFreecam(false)
	end
	spectating = plr
	getCamera().CameraSubject = humanoid
	local safeName = string.gsub(plr.DisplayName, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })
	spectateName.Text = string.format('%s\n<font size="11" color="#C49696">@%s</font>', safeName, plr.Name)
	spectateAvatar.Image = "rbxthumb://type=AvatarHeadShot&id=" .. plr.UserId .. "&w=48&h=48"
	spectateBar.Visible = true
end

local function cycleSpectate(step)
	local list = getOtherPlayers()
	if #list == 0 then
		stopSpectate()
		return
	end
	local index = table.find(list, spectating)
	if not index then
		spectate(list[1])
		return
	end
	index = ((index - 1 + step) % #list) + 1
	spectate(list[index])
end

local function teleportTo(plr)
	local root = getRoot()
	local targetRoot = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		notify("Your character isn't loaded")
		return
	end
	if not targetRoot then
		notify(plr.DisplayName .. " isn't loaded on your side yet")
		return
	end
	root.CFrame = targetRoot.CFrame * TP_OFFSET
	notify("Teleported to " .. plr.DisplayName)
end

local freecam = {
	position = Vector3.zero,
	yaw = 0,
	pitch = 0,
	anchoredRoot = nil,
}

setFreecam = function(on)
	if move.Freecam ~= on then
		move.Freecam = on
		local camera = getCamera()
		if on then
			stopSpectate()
			local cf = camera.CFrame
			local look = cf.LookVector
			freecam.position = cf.Position
			freecam.yaw = math.atan2(-look.X, -look.Z)
			freecam.pitch = math.asin(math.clamp(look.Y, -1, 1))
			camera.CameraType = Enum.CameraType.Scriptable
			local root = getRoot()
			if root and not root.Anchored then
				root.Anchored = true
				freecam.anchoredRoot = root
			end
		else
			camera.CameraType = Enum.CameraType.Custom
			local humanoid = getHumanoid()
			if humanoid then
				camera.CameraSubject = humanoid
			end
			if freecam.anchoredRoot and freecam.anchoredRoot.Parent then
				freecam.anchoredRoot.Anchored = false
			end
			freecam.anchoredRoot = nil
		end
	end
	if ui.freecam then
		ui.freecam(on, true)
	end
	updateHoldButtons()
end

local function rotateFreecam(delta, sensitivity)
	freecam.yaw -= delta.X * sensitivity
	freecam.pitch = math.clamp(freecam.pitch - delta.Y * sensitivity, -1.45, 1.45)
end

--------------------------------------------------------------------------------
-- World: tap TP
--------------------------------------------------------------------------------

local function tapTeleport(screenPos)
	local root = getRoot()
	local character = player.Character
	if not (root and character) then
		return
	end
	local ray = getCamera():ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
	if hit then
		root.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3, 0)) * root.CFrame.Rotation
	end
end

--------------------------------------------------------------------------------
-- Misc: AFK, render, stats, server
--------------------------------------------------------------------------------

local function setFpsCap(fps)
	local capper = executorFunction("setfpscap")
	if not capper then
		return false
	end
	return (pcall(capper, fps))
end

local function applyRender()
	local enabled = afk.Render and not afk.Mode
	-- Roblox only lets executors (not normal scripts) switch 3D rendering off
	local ok = pcall(function()
		RunService:Set3dRenderingEnabled(enabled)
	end)
	if not ok and not enabled and not afk.RenderWarned then
		afk.RenderWarned = true
		notify("Turning off 3D rendering needs an executor. Roblox blocks it for normal scripts.", "warn")
	end
end

local function setAfkMode(on)
	afk.Mode = on
	afkOverlay.Visible = on
	if on then
		afk.StartedAt = os.time()
		afkTimer.Text = formatTime(0)
		afk.Capped = setFpsCap(AFK_FPS_CAP)
		afkInfo.Text = if afk.Capped
			then "Anti-AFK is on, 3D is off, FPS capped at " .. AFK_FPS_CAP
			else "Anti-AFK is on and 3D rendering is off"
	elseif afk.Capped then
		setFpsCap(0)
		afk.Capped = false
	end
	applyRender()
	if ui.afkMode then
		ui.afkMode(on, true)
	end
end

local function antiAfkActive()
	return afk.AntiAFK or afk.Mode
end

local function getPing()
	local ok, value = pcall(function()
		return StatsService.Network.ServerStatsItem["Data Ping"]:GetValue()
	end)
	if ok and type(value) == "number" then
		return value
	end
	local ok2, seconds = pcall(function()
		return player:GetNetworkPing()
	end)
	if ok2 and type(seconds) == "number" then
		return seconds * 1000
	end
	return 0
end

local function rejoin()
	notify("Rejoining…")
	local ok, err = pcall(function()
		if #Players:GetPlayers() <= 1 then
			TeleportService:Teleport(game.PlaceId, player)
		else
			TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
		end
	end)
	if not ok then
		notify("Rejoin failed: " .. tostring(err))
	end
end

local function serverHop()
	notify("Finding a new server…")
	task.spawn(function()
		local candidates = {}
		local url = string.format(
			"https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true",
			game.PlaceId
		)
		local ok, body = pcall(function()
			return game:HttpGet(url)
		end)
		if ok and type(body) == "string" then
			local decoded, data = pcall(HttpService.JSONDecode, HttpService, body)
			if decoded and type(data) == "table" and type(data.data) == "table" then
				for _, server in data.data do
					if server.id ~= game.JobId and (server.playing or 0) < (server.maxPlayers or 0) then
						table.insert(candidates, server.id)
					end
				end
			end
		end
		local tpOk, err = pcall(function()
			if #candidates > 0 then
				TeleportService:TeleportToPlaceInstance(game.PlaceId, candidates[math.random(#candidates)], player)
			else
				TeleportService:Teleport(game.PlaceId, player)
			end
		end)
		if not tpOk then
			notify("Server hop failed: " .. tostring(err))
		end
	end)
end

--------------------------------------------------------------------------------
-- Object ESP (highlights anything whose name matches your keywords)
--------------------------------------------------------------------------------

local objectEsp = { Enabled = false, Keywords = {}, MaxDistance = 1000 }
local OBJECT_COLOR = Color3.fromRGB(255, 200, 40)
local OBJECT_LIMIT = 60
local objectEntries = {}
local objectCount = 0

local function objectMatches(name)
	local lower = string.lower(name)
	for _, keyword in objectEsp.Keywords do
		if string.find(lower, keyword, 1, true) then
			return true
		end
	end
	return false
end

local function removeObject(inst)
	local entry = objectEntries[inst]
	if not entry then
		return
	end
	objectEntries[inst] = nil
	objectCount -= 1
	entry.box:Destroy()
	entry.billboard:Destroy()
end

local function clearObjects()
	for inst in objectEntries do
		removeObject(inst)
	end
end

local function addObject(inst)
	if objectEntries[inst] or objectCount >= OBJECT_LIMIT or #objectEsp.Keywords == 0 then
		return
	end
	if not (inst:IsA("BasePart") or inst:IsA("Model")) or inst:IsA("Terrain") then
		return
	end
	if not objectMatches(inst.Name) then
		return
	end
	local character = player.Character
	if character and (inst == character or inst:IsDescendantOf(character)) then
		return
	end
	-- a part inside a matching model is already covered by the model's box
	local parent = inst.Parent
	if inst:IsA("BasePart") and parent and parent:IsA("Model") and objectMatches(parent.Name) then
		return
	end

	local size, offset, anchorPart
	if inst:IsA("Model") then
		local ok, boxCFrame, extents = pcall(function()
			local cf, ext = inst:GetBoundingBox()
			return cf, ext
		end)
		anchorPart = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
		if not ok or not anchorPart then
			return
		end
		size = extents
		offset = inst:GetPivot():ToObjectSpace(boxCFrame)
	else
		size = inst.Size
		offset = CFrame.identity
		anchorPart = inst
	end

	local box = new("BoxHandleAdornment", {
		Name = "LuciferObjectESP",
		Adornee = inst,
		AlwaysOnTop = true,
		ZIndex = 5,
		Size = size + Vector3.new(0.1, 0.1, 0.1),
		CFrame = offset,
		Color3 = OBJECT_COLOR,
		Transparency = 0.6,
		Visible = false,
		Parent = espFolder,
	})
	local billboard = new("BillboardGui", {
		Adornee = anchorPart,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(220, 30),
		StudsOffset = Vector3.new(0, 2, 0),
		Enabled = false,
		Parent = espFolder,
	})
	-- a pill that hugs its text: the name in cream, the distance in muted
	local label = new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 24),
		BackgroundColor3 = INK,
		BackgroundTransparency = 0.18,
		FontFace = BODY_BOLD,
		RichText = true,
		Text = "",
		TextSize = 12,
		TextColor3 = CREAM,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = billboard,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = label })
	new("UISizeConstraint", { MaxSize = Vector2.new(220, 24), Parent = label })
	corner(label, 8)
	stroke(label, OBJECT_COLOR, 1.5)
	local safeName = string.gsub(inst.Name, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" })
	objectEntries[inst] = {
		box = box,
		billboard = billboard,
		label = label,
		part = anchorPart,
		name = safeName,
		lastDistance = -1,
	}
	objectCount += 1
end

local function rescanObjects()
	clearObjects()
	if not objectEsp.Enabled or #objectEsp.Keywords == 0 then
		return
	end
	for _, inst in Workspace:GetDescendants() do
		if objectCount >= OBJECT_LIMIT then
			break
		end
		addObject(inst)
	end
end

local function setObjectKeywords(text)
	local keywords = {}
	for word in string.gmatch(text, "[^,]+") do
		local keyword = string.lower(trim(word))
		if keyword ~= "" then
			table.insert(keywords, keyword)
		end
	end
	objectEsp.Keywords = keywords
	rescanObjects()
end

local function setObjectEsp(on)
	objectEsp.Enabled = on
	rescanObjects()
	if on and #objectEsp.Keywords == 0 then
		notify("Type what to look for in the Object names box")
	end
end

local function updateObjects()
	if objectCount == 0 then
		return
	end
	local root = getRoot()
	local origin = if root then root.Position else getCamera().CFrame.Position
	for inst, entry in objectEntries do
		if not inst.Parent or not entry.part.Parent then
			removeObject(inst)
			continue
		end
		local distance = (entry.part.Position - origin).Magnitude
		local show = objectEsp.Enabled and distance <= objectEsp.MaxDistance
		entry.box.Visible = show
		entry.billboard.Enabled = show
		local rounded = math.floor(distance)
		if show and rounded ~= entry.lastDistance then
			entry.lastDistance = rounded
			entry.label.Text = string.format('%s  <font color="#C49696">%d studs</font>', entry.name, rounded)
		end
	end
end

--------------------------------------------------------------------------------
-- X-ray + tap-to-hide
--------------------------------------------------------------------------------

local xray = { Enabled = false, Amount = 0.6 }
local xrayParts = {}
local hiddenParts = {}
local hiddenOrder = {}

local function xrayEligible(part)
	if not part:IsA("BasePart") or part:IsA("Terrain") or hiddenParts[part] then
		return false
	end
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return false
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return true
end

local function applyXrayTo(part)
	if xrayEligible(part) then
		xrayParts[part] = true
		part.LocalTransparencyModifier = xray.Amount
	end
end

local function setXray(on)
	xray.Enabled = on
	if on then
		for _, inst in Workspace:GetDescendants() do
			if inst:IsA("BasePart") then
				applyXrayTo(inst)
			end
		end
	else
		for part in xrayParts do
			if part.Parent and not hiddenParts[part] then
				part.LocalTransparencyModifier = 0
			end
		end
		table.clear(xrayParts)
	end
end

local function setXrayAmount(amount)
	xray.Amount = amount
	if not xray.Enabled then
		return
	end
	for part in xrayParts do
		if part.Parent and not hiddenParts[part] then
			part.LocalTransparencyModifier = amount
		end
	end
end

local function hidePart(part)
	if hiddenParts[part] then
		return
	end
	hiddenParts[part] = { CanCollide = part.CanCollide, CanQuery = part.CanQuery }
	table.insert(hiddenOrder, part)
	part.LocalTransparencyModifier = 1
	part.CanCollide = false
	part.CanQuery = false
end

local function unhidePart(part)
	local saved = hiddenParts[part]
	if not saved then
		return
	end
	hiddenParts[part] = nil
	if part.Parent then
		part.CanCollide = saved.CanCollide
		part.CanQuery = saved.CanQuery
		part.LocalTransparencyModifier = if xray.Enabled and xrayParts[part] then xray.Amount else 0
	end
end

local function undoHide()
	local part = table.remove(hiddenOrder)
	while part and not hiddenParts[part] do
		part = table.remove(hiddenOrder)
	end
	if part then
		unhidePart(part)
		notify("Brought back " .. part.Name)
	else
		notify("Nothing to undo")
	end
end

local function restoreHidden()
	local count = 0
	for part in hiddenParts do
		unhidePart(part)
		count += 1
	end
	table.clear(hiddenOrder)
	return count
end

local function tapRaycast(screenPos)
	local ray = getCamera():ScreenPointToRay(screenPos.X, screenPos.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if player.Character then { player.Character } else {}
	return Workspace:Raycast(ray.Origin, ray.Direction * 3000, params)
end

local function hidePartAt(screenPos)
	local hit = tapRaycast(screenPos)
	local part = hit and hit.Instance
	if part and part:IsA("BasePart") and not part:IsA("Terrain") then
		hidePart(part)
		notify("Hid " .. part.Name)
	end
end

--------------------------------------------------------------------------------
-- Camera extras: zoom unlock + time of day
--------------------------------------------------------------------------------

local zoomBackup
local function setZoomUnlock(on)
	visual.ZoomUnlock = on
	if on then
		zoomBackup = zoomBackup or { MaxZoom = player.CameraMaxZoomDistance, Mode = player.CameraMode }
	elseif zoomBackup then
		player.CameraMaxZoomDistance = zoomBackup.MaxZoom
		player.CameraMode = zoomBackup.Mode
		zoomBackup = nil
	end
end

local timeBackup
local function setCustomTime(on)
	visual.CustomTime = on
	if on then
		timeBackup = timeBackup or Lighting.ClockTime
		enforceLighting()
	elseif timeBackup then
		Lighting.ClockTime = timeBackup
		timeBackup = nil
	end
end

--------------------------------------------------------------------------------
-- Follow player + auto-walk
--------------------------------------------------------------------------------

local follow = { Target = nil, Distance = 4 }
local refreshPlayerList -- set up in the PLAYERS tab

local function setFollow(plr)
	follow.Target = plr
	if plr then
		notify("Following " .. plr.DisplayName)
	end
	if refreshPlayerList then
		refreshPlayerList()
	end
end

local walkToken = 0

local function stopWalking()
	walkToken += 1
	local humanoid, root = getHumanoid(), getRoot()
	if humanoid and root then
		humanoid:MoveTo(root.Position)
	end
end

local function walkTo(position, label)
	walkToken += 1
	local token = walkToken
	task.spawn(function()
		local humanoid, root = getHumanoid(), getRoot()
		if not (humanoid and root) then
			notify("Your character isn't loaded")
			return
		end
		local path = PathfindingService:CreatePath({ AgentCanJump = true, WaypointSpacing = 4 })
		local ok = pcall(function()
			path:ComputeAsync(root.Position, position)
		end)
		if not ok or path.Status ~= Enum.PathStatus.Success then
			notify("Couldn't find a walkable path. Try GO instead")
			return
		end
		notify("Walking to " .. label)
		for _, point in path:GetWaypoints() do
			if token ~= walkToken or not running then
				return
			end
			if point.Action == Enum.PathWaypointAction.Jump then
				humanoid.Jump = true
			end
			humanoid:MoveTo(point.Position)
			local reached = false
			local connection = humanoid.MoveToFinished:Connect(function()
				reached = true
			end)
			local started = os.clock()
			while not reached and token == walkToken and os.clock() - started < 4 do
				task.wait()
			end
			connection:Disconnect()
			if not reached and token == walkToken then
				notify("Got stuck on the way. Try GO instead")
				return
			end
		end
		if token == walkToken then
			notify("Made it to " .. label)
		end
	end)
end

--------------------------------------------------------------------------------
-- Animation player
--------------------------------------------------------------------------------

local animation = { Track = nil, Speed = 1, Loop = true }

local function stopAnimation()
	local current = animation.Track
	animation.Track = nil
	if current then
		pcall(function()
			current:Stop(0.2)
			current:Destroy()
		end)
	end
end

local function playAnimation(idText)
	local id = string.match(idText or "", "%d+")
	if not id then
		notify("Paste an animation ID first")
		return
	end
	local humanoid = getHumanoid()
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		notify("Your character isn't loaded")
		return
	end
	stopAnimation()
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. id
	local ok, loaded = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not loaded then
		notify("Couldn't load that animation")
		return
	end
	animation.Track = loaded
	loaded.Priority = Enum.AnimationPriority.Action4
	loaded.Looped = animation.Loop
	loaded:Play(0.2)
	loaded:AdjustSpeed(animation.Speed)
	notify("Playing animation " .. id)
end

--------------------------------------------------------------------------------
-- Chat + join/leave log
--------------------------------------------------------------------------------

local logState = { Chat = true, Joins = true, Toasts = false }
local LOG_LIMIT = 120
local logEntries = {}
local addLogEntry -- set up in the LOG tab

local function logEvent(kind, text)
	local entry = { time = os.date("%H:%M"), kind = kind, text = text }
	table.insert(logEntries, entry)
	if #logEntries > LOG_LIMIT then
		table.remove(logEntries, 1)
	end
	if addLogEntry then
		addLogEntry(entry)
	end
end

--------------------------------------------------------------------------------
-- Themes
--------------------------------------------------------------------------------

local THEMES = {
	{ name = "Scarlet", color = Color3.fromRGB(230, 24, 60) },
	{ name = "Violet", color = Color3.fromRGB(150, 70, 255) },
	{ name = "Ocean", color = Color3.fromRGB(30, 150, 255) },
	{ name = "Toxic", color = Color3.fromRGB(80, 220, 60) },
	{ name = "Gold", color = Color3.fromRGB(240, 170, 20) },
	{ name = "Rainbow", color = nil },
}
local theme = { Name = "Scarlet", Hue = 0 }

local function swapColor(inst, prop, oldAccent, oldDeep, newAccent, newDeep)
	local value = inst[prop]
	if value == oldAccent then
		inst[prop] = newAccent
	elseif value == oldDeep then
		inst[prop] = newDeep
	end
end

-- Repaints every accent-colored piece of the hub. Elements tagged NoTheme keep their colors.
local function recolor(newAccent)
	local newDeep = newAccent:Lerp(Color3.new(0, 0, 0), 0.5)
	local oldAccent, oldDeep = SCARLET, SCARLET_DEEP
	if newAccent == oldAccent then
		return
	end
	for _, inst in gui:GetDescendants() do
		local parent = inst.Parent
		if inst:GetAttribute("NoTheme") or (parent and parent:GetAttribute("NoTheme")) then
			continue
		end
		if inst:IsA("UIStroke") then
			swapColor(inst, "Color", oldAccent, oldDeep, newAccent, newDeep)
		elseif inst:IsA("UIGradient") then
			inst.Color = themedSequence(inst:GetAttribute("ThemeShape"), newAccent, newDeep)
		elseif inst:IsA("GuiObject") then
			swapColor(inst, "BackgroundColor3", oldAccent, oldDeep, newAccent, newDeep)
			if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
				swapColor(inst, "TextColor3", oldAccent, oldDeep, newAccent, newDeep)
			end
			if inst:IsA("ScrollingFrame") then
				swapColor(inst, "ScrollBarImageColor3", oldAccent, oldDeep, newAccent, newDeep)
			end
		end
	end
	SCARLET, SCARLET_DEEP = newAccent, newDeep
end

--------------------------------------------------------------------------------
-- Everything below runs in its own scope (Luau caps a scope at 200 locals)
--------------------------------------------------------------------------------

local function main()
	--------------------------------------------------------------------------------
	-- Launcher + hub panel
	--------------------------------------------------------------------------------

	local hasIcon = ICON_IMAGE ~= "" and ICON_IMAGE ~= "rbxassetid://0"
	local EDGE = Color3.fromRGB(70, 20, 30) -- quiet outline for rows and inputs
	local CHAR_SHADOW = Color3.fromRGB(46, 4, 12) -- the chunky retro drop shadow
	local POP_IN = TweenInfo.new(0.24, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local ringState = { Active = false } -- the ember rings turn while any feature is on

	-- A quick squeeze that answers a tap
	local function pressable(button, target)
		target = target or button
		local scale = target:FindFirstChildOfClass("UIScale") or new("UIScale", { Parent = target })
		button.Activated:Connect(function()
			if motion.Reduced then
				return
			end
			scale.Scale = 0.94
			tween(scale, { Scale = 1 }, POP_IN)
		end)
	end

	local launcher = new("ImageButton", {
		Name = "Launcher",
		AutoButtonColor = false,
		BackgroundColor3 = SCARLET_DEEP,
		Image = if hasIcon then ICON_IMAGE else "",
		ScaleType = Enum.ScaleType.Crop,
		Size = UDim2.fromOffset(LAUNCHER_SIZE, LAUNCHER_SIZE),
		Position = UDim2.fromOffset(12, 70),
		ZIndex = 30,
		Parent = gui,
	})
	corner(launcher, 18)
	local launcherRing = accentGradient(stroke(launcher, Color3.new(1, 1, 1), 2.5), "loop")
	new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		FontFace = RETRO,
		Text = "LH",
		TextSize = 24,
		TextColor3 = CREAM,
		TextStrokeColor3 = CHAR_SHADOW,
		TextStrokeTransparency = 0.3,
		Visible = not hasIcon,
		Parent = launcher,
	})
	-- how many features are switched on, readable with the hub closed
	local launcherBadge = new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -4, 0, 4),
		Size = UDim2.fromOffset(20, 20),
		BackgroundColor3 = CREAM,
		FontFace = BODY_BOLD,
		Text = "0",
		TextSize = 11,
		TextColor3 = INK,
		Visible = false,
		ZIndex = 2,
		Parent = launcher,
	})
	corner(launcherBadge, 10)
	stroke(launcherBadge, INK, 2)
	pressable(launcher)

	local holder = new("Frame", {
		Name = "Hub",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12 + LAUNCHER_SIZE + 12, 70),
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		ZIndex = 10,
		Parent = gui,
	})
	local hubScale = new("UIScale", { Parent = holder }) -- the "Hub size" setting

	-- body scales from its center when the hub opens and closes
	local body = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Parent = holder,
	})
	local popScale = new("UIScale", { Parent = body })

	local shadow = new("Frame", {
		BackgroundColor3 = CHAR_SHADOW,
		Position = UDim2.fromOffset(6, 6),
		Size = UDim2.fromScale(1, 1),
		Parent = body,
	})
	corner(shadow, 18)

	local panel = new("Frame", {
		Name = "Panel",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(1, 1),
		ClipsDescendants = true,
		Parent = body,
	})
	corner(panel, 18)
	plainGradient(panel, { Color = ColorSequence.new(Color3.fromRGB(34, 9, 15), INK), Rotation = 90 })
	local panelRing = accentGradient(stroke(panel, Color3.new(1, 1, 1), 2), "loop")

	local header = new("Frame", {
		Name = "Header",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, HEADER_H),
		Parent = panel,
	})
	corner(header, 18)
	accentGradient(header)
	-- squares off the header's bottom corners
	local headerFill = new("Frame", {
		BackgroundColor3 = Color3.new(1, 1, 1),
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -18),
		Size = UDim2.new(1, 0, 0, 18),
		Parent = header,
	})
	accentGradient(headerFill)

	local title = new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(1, -100, 0, 22),
		FontFace = RETRO,
		Text = HUB_TITLE,
		TextSize = 22,
		TextColor3 = CREAM,
		TextStrokeColor3 = CHAR_SHADOW,
		TextStrokeTransparency = 0.3,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
		Parent = header,
	})
	-- the game you're in, since configs and waypoints are saved per game
	local subtitle = new("TextLabel", {
		Name = "Game",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 28),
		Size = UDim2.new(1, -100, 0, 14),
		FontFace = BODY,
		Text = if game.PlaceId == 0 then "Studio test" else "Place " .. game.PlaceId,
		TextSize = 11,
		TextColor3 = CREAM,
		TextTransparency = 0.2,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 2,
		Parent = header,
	})
	task.spawn(function()
		if game.PlaceId == 0 then
			return
		end
		local ok, info = pcall(function()
			return game:GetService("MarketplaceService"):GetProductInfoAsync(game.PlaceId)
		end)
		if ok and type(info) == "table" and type(info.Name) == "string" and subtitle.Parent then
			subtitle.Text = info.Name
		end
	end)

	local function headerButton(text, xOffset)
		local button = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, xOffset, 0.5, 0),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = INK,
			BackgroundTransparency = 0.35,
			FontFace = RETRO,
			Text = text,
			TextSize = 18,
			TextColor3 = CREAM,
			ZIndex = 3,
			Parent = header,
		})
		corner(button, 8)
		pressable(button)
		return button
	end
	local closeButton = headerButton("X", -10)
	local minButton = headerButton("_", -46)

	local tabBar = new("ScrollingFrame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(8, HEADER_H + 8),
		Size = UDim2.new(1, -16, 0, 28),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.X,
		ScrollingDirection = Enum.ScrollingDirection.X,
		ScrollBarThickness = 0,
		Parent = panel,
	})
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 5),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = tabBar,
	})

	-- fades the right edge while more tabs are scrolled out of view
	local tabFade = new("Frame", {
		Name = "MoreTabs",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, HEADER_H + 8),
		Size = UDim2.fromOffset(36, 28),
		BackgroundColor3 = Color3.fromRGB(32, 9, 14),
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = panel,
	})
	plainGradient(tabFade, { Transparency = NumberSequence.new(1, 0) })
	local function updateTabFade()
		if tabBar.AbsoluteSize.Y < 1 then
			return
		end
		local scale = tabBar.AbsoluteSize.Y / 28
		local hidden = tabBar.AbsoluteCanvasSize.X - tabBar.AbsoluteWindowSize.X - tabBar.CanvasPosition.X * scale
		tabFade.Visible = hidden > 4
	end
	track(tabBar:GetPropertyChangedSignal("CanvasPosition"):Connect(updateTabFade))
	track(tabBar:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(updateTabFade))
	track(tabBar:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(updateTabFade))

	local searchBar = new("TextBox", {
		Name = "Search",
		Position = UDim2.fromOffset(8, HEADER_H + 42),
		Size = UDim2.new(1, -16, 0, 30),
		BackgroundColor3 = INK_RAISED,
		ClearTextOnFocus = false,
		FontFace = BODY,
		PlaceholderText = "Search features",
		PlaceholderColor3 = MUTED,
		Text = "",
		TextSize = 13,
		TextColor3 = CREAM,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = panel,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 34), Parent = searchBar })
	corner(searchBar, 8)
	local searchStroke = stroke(searchBar, EDGE, 1)
	local searchClear = new("TextButton", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(1, 6, 0.5, 0),
		Size = UDim2.fromOffset(22, 22),
		BackgroundColor3 = INK,
		FontFace = RETRO,
		Text = "X",
		TextSize = 14,
		TextColor3 = MUTED,
		Visible = false,
		Parent = searchBar,
	})
	corner(searchClear, 11)
	track(searchClear.Activated:Connect(function()
		searchBar.Text = ""
	end))
	track(searchBar.Focused:Connect(function()
		searchStroke.Color = SCARLET
	end))
	track(searchBar.FocusLost:Connect(function()
		searchStroke.Color = EDGE
	end))

	-- Status strip: what's on, and how the game is running
	local FOOTER_H = 26
	local footer = new("Frame", {
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, FOOTER_H),
		BackgroundTransparency = 1,
		Parent = panel,
	})
	new("Frame", {
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 0, 1),
		BackgroundColor3 = EDGE,
		BorderSizePixel = 0,
		Parent = footer,
	})
	local footerStatus = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(0.65, -14, 1, 0),
		FontFace = BODY_BOLD,
		RichText = true,
		Text = "Nothing switched on",
		TextSize = 11,
		TextColor3 = MUTED,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = footer,
	})
	local footerFps = new("TextLabel", {
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -14, 0, 0),
		Size = UDim2.new(0.35, -14, 1, 0),
		FontFace = BODY,
		Text = "",
		TextSize = 11,
		TextColor3 = MUTED,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = footer,
	})

	local pages = new("Frame", {
		Name = "Pages",
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		Position = UDim2.fromOffset(8, HEADER_H + 80),
		Size = UDim2.new(1, -12, 1, -(HEADER_H + 84 + FOOTER_H)),
		Parent = panel,
	})

	local searchPage = new("ScrollingFrame", {
		Name = "SearchResults",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = SCARLET,
		Visible = false,
		Parent = pages,
	})
	new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = searchPage })
	new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 8), Parent = searchPage })

	local collapsed = false
	local hubOpen = true

	local function applyPanelSize(animate)
		local view = getCamera().ViewportSize
		local scale = hubScale.Scale
		local height = if collapsed
			then HEADER_H
			else math.min(PANEL_H, math.max(HEADER_H + 160, (view.Y - 24) / scale))
		local size = UDim2.fromOffset(PANEL_W, height)
		if animate and not motion.Reduced then
			tween(holder, { Size = size }, TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out))
		else
			holder.Size = size
		end
		clampToScreen(holder, Vector2.new(PANEL_W + 6, height + 6) * scale)
	end

	local function setHubOpen(open)
		hubOpen = open
		if open then
			holder.Visible = true
			applyPanelSize()
			if not motion.Reduced then
				popScale.Scale = 0.92
				tween(popScale, { Scale = 1 }, POP_IN)
			end
		elseif motion.Reduced then
			holder.Visible = false
		else
			tween(popScale, { Scale = 0.92 }, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
			task.delay(0.1, function()
				if not hubOpen then
					holder.Visible = false
				end
			end)
		end
	end

	local function toggleHub()
		setHubOpen(not hubOpen)
	end

	makeDraggable(launcher, launcher, toggleHub)
	makeDraggable(title, holder)
	makeDraggable(subtitle, holder)

	track(minButton.Activated:Connect(function()
		collapsed = not collapsed
		minButton.Text = if collapsed then "+" else "_"
		applyPanelSize(true)
	end))
	track(closeButton.Activated:Connect(function()
		setHubOpen(false)
	end))

	--------------------------------------------------------------------------------
	-- Tabs + widgets
	--------------------------------------------------------------------------------

	local tabs = {}
	local tabCount = 0
	local layoutOrders = {}
	local pageTabs = {} -- [page] = tab name
	local currentTab = "VISUAL"

	-- Registries: saved settings, keybindable toggles, and the feature search index
	local settingsRegistry = {} -- ["TAB/Label"] = { get, set, default }
	local toggleRegistry = {} -- ["TAB/Label"] = { get, set, label }
	local searchIndex = {} -- { label, tabName, row }
	local NO_SAVE = {
		["MOVE/Freecam"] = true,
		["MISC/AFK mode"] = true,
		["MISC/3D rendering"] = true,
		["WORLD/Tap to teleport"] = true,
		["WORLD/Tap to hide parts"] = true,
	}
	local configDirty = false
	local loadingConfig = false

	local function markDirty()
		if not loadingConfig then
			configDirty = true
		end
	end

	local function registerWidget(parent, label, row, get, set, isToggle, default)
		local tabName = pageTabs[parent]
		if not tabName then
			return
		end
		local key = tabName .. "/" .. label
		table.insert(searchIndex, { label = label, tabName = tabName, row = row })
		if get and not NO_SAVE[key] then
			settingsRegistry[key] = { get = get, set = set, default = default }
		end
		if isToggle then
			toggleRegistry[key] = { get = get, set = set, label = label }
		end
	end

	local function nextOrder(parent)
		local order = (layoutOrders[parent] or 0) + 1
		layoutOrders[parent] = order
		return order
	end

	local PAGE_IN = TweenInfo.new(0.18, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

	local function selectTab(name)
		currentTab = name
		searchPage.Visible = false
		for tabName, tab in tabs do
			local active = tabName == name
			local opening = active and not tab.page.Visible
			tab.page.Visible = active
			-- accent colors are set directly, never tweened, so live theme changes always catch them
			tab.button.BackgroundColor3 = if active then SCARLET else INK_RAISED
			tab.button.TextColor3 = if active then CREAM else MUTED
			tab.dot.BackgroundColor3 = if active then CREAM else SCARLET
			if opening and not motion.Reduced then
				tab.page.Position = UDim2.fromOffset(0, 10)
				tween(tab.page, { Position = UDim2.fromOffset(0, 0) }, PAGE_IN)
			end
			if active and tab.button.AbsoluteSize.Y >= 1 then
				-- scroll the tab strip so the chosen tab is in view (skipped until it's laid out)
				local scale = tab.button.AbsoluteSize.Y / 28
				local left = (tab.button.AbsolutePosition.X - tabBar.AbsolutePosition.X) / scale + tabBar.CanvasPosition.X
				local right = left + tab.button.AbsoluteSize.X / scale
				local window = tabBar.AbsoluteWindowSize.X / scale
				if left < tabBar.CanvasPosition.X then
					tabBar.CanvasPosition = Vector2.new(math.max(0, left - 8), 0)
				elseif right > tabBar.CanvasPosition.X + window then
					tabBar.CanvasPosition = Vector2.new(right - window + 8, 0)
				end
			end
		end
	end

	local function addTab(name)
		tabCount += 1
		local button = new("TextButton", {
			AutoButtonColor = false,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, 28),
			BackgroundColor3 = INK_RAISED,
			FontFace = RETRO,
			Text = name,
			TextSize = 16,
			TextColor3 = MUTED,
			LayoutOrder = tabCount,
			Parent = tabBar,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 11), PaddingRight = UDim.new(0, 11), Parent = button })
		corner(button, 8)
		-- lights up while something on this tab is switched on
		local dot = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(1, 5, 0, 6),
			Size = UDim2.fromOffset(6, 6),
			BackgroundColor3 = SCARLET,
			Visible = false,
			Parent = button,
		})
		corner(dot, 3)

		local page = new("ScrollingFrame", {
			Name = name,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 3,
			ScrollBarImageColor3 = SCARLET,
			Visible = false,
			Parent = pages,
		})
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
		new("UIPadding", { PaddingTop = UDim.new(0, 2), PaddingBottom = UDim.new(0, 10), Parent = page })

		tabs[name] = { button = button, page = page, dot = dot }
		pageTabs[page] = name
		track(button.Activated:Connect(function()
			currentTab = name
			if searchBar.Text ~= "" then
				searchBar.Text = "" -- clearing the search reopens currentTab
			else
				selectTab(name)
			end
		end))
		return page
	end

	local function addSection(parent, text)
		return new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -6, 0, 28),
			FontFace = RETRO,
			Text = text,
			TextSize = 16,
			TextColor3 = SCARLET,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Bottom,
			LayoutOrder = nextOrder(parent),
			Parent = parent,
		})
	end

	local function addNote(parent, text)
		return new("TextLabel", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, -10, 0, 0),
			FontFace = BODY,
			Text = text,
			TextSize = 11,
			TextColor3 = MUTED,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = nextOrder(parent),
			Parent = parent,
		})
	end

	local function addRow(parent, height)
		local row = new("Frame", {
			BackgroundColor3 = INK_RAISED,
			Size = UDim2.new(1, -6, 0, height),
			LayoutOrder = nextOrder(parent),
			Parent = parent,
		})
		corner(row, 10)
		local rowStroke = stroke(row, EDGE, 1)
		rowStroke.Transparency = 0.35
		return row
	end

	local function rowLabel(row, text, widthOffset)
		return new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, 0),
			Size = UDim2.new(1, widthOffset, 1, 0),
			FontFace = BODY,
			Text = text,
			TextSize = 13,
			TextColor3 = CREAM,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})
	end

	local function focusGlow(box, boxStroke)
		track(box.Focused:Connect(function()
			boxStroke.Color = SCARLET
			boxStroke.Thickness = 1.5
		end))
		track(box.FocusLost:Connect(function()
			boxStroke.Color = EDGE
			boxStroke.Thickness = 1
		end))
	end

	local function addToggle(parent, text, default, callback)
		local row = addRow(parent, ROW_H)
		-- ember edge on the left marks rows that are switched on
		local onEdge = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.new(0, 3, 1, -16),
			BackgroundColor3 = SCARLET,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Parent = row,
		})
		corner(onEdge, 2)
		local label = rowLabel(row, text, -74)

		local switch = new("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Size = UDim2.fromOffset(44, 24),
			BackgroundColor3 = INK,
			Parent = row,
		})
		corner(switch, 12)
		local switchStroke = stroke(switch, MUTED, 1)
		local knob = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, 3, 0.5, 0),
			Size = UDim2.fromOffset(18, 18),
			BackgroundColor3 = MUTED,
			Parent = switch,
		})
		corner(knob, 9)

		local hit = new("TextButton", {
			BackgroundTransparency = 1,
			Text = "",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 3,
			Parent = row,
		})
		pressable(hit, row)

		local state = false
		local function set(value, silent)
			state = value
			switch.BackgroundColor3 = if value then SCARLET else INK
			switchStroke.Color = if value then SCARLET else MUTED
			onEdge.BackgroundColor3 = SCARLET
			label.FontFace = if value then BODY_BOLD else BODY
			tween(onEdge, { BackgroundTransparency = if value then 0 else 1 })
			tween(knob, {
				Position = if value then UDim2.new(1, -21, 0.5, 0) else UDim2.new(0, 3, 0.5, 0),
				BackgroundColor3 = if value then CREAM else MUTED,
			})
			if not silent then
				callback(value)
				markDirty()
			end
		end
		local function get()
			return state
		end

		track(hit.Activated:Connect(function()
			set(not state)
		end))
		if default then
			set(true, true)
		end
		registerWidget(parent, text, row, get, set, true, default == true)
		return set, get
	end

	local function addSlider(parent, text, min, max, default, step, format, callback)
		local row = addRow(parent, ROW_H + 20)
		new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, 6),
			Size = UDim2.new(1, -90, 0, 20),
			FontFace = BODY,
			Text = text,
			TextSize = 13,
			TextColor3 = CREAM,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})
		local valueLabel = new("TextLabel", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 6),
			Size = UDim2.fromOffset(64, 20),
			BackgroundColor3 = INK,
			FontFace = BODY_BOLD,
			Text = "",
			TextSize = 12,
			TextColor3 = SCARLET,
			Parent = row,
		})
		corner(valueLabel, 6)
		local bar = new("Frame", {
			BackgroundColor3 = INK,
			BorderSizePixel = 0,
			Position = UDim2.new(0, 14, 1, -19),
			Size = UDim2.new(1, -28, 0, 8),
			Parent = row,
		})
		corner(bar, 4)
		local fill = new("Frame", {
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Size = UDim2.fromScale(0, 1),
			Parent = bar,
		})
		corner(fill, 4)
		accentGradient(fill, nil, 180)
		local knob = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = CREAM,
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(18, 18),
			Parent = bar,
		})
		corner(knob, 9)
		stroke(knob, SCARLET, 2)
		local hit = new("TextButton", {
			BackgroundTransparency = 1,
			Text = "",
			Position = UDim2.fromOffset(0, 24),
			Size = UDim2.new(1, 0, 1, -24),
			ZIndex = 3,
			Parent = row,
		})

		local value = default
		local function round(v)
			return math.clamp(min + math.floor((v - min) / step + 0.5) * step, min, max)
		end
		local function set(v, silent)
			value = round(v)
			local alpha = (value - min) / (max - min)
			fill.Size = UDim2.fromScale(alpha, 1)
			knob.Position = UDim2.fromScale(alpha, 0.5)
			valueLabel.Text = format(value)
			if not silent then
				callback(value)
				markDirty()
			end
		end
		local function slideTo(x)
			local width = math.max(bar.AbsoluteSize.X, 1)
			local alpha = math.clamp((x - bar.AbsolutePosition.X) / width, 0, 1)
			local target = round(min + (max - min) * alpha)
			if target ~= value then
				set(target)
			end
		end

		local activeInput
		track(hit.InputBegan:Connect(function(input)
			if isPress(input) then
				activeInput = input
				if parent:IsA("ScrollingFrame") then
					parent.ScrollingEnabled = false
				end
				tween(knob, { Size = UDim2.fromOffset(22, 22) })
				slideTo(input.Position.X)
			end
		end))
		track(UserInputService.InputChanged:Connect(function(input)
			if not activeInput then
				return
			end
			local mouseDrag = input.UserInputType == Enum.UserInputType.MouseMovement
				and activeInput.UserInputType == Enum.UserInputType.MouseButton1
			if input == activeInput or mouseDrag then
				slideTo(input.Position.X)
			end
		end))
		track(UserInputService.InputEnded:Connect(function(input)
			if activeInput and (input == activeInput or input.UserInputType == activeInput.UserInputType) then
				activeInput = nil
				if parent:IsA("ScrollingFrame") then
					parent.ScrollingEnabled = true
				end
				tween(knob, { Size = UDim2.fromOffset(18, 18) })
			end
		end))

		set(default, true)
		registerWidget(parent, text, row, function()
			return value
		end, set, false, round(default))
		return set
	end

	local function addInput(parent, text, default, min, max, callback)
		local row = addRow(parent, ROW_H)
		rowLabel(row, text, -108)
		local box = new("TextBox", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(84, ROW_H - 12),
			BackgroundColor3 = INK,
			ClearTextOnFocus = false,
			FontFace = BODY_BOLD,
			PlaceholderText = tostring(default),
			PlaceholderColor3 = MUTED,
			Text = tostring(default),
			TextSize = 13,
			TextColor3 = CREAM,
			Parent = row,
		})
		corner(box, 6)
		focusGlow(box, stroke(box, EDGE, 1))
		local value = default
		local function set(v, silent)
			value = math.clamp(v, min, max)
			box.Text = tostring(value)
			if not silent then
				callback(value)
				markDirty()
			end
		end
		track(box.FocusLost:Connect(function()
			local number = tonumber(box.Text)
			if number then
				set(number)
			else
				box.Text = tostring(value)
			end
		end))
		registerWidget(parent, text, row, function()
			return value
		end, set, false, default)
		return box
	end

	local function addTextBox(parent, placeholder)
		local box = new("TextBox", {
			Size = UDim2.new(1, -6, 0, ROW_H),
			BackgroundColor3 = INK_RAISED,
			ClearTextOnFocus = false,
			FontFace = BODY,
			PlaceholderText = placeholder,
			PlaceholderColor3 = MUTED,
			Text = "",
			TextSize = 13,
			TextColor3 = CREAM,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			LayoutOrder = nextOrder(parent),
			Parent = parent,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12), Parent = box })
		corner(box, 10)
		focusGlow(box, stroke(box, EDGE, 1))
		return box
	end

	-- Arcade button: an accent face sitting on a darker lip, which it presses down into
	local function arcadeButton(parent, text, textSize, callback)
		local base = new("Frame", {
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.3,
			Size = UDim2.fromScale(1, 1),
			Parent = parent,
		})
		corner(base, 9)
		local face = new("Frame", {
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = UDim2.new(1, 0, 1, -3),
			Parent = base,
		})
		corner(face, 9)
		accentGradient(face, nil, 90)
		new("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			FontFace = RETRO,
			Text = text,
			TextSize = textSize,
			TextColor3 = CREAM,
			TextStrokeColor3 = Color3.new(0, 0, 0),
			TextStrokeTransparency = 0.65,
			Parent = face,
		})
		local hit = new("TextButton", {
			BackgroundTransparency = 1,
			Text = "",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = base,
		})
		track(hit.Activated:Connect(function()
			if not motion.Reduced then
				face.Position = UDim2.fromOffset(0, 3)
				tween(face, { Position = UDim2.fromOffset(0, 0) }, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out))
			end
			callback()
		end))
		return base, hit
	end

	local function addButton(parent, text, callback)
		local base, hit = arcadeButton(parent, text, 16, callback)
		base.Size = UDim2.new(1, -6, 0, ROW_H + 2)
		base.LayoutOrder = nextOrder(parent)
		registerWidget(parent, text, base)
		return hit
	end

	-- Several buttons sharing one row, split evenly
	local function addButtonRow(parent, buttons)
		local row = new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -6, 0, ROW_H + 2),
			LayoutOrder = nextOrder(parent),
			Parent = parent,
		})
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
			Parent = row,
		})
		local made = {}
		local gap = 6 * (#buttons - 1) / #buttons
		for index, spec in buttons do
			local base, hit = arcadeButton(row, spec[1], 15, spec[2])
			base.Size = UDim2.new(1 / #buttons, -gap, 1, 0)
			base.LayoutOrder = index
			registerWidget(parent, spec[1], row)
			made[index] = hit
		end
		return made
	end

	local function addList(parent)
		local list = new("Frame", {
			BackgroundTransparency = 1,
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, 0, 0, 0),
			LayoutOrder = nextOrder(parent),
			Parent = parent,
		})
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder, Parent = list })
		return list
	end

	local function clearList(list)
		for _, child in list:GetChildren() do
			if not child:IsA("UIComponent") then
				child:Destroy()
			end
		end
		layoutOrders[list] = 0
	end

	-- Small button that lives on the right side of a list row
	local function rowButton(row, text, width, xOffset, color, callback)
		local button = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, xOffset, 0.5, 0),
			Size = UDim2.fromOffset(width, ROW_H - 10),
			BackgroundColor3 = color,
			FontFace = RETRO,
			Text = text,
			TextSize = 14,
			TextColor3 = CREAM,
			ZIndex = 3,
			Parent = row,
		})
		corner(button, 7)
		if color == INK then
			stroke(button, EDGE, 1)
		end
		pressable(button)
		button.Activated:Connect(callback)
		return button
	end

	--------------------------------------------------------------------------------
	-- VISUAL tab
	--------------------------------------------------------------------------------

	local visualPage = addTab("VISUAL")

	addSection(visualPage, "ESP+")
	ui.esp = addToggle(visualPage, "Player ESP", false, function(on)
		esp.Enabled = on
	end)
	addToggle(visualPage, "Names", esp.Names, function(on)
		esp.Names = on
	end)
	addToggle(visualPage, "Distance", esp.Distance, function(on)
		esp.Distance = on
	end)
	addToggle(visualPage, "Health bars", esp.Health, function(on)
		esp.Health = on
	end)
	addToggle(visualPage, "Tracers", esp.Tracers, function(on)
		esp.Tracers = on
	end)
	addToggle(visualPage, "Team colors", esp.TeamColors, function(on)
		esp.TeamColors = on
	end)
	addToggle(visualPage, "Hide teammates", esp.HideTeam, function(on)
		esp.HideTeam = on
	end)
	addSlider(visualPage, "Max distance", 50, 5000, esp.MaxDistance, 50, function(v)
		return v .. " studs"
	end, function(v)
		esp.MaxDistance = v
	end)

	addSection(visualPage, "CAMERA")
	addToggle(visualPage, "Custom FOV", false, setCustomFov)
	addSlider(visualPage, "Field of view", 30, 120, 70, 1, function(v)
		return tostring(v)
	end, function(v)
		visual.Fov = v
	end)
	addSlider(visualPage, "Res stretch", 0, #STRETCH_LEVELS, 0, 1, function(v)
		return if v == 0 then "Off" else "Lv " .. v
	end, function(v)
		visual.Stretch = v
	end)
	addToggle(visualPage, "Crosshair", false, function(on)
		crosshair.Visible = on
	end)

	addSection(visualPage, "LIGHTING")
	ui.fullbright = addToggle(visualPage, "Fullbright", false, setFullbright)
	ui.noFog = addToggle(visualPage, "No fog", false, setNoFog)
	ui.noEffects = addToggle(visualPage, "No blur / effects", false, setNoEffects)
	addToggle(visualPage, "Custom time of day", false, setCustomTime)
	addSlider(visualPage, "Time of day", 0, 24, visual.Time, 0.5, function(v)
		local hours = math.floor(v)
		local minutes = math.floor((v - hours) * 60 + 0.5)
		return string.format("%02d:%02d", hours, minutes)
	end, function(v)
		visual.Time = v
	end)

	addSection(visualPage, "OBJECT ESP")
	addToggle(visualPage, "Object ESP", false, setObjectEsp)
	local objectKeywordBox = addTextBox(visualPage, "Object names, comma separated (key, chest)")
	track(objectKeywordBox.FocusLost:Connect(function()
		setObjectKeywords(objectKeywordBox.Text)
		markDirty()
		if objectEsp.Enabled then
			notify(string.format("Object ESP found %d match%s", objectCount, if objectCount == 1 then "" else "es"))
		end
	end))
	addSlider(visualPage, "Object range", 50, 5000, objectEsp.MaxDistance, 50, function(v)
		return v .. " studs"
	end, function(v)
		objectEsp.MaxDistance = v
	end)
	addNote(visualPage, "Matches part and model names, NPCs included. Shows up to 60 at once.")

	addSection(visualPage, "X-RAY")
	addToggle(visualPage, "X-ray", false, setXray)
	addSlider(visualPage, "See-through amount", 10, 95, 60, 5, function(v)
		return v .. "%"
	end, function(v)
		setXrayAmount(v / 100)
	end)

	addSection(visualPage, "CAMERA+")
	addToggle(visualPage, "Zoom unlock", false, setZoomUnlock)
	addNote(visualPage, "Removes the max zoom limit and the forced first-person lock.")

	--------------------------------------------------------------------------------
	-- MOVE tab
	--------------------------------------------------------------------------------

	local movePage = addTab("MOVE")

	addSection(movePage, "SPEED")
	addToggle(movePage, "TPwalk", false, function(on)
		move.TPWalk = on
	end)
	addInput(movePage, "TPwalk speed (0-1000)", move.TPSpeed, 0, 1000, function(v)
		move.TPSpeed = v
	end)

	addSection(movePage, "FLY")
	ui.fly = addToggle(movePage, "Fly", false, setFly)
	addSlider(movePage, "Fly speed", 10, 300, move.FlySpeed, 5, function(v)
		return tostring(v)
	end, function(v)
		move.FlySpeed = v
	end)
	addNote(movePage, "Aim the camera to climb or dive. Phone: hold UP / DN. PC: E up, Q down.")

	addSection(movePage, "BODY")
	addToggle(movePage, "Noclip", false, setNoclip)
	addToggle(movePage, "Infinite jump", false, function(on)
		move.InfJump = on
	end)
	addToggle(movePage, "Custom jump height", false, setCustomJump)
	addSlider(movePage, "Jump height", 5, 150, move.JumpHeight, 1, function(v)
		return tostring(v)
	end, function(v)
		move.JumpHeight = v
	end)

	addSection(movePage, "FREECAM")
	ui.freecam = addToggle(movePage, "Freecam", false, function(on)
		setFreecam(on)
	end)
	addSlider(movePage, "Freecam speed", 5, 200, move.FreecamSpeed, 5, function(v)
		return tostring(v)
	end, function(v)
		move.FreecamSpeed = v
	end)
	addNote(movePage, "Drag the screen to look around (right-click drag on PC). Your body stays put.")

	addSection(movePage, "ANIMATIONS")
	local animationBox = addTextBox(movePage, "Animation ID or link")
	addButtonRow(movePage, {
		{
			"PLAY",
			function()
				playAnimation(animationBox.Text)
			end,
		},
		{
			"STOP",
			function()
				stopAnimation()
			end,
		},
	})
	addToggle(movePage, "Loop animation", animation.Loop, function(on)
		animation.Loop = on
		if animation.Track then
			animation.Track.Looped = on
		end
	end)
	addSlider(movePage, "Animation speed", 0.1, 3, animation.Speed, 0.1, function(v)
		return string.format("%.1fx", v)
	end, function(v)
		animation.Speed = v
		if animation.Track then
			animation.Track:AdjustSpeed(v)
		end
	end)
	addNote(movePage, "R15 avatar animations work best. Some games only let their own animations play.")

	--------------------------------------------------------------------------------
	-- PLAYERS tab
	--------------------------------------------------------------------------------

	local playersPage = addTab("PLAYERS")
	local searchBox = addTextBox(playersPage, "Search players…")
	addSlider(playersPage, "Follow distance", 2, 20, follow.Distance, 1, function(v)
		return v .. " studs"
	end, function(v)
		follow.Distance = v
	end)
	local playerList = addList(playersPage)
	addNote(playersPage, "FOL sticks you behind a player. Far-away players might not be loaded yet in games with streaming on.")

	refreshPlayerList = function()
		clearList(playerList)
		local query = string.lower(searchBox.Text)
		local shown = 0
		for _, plr in getOtherPlayers() do
			local matches = query == ""
				or string.find(string.lower(plr.Name), query, 1, true) ~= nil
				or string.find(string.lower(plr.DisplayName), query, 1, true) ~= nil
			if matches then
				shown += 1
				local row = addRow(playerList, ROW_H + 8)
				local isFollowing = follow.Target == plr
				local avatar = new("ImageLabel", {
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.new(0, 8, 0.5, 0),
					Size = UDim2.fromOffset(32, 32),
					BackgroundColor3 = INK,
					Image = "rbxthumb://type=AvatarHeadShot&id=" .. plr.UserId .. "&w=48&h=48",
					Parent = row,
				})
				corner(avatar, 16)
				stroke(avatar, if isFollowing then SCARLET else EDGE, 1.5)
				new("TextLabel", {
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(48, 5),
					Size = UDim2.new(1, -204, 0.5, -3),
					FontFace = BODY_BOLD,
					Text = plr.DisplayName,
					TextSize = 13,
					TextColor3 = CREAM,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
				new("TextLabel", {
					BackgroundTransparency = 1,
					Position = UDim2.new(0, 48, 0.5, 0),
					Size = UDim2.new(1, -204, 0.5, -5),
					FontFace = BODY,
					Text = "@" .. plr.Name,
					TextSize = 11,
					TextColor3 = MUTED,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = row,
				})
				rowButton(row, "VIEW", 48, -6, INK, function()
					spectate(plr)
				end)
				rowButton(row, "TP", 34, -60, SCARLET_DEEP, function()
					teleportTo(plr)
				end)
				rowButton(row, if isFollowing then "STOP" else "FOL", 50, -100, if isFollowing then SCARLET else INK, function()
					setFollow(if follow.Target == plr then nil else plr)
				end)
			end
		end
		if shown == 0 then
			addNote(playerList, if query == "" then "Nobody else is here yet." else "No players match that.")
		end
	end

	track(searchBox:GetPropertyChangedSignal("Text"):Connect(refreshPlayerList))
	track(spectatePrev.Activated:Connect(function()
		cycleSpectate(-1)
	end))
	track(spectateNext.Activated:Connect(function()
		cycleSpectate(1)
	end))
	track(spectateStop.Activated:Connect(stopSpectate))

	--------------------------------------------------------------------------------
	-- WORLD tab
	--------------------------------------------------------------------------------

	local worldPage = addTab("WORLD")

	addSection(worldPage, "TAP TP")
	ui.tapTP = addToggle(worldPage, "Tap to teleport", false, function(on)
		world.TapTP = on
		if on then
			if world.TapHide then
				ui.tapHide(false)
			end
			notify("Tap anywhere in the world to teleport there")
		end
	end)
	addNote(worldPage, "Quick taps teleport you. Dragging the camera won't.")

	addSection(worldPage, "TAP TO HIDE")
	ui.tapHide = addToggle(worldPage, "Tap to hide parts", false, function(on)
		world.TapHide = on
		if on then
			if world.TapTP then
				ui.tapTP(false)
			end
			notify("Tap a part to hide it (only on your screen)")
		end
	end)
	addButtonRow(worldPage, {
		{ "UNDO LAST", undoHide },
		{
			"RESTORE ALL",
			function()
				local count = restoreHidden()
				notify(string.format("Restored %d part%s", count, if count == 1 then "" else "s"))
			end,
		},
	})
	addNote(worldPage, "Hidden parts turn invisible and you can walk through them. Only you see the change.")

	addSection(worldPage, "WAYPOINTS")
	local waypointName = addTextBox(worldPage, "Waypoint name (optional)")
	local waypoints = {}
	local waypointList

	local function refreshWaypoints()
		clearList(waypointList)
		if #waypoints == 0 then
			addNote(waypointList, "No waypoints saved yet.")
			return
		end
		for index, waypoint in waypoints do
			local row = addRow(waypointList, ROW_H)
			rowLabel(row, waypoint.name, -160)
			rowButton(row, "X", 30, -6, INK, function()
				table.remove(waypoints, index)
				refreshWaypoints()
				markDirty()
			end)
			rowButton(row, "WALK", 56, -42, INK, function()
				walkTo(waypoint.cframe.Position, waypoint.name)
			end)
			rowButton(row, "GO", 44, -104, SCARLET_DEEP, function()
				local root = getRoot()
				if root then
					root.CFrame = waypoint.cframe
					notify("Went to " .. waypoint.name)
				end
			end)
		end
	end

	addButton(worldPage, "SAVE CURRENT SPOT", function()
		local root = getRoot()
		if not root then
			notify("Your character isn't loaded")
			return
		end
		local name = trim(waypointName.Text)
		if name == "" then
			name = "Spot " .. (#waypoints + 1)
		end
		table.insert(waypoints, { name = name, cframe = root.CFrame })
		waypointName.Text = ""
		refreshWaypoints()
		markDirty()
		notify("Saved " .. name)
	end)
	addButton(worldPage, "STOP WALKING", function()
		stopWalking()
		notify("Stopped walking")
	end)
	waypointList = addList(worldPage)
	addNote(worldPage, "GO teleports. WALK pathfinds there on foot. Waypoints save per game.")
	refreshWaypoints()

	--------------------------------------------------------------------------------
	-- Touch helpers (used by the EXPLORE and TOUCH tabs)
	--------------------------------------------------------------------------------

	local fireTouch = executorFunction("firetouchinterest")
	local TOUCH_COLOR = Color3.fromRGB(255, 70, 70)

	-- Path copier: turns an instance into Luau you can paste into a script
	local LUAU_KEYWORDS = {}
	for _, word in string.split("and break do else elseif end false for function if in local nil not or repeat return then true until while", " ") do
		LUAU_KEYWORDS[word] = true
	end

	local function pathSegment(name)
		if string.match(name, "^[%a_][%w_]*$") and not LUAU_KEYWORDS[name] then
			return "." .. name
		end
		return string.format("[%q]", name) -- spaces, symbols, keywords: workspace.Map["Spawn Pad"]
	end

	local function luauPath(inst)
		if inst == game then
			return "game"
		end
		local chain = {}
		local current = inst
		while current and current ~= game do
			table.insert(chain, 1, current)
			current = current.Parent
		end
		if current ~= game then
			return nil -- not in the game tree anymore
		end
		local top = chain[1]
		local path
		if top == Workspace then
			path = "workspace"
		else
			local ok, service = pcall(function()
				return game:GetService(top.ClassName)
			end)
			path = if ok and service == top
				then string.format('game:GetService("%s")', top.ClassName)
				else "game" .. pathSegment(top.Name)
		end
		for index = 2, #chain do
			path ..= pathSegment(chain[index].Name)
		end
		return path
	end

	-- Fallback when there's no setclipboard: a small box you can select the path from
	local showCopyBox
	do
		local boxHeight = ROW_H + 12
		local popup = new("Frame", {
			Name = "CopyBox",
			Position = UDim2.fromOffset(math.max(8, (getCamera().ViewportSize.X - 300) / 2), 90),
			Size = UDim2.fromOffset(300, 40 + boxHeight + 26),
			BackgroundColor3 = INK,
			Visible = false,
			ZIndex = 65,
			Parent = gui,
		})
		corner(popup, 14)
		stroke(popup, SCARLET, 2)
		local popupTitle = new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(12, 8),
			Size = UDim2.new(1, -56, 0, 24),
			FontFace = RETRO,
			Text = "COPY THIS PATH",
			TextSize = 18,
			TextColor3 = CREAM,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = popup,
		})
		local close = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 8),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = INK_RAISED,
			FontFace = RETRO,
			Text = "X",
			TextSize = 16,
			TextColor3 = CREAM,
			Parent = popup,
		})
		corner(close, 8)
		local box = new("TextBox", {
			Position = UDim2.fromOffset(10, 40),
			Size = UDim2.new(1, -20, 0, boxHeight),
			BackgroundColor3 = INK_RAISED,
			ClearTextOnFocus = false,
			FontFace = BODY,
			Text = "",
			TextSize = 13,
			TextColor3 = CREAM,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = popup,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), Parent = box })
		corner(box, 8)
		stroke(box, SCARLET_DEEP, 1)
		new("TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, 12, 1, -24),
			Size = UDim2.new(1, -24, 0, 18),
			FontFace = BODY,
			Text = "Tap the box, then select all and copy.",
			TextSize = 11,
			TextColor3 = MUTED,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = popup,
		})
		makeDraggable(popupTitle, popup)
		track(close.Activated:Connect(function()
			popup.Visible = false
		end))
		track(box.Focused:Connect(function()
			-- selects the whole path so it's one tap from copied
			box.SelectionStart = 1
			box.CursorPosition = #box.Text + 1
		end))
		showCopyBox = function(text)
			box.Text = text
			popup.Visible = true
			clampToScreen(popup)
		end
	end

	local function copyPath(inst)
		local path = luauPath(inst)
		if not path then
			notify("That isn't in the game anymore")
			return
		end
		local clip = executorFunction("setclipboard") or executorFunction("toclipboard")
		if clip and pcall(clip, path) then
			notify("Copied " .. path)
		else
			showCopyBox(path)
		end
	end

	-- A part has a touch event when a script connected .Touched to it (it gets a TouchInterest)
	local function hasTouch(inst)
		return inst:IsA("BasePart") and inst:FindFirstChildWhichIsA("TouchTransmitter") ~= nil
	end

	-- Fires the part's touch event. With firetouchinterest you never move;
	-- without it you stand on the part for a moment and get put back.
	local function touchPart(part)
		local root = getRoot()
		if not root then
			notify("Your character isn't loaded")
			return false
		end
		if not part.Parent then
			return false
		end
		if fireTouch then
			local ok = pcall(function()
				fireTouch(root, part, 0)
				task.wait()
				fireTouch(root, part, 1)
			end)
			if ok then
				return true
			end
		end
		local back = root.CFrame
		root.CFrame = CFrame.new(part.Position) * back.Rotation
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait(0.12)
		if root.Parent then
			root.CFrame = back
			root.AssemblyLinearVelocity = Vector3.zero
		end
		return true
	end

	--------------------------------------------------------------------------------
	-- EXPLORE tab
	--------------------------------------------------------------------------------

	local explorePage = addTab("EXPLORE")
	local EXPLORE_LIMIT = 150
	local explorer = { Current = game }
	local refreshExplorer

	local function safeChildren(inst)
		local ok, children = pcall(function()
			return inst:GetChildren()
		end)
		return if ok then children else {}
	end

	local function instanceCFrame(inst)
		if inst:IsA("BasePart") then
			return inst.CFrame
		end
		if inst:IsA("Model") then
			local ok, pivot = pcall(function()
				return inst:GetPivot()
			end)
			if ok then
				return pivot
			end
		end
		return nil
	end

	local function exploreTeleport(inst)
		local cf = instanceCFrame(inst)
		local root = getRoot()
		if cf and root then
			root.CFrame = CFrame.new(cf.Position + Vector3.new(0, 4, 0))
			notify("Teleported to " .. inst.Name)
		end
	end

	local function classColor(inst)
		if inst:IsA("BasePart") then
			return Color3.fromRGB(255, 150, 60)
		elseif inst:IsA("Model") then
			return Color3.fromRGB(80, 170, 255)
		elseif inst:IsA("LuaSourceContainer") then
			return Color3.fromRGB(90, 220, 120)
		elseif inst:IsA("Folder") or inst:IsA("Configuration") then
			return Color3.fromRGB(240, 200, 70)
		elseif inst:IsA("GuiBase") then
			return Color3.fromRGB(240, 110, 200)
		elseif inst:IsA("ValueBase") then
			return Color3.fromRGB(170, 140, 255)
		elseif inst:IsA("Sound") then
			return Color3.fromRGB(80, 220, 220)
		end
		return MUTED
	end

	local explorePath = addNote(explorePage, "game")
	addButtonRow(explorePage, {
		{
			"UP",
			function()
				local parent = explorer.Current.Parent
				explorer.Current = if explorer.Current == game or not parent then game else parent
				refreshExplorer()
			end,
		},
		{
			"HOME",
			function()
				explorer.Current = game
				refreshExplorer()
			end,
		},
	})
	addButtonRow(explorePage, {
		{
			"TP HERE",
			function()
				if instanceCFrame(explorer.Current) then
					exploreTeleport(explorer.Current)
				else
					notify("Open a part or model to teleport to it")
				end
			end,
		},
		{
			"COPY PATH",
			function()
				copyPath(explorer.Current)
			end,
		},
	})
	local exploreList = addList(explorePage)

	refreshExplorer = function()
		clearList(exploreList)
		local current = explorer.Current
		if current ~= game and not current.Parent then
			current = game
			explorer.Current = game
		end
		if current == game then
			explorePath.Text = "game"
		else
			local ok, fullName = pcall(function()
				return current:GetFullName()
			end)
			explorePath.Text = "game." .. (if ok then fullName else current.Name) .. "  (" .. current.ClassName .. ")"
		end

		local children = safeChildren(current)
		table.sort(children, function(a, b)
			return string.lower(a.Name) < string.lower(b.Name)
		end)
		local shown = math.min(#children, EXPLORE_LIMIT)
		for index = 1, shown do
			local child = children[index]
			local row = addRow(exploreList, ROW_H + 6)
			local childCount = #safeChildren(child)
			local canTeleport = instanceCFrame(child) ~= nil
			local touchable = hasTouch(child)
			local labelWidth = if touchable then -140 elseif canTeleport then -80 else -36
			-- color-coded by kind of instance, so parts, models and scripts stand apart
			local kindDot = new("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 12, 0.5, 0),
				Size = UDim2.fromOffset(8, 8),
				BackgroundColor3 = if touchable then TOUCH_COLOR else classColor(child),
				Parent = row,
			})
			corner(kindDot, 4)
			new("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(28, 4),
				Size = UDim2.new(1, labelWidth, 0.5, -2),
				FontFace = BODY_BOLD,
				Text = child.Name,
				TextSize = 13,
				TextColor3 = CREAM,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			new("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 28, 0.5, 0),
				Size = UDim2.new(1, labelWidth, 0.5, -4),
				FontFace = BODY,
				Text = child.ClassName
					.. (if touchable then ", touch part" else "")
					.. (if childCount > 0 then "  (" .. childCount .. " inside)" else ""),
				TextSize = 11,
				TextColor3 = MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			local open = new("TextButton", {
				BackgroundTransparency = 1,
				Text = "",
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
				Parent = row,
			})
			open.Activated:Connect(function()
				explorer.Current = child
				refreshExplorer()
			end)
			if canTeleport then
				rowButton(row, "TP", 44, -6, SCARLET_DEEP, function()
					exploreTeleport(child)
				end)
			end
			if touchable then
				rowButton(row, "FIRE", 56, -56, SCARLET_DEEP, function()
					if touchPart(child) then
						notify("Touched " .. child.Name)
					end
				end)
			end
		end
		if #children == 0 then
			addNote(exploreList, "Nothing inside this one.")
		elseif #children > shown then
			addNote(exploreList, string.format("Showing the first %d of %d.", shown, #children))
		end
		explorePage.CanvasPosition = Vector2.zero
	end

	addNote(explorePage, "Tap a row to open it. COPY PATH copies what you have open as Luau. Red dots are touch parts, FIRE touches them. Some services are locked and show up empty.")
	refreshExplorer()

	--------------------------------------------------------------------------------
	-- TOUCH tab: finds every part with a touch event in this game
	--------------------------------------------------------------------------------

	do
		local touchPage = addTab("TOUCH")
		local TOUCH_LIMIT = 150
		local scan = {
			Done = false,
			Scanning = false,
			Firing = false,
			Explorer = false,
			Results = {}, -- { part, path }
			Set = {}, -- [part] = true
			Counts = {}, -- [ancestor] = touch parts inside it
			Current = Workspace,
		}
		local refreshTouch
		local scanStatus, filterBox -- created below, used by the scan and filter functions

		local function plural(n, word)
			return string.format("%d %s%s", n, word, if n == 1 then "" else "s")
		end

		local function pathOf(inst)
			local ok, full = pcall(function()
				return inst:GetFullName()
			end)
			local path = if ok then full else inst.Name
			return (string.gsub(path, "^Workspace%.", ""))
		end

		local function runScan()
			if scan.Scanning then
				return
			end
			scan.Scanning = true
			scanStatus.Text = "Scanning…"
			task.spawn(function()
				local started = os.clock()
				local results, set, counts = {}, {}, {}
				local character = player.Character
				for index, inst in Workspace:GetDescendants() do
					if inst:IsA("TouchTransmitter") then
						local part = inst.Parent
						local mine = character ~= nil and part ~= nil and part:IsDescendantOf(character)
						if part and part:IsA("BasePart") and not set[part] and not mine then
							set[part] = true
							table.insert(results, { part = part, path = pathOf(part) })
							local ancestor = part.Parent
							while ancestor do
								counts[ancestor] = (counts[ancestor] or 0) + 1
								if ancestor == Workspace then
									break
								end
								ancestor = ancestor.Parent
							end
						end
					end
					if index % 3000 == 0 then
						task.wait() -- spread big games over a few frames so nothing freezes
					end
				end
				if not running then
					return
				end
				table.sort(results, function(a, b)
					return string.lower(a.path) < string.lower(b.path)
				end)
				scan.Results, scan.Set, scan.Counts = results, set, counts
				scan.Done, scan.Scanning = true, false
				if scan.Current ~= Workspace and not counts[scan.Current] then
					scan.Current = Workspace
				end
				scanStatus.Text = string.format("Found %s in %.1fs", plural(#results, "touch part"), os.clock() - started)
				refreshTouch()
			end)
		end

		local function filtered()
			local query = string.lower(trim(filterBox.Text))
			local out = {}
			for _, result in scan.Results do
				local part = result.part
				local inView = if scan.Explorer
					then part:IsDescendantOf(scan.Current)
					else query == "" or string.find(string.lower(result.path), query, 1, true) ~= nil
				if part.Parent and inView then
					table.insert(out, result)
				end
			end
			return out
		end

		local function fireAll()
			if scan.Firing then
				notify("Already firing, hang on")
				return
			end
			if not scan.Done then
				notify("Tap SCAN first")
				return
			end
			local list = filtered()
			if #list == 0 then
				notify("Nothing to fire here")
				return
			end
			if not getRoot() then
				notify("Your character isn't loaded")
				return
			end
			scan.Firing = true
			task.spawn(function()
				local touched = 0
				for index, result in list do
					if not running or not getRoot() then
						break
					end
					if result.part.Parent and touchPart(result.part) then
						touched += 1
					end
					scanStatus.Text = string.format("Firing %d / %d", index, #list)
				end
				scan.Firing = false
				scanStatus.Text = "Touched " .. plural(touched, "part")
				notify("Touched " .. plural(touched, "part"))
			end)
		end

		addNote(
			touchPage,
			if fireTouch
				then "Uses firetouchinterest, so FIRE touches parts without moving you."
				else "No firetouchinterest here, so FIRE puts you on the part for a moment and brings you back."
		)
		scanStatus = addNote(touchPage, "Tap SCAN to find every part with a touch event in this game.")
		addButtonRow(touchPage, { { "SCAN", runScan }, { "FIRE ALL", fireAll } })
		addToggle(touchPage, "Explorer view", false, function(on)
			scan.Explorer = on
			refreshTouch()
		end)
		filterBox = addTextBox(touchPage, "Filter by name or path")
		local pathLabel = addNote(touchPage, "Workspace")
		local navHits = addButtonRow(touchPage, {
			{
				"UP",
				function()
					local parent = scan.Current.Parent
					if scan.Current ~= Workspace and parent then
						scan.Current = parent
					end
					refreshTouch()
				end,
			},
			{
				"HOME",
				function()
					scan.Current = Workspace
					refreshTouch()
				end,
			},
			{
				"COPY",
				function()
					copyPath(scan.Current)
				end,
			},
		})
		local navRow = navHits[1].Parent.Parent
		local touchList = addList(touchPage)
		addNote(touchPage, "FIRE ALL touches kill bricks too, so filter first in games that have them. In Explorer view it fires everything in the open folder.")

		local function addTouchRow(inst, subtitle, isTouch, onOpen)
			local row = addRow(touchList, ROW_H + 6)
			local labelWidth = if isTouch then -200 else -36
			local kindDot = new("Frame", {
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, 12, 0.5, 0),
				Size = UDim2.fromOffset(8, 8),
				BackgroundColor3 = if isTouch then TOUCH_COLOR else classColor(inst),
				Parent = row,
			})
			corner(kindDot, 4)
			new("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.fromOffset(28, 4),
				Size = UDim2.new(1, labelWidth, 0.5, -2),
				FontFace = BODY_BOLD,
				Text = inst.Name,
				TextSize = 13,
				TextColor3 = CREAM,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			new("TextLabel", {
				BackgroundTransparency = 1,
				Position = UDim2.new(0, 28, 0.5, 0),
				Size = UDim2.new(1, labelWidth, 0.5, -4),
				FontFace = BODY,
				Text = subtitle,
				TextSize = 11,
				TextColor3 = MUTED,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Parent = row,
			})
			if onOpen then
				local open = new("TextButton", {
					BackgroundTransparency = 1,
					Text = "",
					Size = UDim2.fromScale(1, 1),
					ZIndex = 2,
					Parent = row,
				})
				open.Activated:Connect(onOpen)
			end
			if isTouch then
				rowButton(row, "TP", 40, -6, INK, function()
					exploreTeleport(inst)
				end)
				rowButton(row, "FIRE", 56, -52, SCARLET_DEEP, function()
					if touchPart(inst) then
						notify("Touched " .. inst.Name)
					end
				end)
				rowButton(row, "COPY", 54, -114, INK, function()
					copyPath(inst)
				end)
			end
		end

		local function renderList()
			local list = filtered()
			local shown = math.min(#list, TOUCH_LIMIT)
			for index = 1, shown do
				local result = list[index]
				addTouchRow(result.part, result.path, true, nil)
			end
			if #scan.Results == 0 then
				addNote(touchList, "No touch parts found in this game.")
			elseif #list == 0 then
				addNote(touchList, "No touch parts match that filter.")
			elseif #list > shown then
				addNote(touchList, string.format("Showing the first %d of %d. Filter to narrow it down.", shown, #list))
			end
		end

		local function renderExplorer()
			local current = scan.Current
			if current ~= Workspace and not current.Parent then
				current = Workspace
				scan.Current = Workspace
			end
			pathLabel.Text = (if current == Workspace then "Workspace" else "Workspace." .. pathOf(current))
				.. "  ("
				.. plural(scan.Counts[current] or 0, "touch part")
				.. " inside)"

			local entries = {}
			for _, child in current:GetChildren() do
				local isTouch = scan.Set[child] == true
				local inside = scan.Counts[child] or 0
				if isTouch or inside > 0 then
					table.insert(entries, { inst = child, isTouch = isTouch, inside = inside })
				end
			end
			table.sort(entries, function(a, b)
				if (a.inside > 0) ~= (b.inside > 0) then
					return a.inside > 0 -- folders first
				end
				return string.lower(a.inst.Name) < string.lower(b.inst.Name)
			end)

			local shown = math.min(#entries, TOUCH_LIMIT)
			for index = 1, shown do
				local entry = entries[index]
				local child = entry.inst
				local subtitle = child.ClassName
					.. (if entry.isTouch then ", touch part" else "")
					.. (if entry.inside > 0 then "  (" .. plural(entry.inside, "touch part") .. " inside)" else "")
				local onOpen = if entry.inside > 0
					then function()
						scan.Current = child
						refreshTouch()
					end
					else nil
				addTouchRow(child, subtitle, entry.isTouch, onOpen)
			end
			if #entries == 0 then
				addNote(touchList, "No touch parts in here.")
			elseif #entries > shown then
				addNote(touchList, string.format("Showing the first %d of %d.", shown, #entries))
			end
		end

		refreshTouch = function()
			clearList(touchList)
			filterBox.Visible = not scan.Explorer
			pathLabel.Visible = scan.Explorer and scan.Done
			navRow.Visible = scan.Explorer and scan.Done
			if not scan.Done then
				addNote(touchList, "Nothing scanned yet.")
				return
			end
			if scan.Explorer then
				renderExplorer()
				touchPage.CanvasPosition = Vector2.zero
			else
				renderList()
			end
		end

		track(filterBox:GetPropertyChangedSignal("Text"):Connect(function()
			if scan.Done and not scan.Explorer then
				refreshTouch()
			end
		end))
		refreshTouch()
	end

	--------------------------------------------------------------------------------
	-- LOG tab
	--------------------------------------------------------------------------------

	local logPage = addTab("LOG")
	addToggle(logPage, "Log chat", logState.Chat, function(on)
		logState.Chat = on
	end)
	addToggle(logPage, "Log joins / leaves", logState.Joins, function(on)
		logState.Joins = on
	end)
	addToggle(logPage, "Join / leave toasts", logState.Toasts, function(on)
		logState.Toasts = on
	end)
	local logRows = {}
	local logOrder = 0
	addButton(logPage, "CLEAR LOG", function()
		for _, row in logRows do
			row:Destroy()
		end
		table.clear(logRows)
		table.clear(logEntries)
	end)
	local logList = addList(logPage)

	-- the left edge says what kind of entry it is; the text stays easy to read
	local LOG_COLORS = { chat = MUTED, join = HEALTH_HIGH, leave = HEALTH_LOW }
	addLogEntry = function(entry)
		logOrder -= 1 -- newest on top
		local label = new("TextLabel", {
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.new(1, -6, 0, 0),
			BackgroundColor3 = INK_RAISED,
			FontFace = BODY,
			RichText = false,
			Text = entry.time .. "   " .. entry.text,
			TextSize = 12,
			TextColor3 = CREAM,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = logOrder,
			Parent = logList,
		})
		new("UIPadding", {
			PaddingTop = UDim.new(0, 7),
			PaddingBottom = UDim.new(0, 7),
			PaddingLeft = UDim.new(0, 14),
			PaddingRight = UDim.new(0, 10),
			Parent = label,
		})
		corner(label, 8)
		local kindEdge = new("Frame", {
			Position = UDim2.fromOffset(-8, 0),
			Size = UDim2.new(0, 3, 1, 0),
			BackgroundColor3 = LOG_COLORS[entry.kind] or MUTED,
			BorderSizePixel = 0,
			Parent = label,
		})
		corner(kindEdge, 2)
		table.insert(logRows, label)
		if #logRows > LOG_LIMIT then
			table.remove(logRows, 1):Destroy()
		end
	end
	for _, entry in logEntries do
		addLogEntry(entry)
	end

	--------------------------------------------------------------------------------
	-- MISC tab
	--------------------------------------------------------------------------------

	local miscPage = addTab("MISC")

	addSection(miscPage, "AFK")
	ui.afkMode = addToggle(miscPage, "AFK mode", false, setAfkMode)
	addNote(miscPage, "Anti-AFK + 3D off + FPS cap (where supported) with a timer. Battery saver.")
	addToggle(miscPage, "Anti-AFK", false, function(on)
		afk.AntiAFK = on
	end)
	addToggle(miscPage, "3D rendering", true, function(on)
		afk.Render = on
		applyRender()
	end)

	addSection(miscPage, "HUD")
	addToggle(miscPage, "Stats overlay (FPS / ping)", false, function(on)
		stats.Enabled = on
		statsLabel.Visible = on
	end)

	addSection(miscPage, "SERVER")
	addButtonRow(miscPage, { { "REJOIN", rejoin }, { "SERVER HOP", serverHop } })
	local autoRejoinAvailable = true -- set for real once the kick-screen hookup is tried below
	ui.autoRejoin = addToggle(miscPage, "Auto-rejoin on kick", false, function(on)
		if on and not autoRejoinAvailable then
			world.AutoRejoin = false
			ui.autoRejoin(false, true)
			notify("Auto-rejoin needs an executor. Roblox doesn't let normal scripts see the kick screen.", "warn")
			return
		end
		world.AutoRejoin = on
	end)

	addSection(miscPage, "SERVER INFO")
	local serverInfoRow = addRow(miscPage, 64)
	local serverInfoLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 6),
		Size = UDim2.new(1, -20, 1, -12),
		FontFace = BODY,
		Text = "",
		TextSize = 12,
		TextColor3 = CREAM,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = serverInfoRow,
	})
	local jobIdText = if game.JobId ~= "" then game.JobId else "No job ID (Studio test)"
	local jobIdBox = addTextBox(miscPage, "Job ID")
	jobIdBox.Text = jobIdText
	jobIdBox.TextEditable = false
	jobIdBox.TextTruncate = Enum.TextTruncate.AtEnd
	addButton(miscPage, "COPY JOB ID", function()
		local copy = executorFunction("setclipboard")
		if copy and pcall(copy, game.JobId) then
			notify("Job ID copied")
		else
			notify("Tap the Job ID box, select it, and copy")
		end
	end)

	local function updateServerInfo()
		serverInfoLabel.Text = string.format(
			"Place ID: %d\nServer age: %s\nPlayers: %d / %d   •   Ping: %dms",
			game.PlaceId,
			formatTime(Workspace.DistributedGameTime),
			#Players:GetPlayers(),
			Players.MaxPlayers,
			math.floor(getPing() + 0.5)
		)
	end
	updateServerInfo()

	addSection(miscPage, "HUB")
	addButton(miscPage, "RESET CHARACTER", function()
		local humanoid = getHumanoid()
		if humanoid then
			humanoid.Health = 0
		end
	end)
	local unloadButton = addButton(miscPage, "UNLOAD HUB", function() end)
	addNote(miscPage, "RightShift shows/hides the hub on PC (change it in SETTINGS). Unload saves your config, turns everything off and removes the hub.")

	--------------------------------------------------------------------------------
	-- SETTINGS tab: themes, keybinds, configs
	--------------------------------------------------------------------------------

	local settingsPage = addTab("SETTINGS")

	-- Themes
	addSection(settingsPage, "THEME")
	local chipRow = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -6, 0, 38),
		LayoutOrder = nextOrder(settingsPage),
		Parent = settingsPage,
	})
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Parent = chipRow,
	})
	local themeLabel = addNote(settingsPage, "Theme: Scarlet")
	local chips = {}

	local function updateChips()
		for name, chipStroke in chips do
			chipStroke.Color = if name == theme.Name then CREAM else Color3.new(0, 0, 0)
			chipStroke.Thickness = if name == theme.Name then 3 else 1
		end
		themeLabel.Text = "Theme: " .. theme.Name
	end

	local function setTheme(name)
		local chosen
		for _, option in THEMES do
			if option.name == name then
				chosen = option
			end
		end
		if not chosen then
			return
		end
		theme.Name = name
		if chosen.color then
			recolor(chosen.color)
		end
		updateChips()
		markDirty()
	end

	for index, option in THEMES do
		local chip = new("TextButton", {
			Size = UDim2.fromOffset(34, 34),
			BackgroundColor3 = option.color or Color3.new(1, 1, 1),
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = index,
			Parent = chipRow,
		})
		chip:SetAttribute("NoTheme", true)
		corner(chip, 17)
		pressable(chip)
		if not option.color then
			new("UIGradient", {
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 60, 60)),
					ColorSequenceKeypoint.new(0.33, Color3.fromRGB(255, 220, 40)),
					ColorSequenceKeypoint.new(0.66, Color3.fromRGB(40, 200, 255)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 70, 255)),
				}),
				Parent = chip,
			})
		end
		chips[option.name] = stroke(chip, Color3.new(0, 0, 0), 1)
		track(chip.Activated:Connect(function()
			setTheme(option.name)
		end))
	end
	updateChips()

	addSlider(settingsPage, "Hub size", 80, 130, 100, 5, function(v)
		return v .. "%"
	end, function(v)
		hubScale.Scale = v / 100
		applyPanelSize()
	end)

	-- Keybinds (PC)
	addSection(settingsPage, "KEYBINDS")
	addNote(settingsPage, "PC only. Tap a key box, then press a key. Backspace clears it, Esc cancels.")

	local keybinds = {} -- ["TAB/Label" or "HUB"] = KeyCode name
	local bindCapture -- set while a key box is waiting for a key
	local BINDABLE = {
		{ key = "HUB", label = "Show / hide hub" },
		{ key = "VISUAL/Player ESP", label = "Player ESP" },
		{ key = "VISUAL/Object ESP", label = "Object ESP" },
		{ key = "VISUAL/X-ray", label = "X-ray" },
		{ key = "VISUAL/Fullbright", label = "Fullbright" },
		{ key = "VISUAL/Crosshair", label = "Crosshair" },
		{ key = "MOVE/TPwalk", label = "TPwalk" },
		{ key = "MOVE/Fly", label = "Fly" },
		{ key = "MOVE/Noclip", label = "Noclip" },
		{ key = "MOVE/Infinite jump", label = "Infinite jump" },
		{ key = "MOVE/Freecam", label = "Freecam" },
		{ key = "WORLD/Tap to teleport", label = "Tap to teleport" },
		{ key = "MISC/AFK mode", label = "AFK mode" },
	}
	keybinds.HUB = TOGGLE_KEY.Name
	local keyButtons = {}

	local function refreshKeyButtons()
		for key, button in keyButtons do
			button.Text = keybinds[key] or "NONE"
			button.TextColor3 = if keybinds[key] then CREAM else MUTED
		end
	end

	local function setBind(key, keyName)
		keybinds[key] = keyName
		if key == "HUB" then
			local ok, keyCode = pcall(function()
				return Enum.KeyCode[keyName or "RightShift"]
			end)
			TOGGLE_KEY = if ok and keyCode then keyCode else Enum.KeyCode.RightShift
			keybinds.HUB = TOGGLE_KEY.Name
		end
		refreshKeyButtons()
		markDirty()
	end

	for _, bind in BINDABLE do
		local row = addRow(settingsPage, ROW_H)
		rowLabel(row, bind.label, -110)
		local button = new("TextButton", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(92, ROW_H - 12),
			BackgroundColor3 = INK,
			FontFace = BODY_BOLD,
			Text = "NONE",
			TextSize = 12,
			TextColor3 = MUTED,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		})
		corner(button, 6)
		stroke(button, SCARLET_DEEP, 1)
		keyButtons[bind.key] = button
		table.insert(searchIndex, { label = "Keybind: " .. bind.label, tabName = "SETTINGS", row = row })
		track(button.Activated:Connect(function()
			button.Text = "PRESS KEY…"
			button.TextColor3 = SCARLET
			bindCapture = function(keyCode)
				if keyCode == Enum.KeyCode.Escape then
					refreshKeyButtons()
				elseif keyCode == Enum.KeyCode.Backspace or keyCode == Enum.KeyCode.Delete then
					setBind(bind.key, nil)
				else
					-- one key per feature: free it up anywhere else first
					for otherKey, name in keybinds do
						if name == keyCode.Name and otherKey ~= bind.key and otherKey ~= "HUB" then
							keybinds[otherKey] = nil
						end
					end
					setBind(bind.key, keyCode.Name)
				end
			end
		end))
	end
	refreshKeyButtons()

	local function runKeybind(keyCode)
		for key, name in keybinds do
			if key ~= "HUB" and name == keyCode.Name then
				local toggle = toggleRegistry[key]
				if toggle then
					local nextState = not toggle.get()
					toggle.set(nextState)
					notify(toggle.label .. (if nextState then " on" else " off"))
				end
			end
		end
	end

	-- Configs
	addSection(settingsPage, "CONFIG")
	local CONFIG_FOLDER = "LuciferHub"
	local CONFIG_FILE = CONFIG_FOLDER .. "/config.json"
	local canWriteFiles = executorFunction("writefile") ~= nil
	local savedWaypoints = {} -- waypoints from every game, keyed by place ID
	addNote(
		settingsPage,
		if canWriteFiles
			then "Auto-saves to workspace/" .. CONFIG_FILE .. " a few seconds after you change something."
			else "File saving isn't available here, so your config lasts until you leave this server."
	)

	local function serializeWaypoints()
		local list = {}
		for _, waypoint in waypoints do
			table.insert(list, { name = waypoint.name, cf = { waypoint.cframe:GetComponents() } })
		end
		return list
	end

	local function collectConfig()
		local values = {}
		for key, setting in settingsRegistry do
			values[key] = setting.get()
		end
		savedWaypoints[tostring(game.PlaceId)] = serializeWaypoints()
		return {
			version = 1,
			values = values,
			theme = theme.Name,
			keybinds = keybinds,
			objectKeywords = objectKeywordBox.Text,
			waypoints = savedWaypoints,
		}
	end

	local function saveConfig()
		configDirty = false
		local ok, encoded = pcall(function()
			return HttpService:JSONEncode(collectConfig())
		end)
		if not ok then
			return false
		end
		_G.LuciferHubConfig = encoded
		local writefile = executorFunction("writefile")
		if not writefile then
			return false
		end
		return (pcall(function()
			local isfolder, makefolder = executorFunction("isfolder"), executorFunction("makefolder")
			if makefolder and not (isfolder and isfolder(CONFIG_FOLDER)) then
				makefolder(CONFIG_FOLDER)
			end
			writefile(CONFIG_FILE, encoded)
		end))
	end

	local function readConfig()
		local raw
		local readfile, isfile = executorFunction("readfile"), executorFunction("isfile")
		if readfile then
			pcall(function()
				if not isfile or isfile(CONFIG_FILE) then
					raw = readfile(CONFIG_FILE)
				end
			end)
		end
		raw = raw or _G.LuciferHubConfig
		if type(raw) ~= "string" then
			return nil
		end
		local ok, data = pcall(function()
			return HttpService:JSONDecode(raw)
		end)
		return if ok and type(data) == "table" then data else nil
	end

	local function applyConfig(data)
		loadingConfig = true
		if type(data.theme) == "string" then
			setTheme(data.theme)
		end
		if type(data.objectKeywords) == "string" then
			objectKeywordBox.Text = data.objectKeywords
			setObjectKeywords(data.objectKeywords)
		end
		if type(data.values) == "table" then
			for key, value in data.values do
				local setting = settingsRegistry[key]
				if setting and type(value) == type(setting.get()) and value ~= setting.get() then
					pcall(setting.set, value)
				end
			end
		end
		if type(data.keybinds) == "table" then
			for key, name in data.keybinds do
				if type(key) == "string" and type(name) == "string" and keyButtons[key] then
					setBind(key, name)
				end
			end
		end
		if type(data.waypoints) == "table" then
			savedWaypoints = data.waypoints
			local list = savedWaypoints[tostring(game.PlaceId)]
			if type(list) == "table" then
				table.clear(waypoints)
				for _, saved in list do
					if type(saved) == "table" and type(saved.name) == "string" and type(saved.cf) == "table" and #saved.cf == 12 then
						table.insert(waypoints, { name = saved.name, cframe = CFrame.new(table.unpack(saved.cf)) })
					end
				end
				refreshWaypoints()
			end
		end
		loadingConfig = false
		configDirty = false
	end

	local function resetConfig()
		loadingConfig = true
		for _, setting in settingsRegistry do
			if setting.get() ~= setting.default then
				pcall(setting.set, setting.default)
			end
		end
		for key in keyButtons do
			keybinds[key] = nil
		end
		setBind("HUB", "RightShift")
		setTheme("Scarlet")
		objectKeywordBox.Text = ""
		setObjectKeywords("")
		loadingConfig = false
		saveConfig()
	end

	addButtonRow(settingsPage, {
		{
			"SAVE NOW",
			function()
				notify(if saveConfig() then "Config saved" else "Saved for this session")
			end,
		},
		{
			"RESET ALL",
			function()
				resetConfig()
				notify("Everything's back to default")
			end,
		},
	})

	--------------------------------------------------------------------------------
	-- Feature search
	--------------------------------------------------------------------------------

	local function jumpTo(item)
		currentTab = item.tabName
		searchBar.Text = "" -- reopens currentTab
		selectTab(item.tabName)
		task.defer(function()
			local page = tabs[item.tabName].page
			local row = item.row
			if not row.Parent then
				return
			end
			-- AbsolutePosition is in screen pixels, CanvasPosition isn't scaled by the hub size setting
			local designHeight = row.Size.Y.Offset
			local scale = if designHeight > 0 then math.max(row.AbsoluteSize.Y / designHeight, 0.01) else 1
			local y = (row.AbsolutePosition.Y - page.AbsolutePosition.Y) / scale + page.CanvasPosition.Y - 6
			page.CanvasPosition = Vector2.new(0, math.max(0, y))
			if row:IsA("GuiObject") and row.BackgroundTransparency < 1 then
				local original = row.BackgroundColor3
				row.BackgroundColor3 = SCARLET_DEEP
				tween(row, { BackgroundColor3 = original }, TweenInfo.new(0.9))
			end
		end)
	end

	local function runSearch()
		local query = string.lower(trim(searchBar.Text))
		searchClear.Visible = searchBar.Text ~= ""
		if query == "" then
			selectTab(currentTab)
			return
		end
		for _, tab in tabs do
			tab.page.Visible = false
			tab.button.BackgroundColor3 = INK_RAISED
			tab.button.TextColor3 = MUTED
		end
		searchPage.Visible = true
		clearList(searchPage)
		searchPage.CanvasPosition = Vector2.zero

		local shown = 0
		for _, item in searchIndex do
			if string.find(string.lower(item.label), query, 1, true) then
				shown += 1
				local button = new("TextButton", {
					Size = UDim2.new(1, -6, 0, ROW_H),
					BackgroundColor3 = INK_RAISED,
					AutoButtonColor = false,
					Text = "",
					LayoutOrder = nextOrder(searchPage),
					Parent = searchPage,
				})
				corner(button, 10)
				local resultStroke = stroke(button, EDGE, 1)
				resultStroke.Transparency = 0.35
				pressable(button)
				new("TextLabel", {
					BackgroundTransparency = 1,
					Position = UDim2.fromOffset(12, 0),
					Size = UDim2.new(1, -100, 1, 0),
					FontFace = BODY,
					Text = item.label,
					TextSize = 13,
					TextColor3 = CREAM,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTruncate = Enum.TextTruncate.AtEnd,
					Parent = button,
				})
				new("TextLabel", {
					AnchorPoint = Vector2.new(1, 0),
					BackgroundTransparency = 1,
					Position = UDim2.new(1, -12, 0, 0),
					Size = UDim2.new(0, 80, 1, 0),
					FontFace = RETRO,
					Text = item.tabName,
					TextSize = 13,
					TextColor3 = SCARLET,
					TextXAlignment = Enum.TextXAlignment.Right,
					Parent = button,
				})
				button.Activated:Connect(function()
					jumpTo(item)
				end)
			end
		end
		if shown == 0 then
			addNote(searchPage, "No features match that.")
		end
	end

	track(searchBar:GetPropertyChangedSignal("Text"):Connect(runSearch))

	selectTab("VISUAL")

	--------------------------------------------------------------------------------
	-- Runtime loops
	--------------------------------------------------------------------------------

	-- Camera: freecam, FOV, res stretch (after Roblox's camera updates)
	RunService:BindToRenderStep(RENDER_BIND, Enum.RenderPriority.Camera.Value + 1, function(dt)
		local camera = getCamera()

		if move.Freecam then
			local rotation = CFrame.fromEulerAnglesYXZ(freecam.pitch, freecam.yaw, 0)
			local moveVector = getMoveVector()
			local direction = rotation.LookVector * -moveVector.Z
				+ rotation.RightVector * moveVector.X
				+ Vector3.yAxis * verticalInput()
			if direction.Magnitude > 1 then
				direction = direction.Unit
			end
			freecam.position += direction * move.FreecamSpeed * dt
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = CFrame.new(freecam.position) * rotation
		end

		if visual.CustomFov then
			camera.FieldOfView = visual.Fov
		end

		if visual.Stretch > 0 then
			local s = STRETCH_LEVELS[visual.Stretch]
			camera.CFrame = camera.CFrame * CFrame.new(0, 0, 0, 1, 0, 0, 0, s, 0, 0, 0, 1)
		end
	end)

	-- ESP, fly steering, FPS counter, ember rings
	track(RunService.RenderStepped:Connect(function()
		stats.Frames += 1
		updateEsp()
		updateObjects()

		if ringState.Active and not motion.Reduced then
			local angle = (os.clock() * 60) % 360
			panelRing.Rotation = angle
			launcherRing.Rotation = angle
		end

		if move.Fly then
			local velocity, align = flyParts.velocity, flyParts.align
			if velocity and velocity.Parent then
				local cf = getCamera().CFrame
				local moveVector = getMoveVector()
				local direction = cf.LookVector * -moveVector.Z + cf.RightVector * moveVector.X + Vector3.yAxis * verticalInput()
				if direction.Magnitude > 1 then
					direction = direction.Unit
				end
				velocity.VectorVelocity = direction * move.FlySpeed
				local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
				if flat.Magnitude > 0.01 then
					align.CFrame = CFrame.lookAt(Vector3.zero, flat)
				end
			end
		end
	end))

	-- Noclip
	track(RunService.Stepped:Connect(function()
		if not move.Noclip then
			return
		end
		local character = player.Character
		if not character then
			return
		end
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") and part.CanCollide then
				noclipParts[part] = true
				part.CanCollide = false
			end
		end
	end))

	-- Toggles that count as "on" for the launcher badge, tab dots and footer
	local MAIN_FEATURES = {
		["VISUAL/Player ESP"] = true,
		["VISUAL/Object ESP"] = true,
		["VISUAL/X-ray"] = true,
		["VISUAL/Custom FOV"] = true,
		["VISUAL/Zoom unlock"] = true,
		["VISUAL/Crosshair"] = true,
		["VISUAL/Fullbright"] = true,
		["VISUAL/No fog"] = true,
		["VISUAL/No blur / effects"] = true,
		["VISUAL/Custom time of day"] = true,
		["MOVE/TPwalk"] = true,
		["MOVE/Fly"] = true,
		["MOVE/Noclip"] = true,
		["MOVE/Infinite jump"] = true,
		["MOVE/Custom jump height"] = true,
		["MOVE/Freecam"] = true,
		["WORLD/Tap to teleport"] = true,
		["WORLD/Tap to hide parts"] = true,
		["MISC/AFK mode"] = true,
		["MISC/Anti-AFK"] = true,
		["MISC/Stats overlay (FPS / ping)"] = true,
		["MISC/Auto-rejoin on kick"] = true,
	}

	local function statusColor(value, good, okay, higherIsBetter)
		local isGood = if higherIsBetter then value >= good else value <= good
		local isOkay = if higherIsBetter then value >= okay else value <= okay
		return if isGood then "#3CFF78" elseif isOkay then "#FFB03C" else "#FF4B4B"
	end

	local function updateStatus(fps)
		local activeTotal = 0
		local activeTabs = {}
		for key in MAIN_FEATURES do
			local toggle = toggleRegistry[key]
			if toggle and toggle.get() then
				activeTotal += 1
				activeTabs[string.match(key, "^[^/]+")] = true
			end
		end
		if visual.Stretch > 0 then
			activeTotal += 1
			activeTabs.VISUAL = true
		end
		if animation.Track then
			activeTotal += 1
			activeTabs.MOVE = true
		end
		if follow.Target or spectating then
			activeTotal += 1
			activeTabs.PLAYERS = true
		end

		ringState.Active = activeTotal > 0
		launcherBadge.Text = tostring(activeTotal)
		launcherBadge.Visible = activeTotal > 0
		for tabName, tab in tabs do
			tab.dot.Visible = activeTabs[tabName] == true
		end
		if activeTotal > 0 then
			footerStatus.TextColor3 = CREAM
			footerStatus.Text = string.format(
				'<font color="#%s">●</font>  %d feature%s on',
				SCARLET:ToHex(),
				activeTotal,
				if activeTotal == 1 then "" else "s"
			)
		else
			footerStatus.TextColor3 = MUTED
			footerStatus.Text = "Nothing switched on"
		end
		footerFps.Text = fps .. " fps"
	end

	-- TPwalk, jump height, spectate follow, lighting, stats, AFK timer
	local lightTimer = 0
	local statTimer = 0
	local themeTimer = 0
	local configTimer = 0
	local lastView = getCamera().ViewportSize
	track(RunService.Heartbeat:Connect(function(dt)
		local humanoid = getHumanoid()
		local root = getRoot()

		if move.TPWalk and humanoid and root and not move.Fly and not move.Freecam then
			if humanoid.MoveDirection.Magnitude > 0 then
				root.CFrame += humanoid.MoveDirection * move.TPSpeed * dt
			end
		end

		if move.CustomJump and humanoid then
			if not jumpBackup then
				setCustomJump(true)
			end
			setProp(humanoid, "UseJumpPower", false)
			setProp(humanoid, "JumpHeight", move.JumpHeight)
		end

		if spectating then
			local target = spectating.Character and spectating.Character:FindFirstChildOfClass("Humanoid")
			local camera = getCamera()
			if target and camera.CameraSubject ~= target then
				camera.CameraSubject = target
			end
		end

		if follow.Target and root and not move.Freecam then
			local targetCharacter = follow.Target.Character
			local targetRoot = targetCharacter and targetCharacter:FindFirstChild("HumanoidRootPart")
			if targetRoot then
				root.CFrame = targetRoot.CFrame * CFrame.new(0, 0, follow.Distance)
				root.AssemblyLinearVelocity = Vector3.zero
			end
		end

		if visual.ZoomUnlock then
			setProp(player, "CameraMaxZoomDistance", 5000)
			setProp(player, "CameraMode", Enum.CameraMode.Classic)
		end

		if theme.Name == "Rainbow" then
			themeTimer += dt
			if themeTimer >= 0.25 then
				themeTimer = 0
				theme.Hue = (theme.Hue + 0.03) % 1
				recolor(Color3.fromHSV(theme.Hue, 0.8, 1))
			end
		end

		configTimer += dt
		if configTimer >= 3 then
			configTimer = 0
			if configDirty then
				saveConfig()
			end
		end

		lightTimer += dt
		if lightTimer >= 0.25 then
			lightTimer = 0
			enforceLighting()
		end

		statTimer += dt
		if statTimer >= 0.5 then
			local fps = math.floor(stats.Frames / statTimer + 0.5)
			if stats.Enabled then
				local ping = math.floor(getPing() + 0.5)
				statsLabel.Text = string.format(
					'<font color="%s">%d</font> fps    <font color="%s">%d</font> ms    %d/%d players',
					statusColor(fps, 50, 30, true),
					fps,
					statusColor(ping, 100, 200, false),
					ping,
					#Players:GetPlayers(),
					Players.MaxPlayers
				)
			end
			updateStatus(fps)
			stats.Frames = 0
			statTimer = 0

			if afk.Mode then
				afkTimer.Text = formatTime(os.time() - afk.StartedAt)
			end

			if holder.Visible and miscPage.Visible then
				updateServerInfo()
			end

			local view = getCamera().ViewportSize
			if view ~= lastView then
				lastView = view
				applyPanelSize()
				clampToScreen(launcher)
				clampToScreen(statsLabel)
			end
		end
	end))

	-- Infinite jump
	track(UserInputService.JumpRequest:Connect(function()
		if move.InfJump and not move.Fly then
			local humanoid = getHumanoid()
			if humanoid and humanoid.Health > 0 then
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
			end
		end
	end))

	-- Keybinds, tap TP, tap to hide
	local tapStarts = {}
	track(UserInputService.InputBegan:Connect(function(input, processed)
		if bindCapture and input.UserInputType == Enum.UserInputType.Keyboard then
			local capture = bindCapture
			bindCapture = nil
			capture(input.KeyCode)
			return
		end
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			if input.KeyCode == TOGGLE_KEY then
				toggleHub()
			else
				runKeybind(input.KeyCode)
			end
			return
		end
		if (world.TapTP or world.TapHide) and isPress(input) then
			tapStarts[input] = { position = input.Position, time = os.clock() }
		end
	end))
	track(UserInputService.InputEnded:Connect(function(input)
		local start = tapStarts[input]
		if not start then
			return
		end
		tapStarts[input] = nil
		local isTap = os.clock() - start.time < 0.3 and (input.Position - start.position).Magnitude < 12
		if not isTap then
			return
		end
		if world.TapHide then
			hidePartAt(input.Position)
		elseif world.TapTP then
			tapTeleport(input.Position)
		end
	end))

	-- New parts: keep x-ray and object ESP up to date
	track(Workspace.DescendantAdded:Connect(function(inst)
		local isPart = inst:IsA("BasePart")
		if xray.Enabled and isPart then
			task.defer(function()
				if inst.Parent and xray.Enabled then
					applyXrayTo(inst)
				end
			end)
		end
		if objectEsp.Enabled and #objectEsp.Keywords > 0 and (isPart or inst:IsA("Model")) then
			task.defer(function()
				if inst.Parent and objectEsp.Enabled then
					addObject(inst)
				end
			end)
		end
	end))

	-- Chat log (new chat system first, legacy chat as a fallback)
	local chatHooked = false
	pcall(function()
		if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
			track(TextChatService.MessageReceived:Connect(function(message)
				if not logState.Chat then
					return
				end
				local source = message.TextSource
				local speaker = "System"
				if source then
					local sender = Players:GetPlayerByUserId(source.UserId)
					speaker = if sender then sender.DisplayName else source.Name
				end
				logEvent("chat", speaker .. ": " .. message.Text)
			end))
			chatHooked = true
		end
	end)

	local function hookLegacyChat(plr)
		if chatHooked then
			return
		end
		track(plr.Chatted:Connect(function(text)
			if logState.Chat then
				logEvent("chat", plr.DisplayName .. ": " .. text)
			end
		end))
	end
	for _, plr in Players:GetPlayers() do
		hookLegacyChat(plr)
	end

	-- Auto-rejoin when the disconnect / kick screen shows up.
	-- The kick-screen event is Roblox-only: executors can reach it, normal scripts can't,
	-- so the hookup is guarded and the toggle explains itself when it's unavailable.
	local rejoinQueued = false
	autoRejoinAvailable = pcall(function()
		track(GuiService.ErrorMessageChanged:Connect(function(message)
			if not world.AutoRejoin or rejoinQueued or message == "" then
				return
			end
			rejoinQueued = true
			task.delay(3, function()
				pcall(function()
					TeleportService:Teleport(game.PlaceId, player)
				end)
				task.wait(10)
				rejoinQueued = false
			end)
		end))
	end)

	-- Freecam look
	track(UserInputService.InputChanged:Connect(function(input, processed)
		if not move.Freecam then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			if UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
				rotateFreecam(input.Delta, 0.0045)
			end
		elseif input.UserInputType == Enum.UserInputType.Touch and not processed then
			rotateFreecam(input.Delta, 0.008)
		end
	end))

	-- Anti-AFK: answer Roblox's idle check, plus a jump every 20 seconds
	track(player.Idled:Connect(function()
		if not antiAfkActive() then
			return
		end
		pcall(function()
			local virtualUser = game:GetService("VirtualUser")
			virtualUser:CaptureController()
			virtualUser:ClickButton2(Vector2.new())
		end)
	end))
	task.spawn(function()
		while running do
			task.wait(ANTI_AFK_JUMP_INTERVAL)
			if running and antiAfkActive() then
				local humanoid = getHumanoid()
				if humanoid and humanoid.Health > 0 then
					humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				end
			end
		end
	end)

	track(afkExit.Activated:Connect(function()
		setAfkMode(false)
	end))

	-- Respawns
	track(player.CharacterAdded:Connect(function(character)
		table.clear(noclipParts)
		table.clear(flyParts)
		jumpBackup = nil
		animation.Track = nil
		walkToken += 1
		if move.Freecam then
			freecam.anchoredRoot = nil
			setFreecam(false)
		end
		character:WaitForChild("HumanoidRootPart", 10)
		character:WaitForChild("Humanoid", 10)
		if move.Fly and running then
			attachFly()
		end
	end))

	-- Players joining / leaving
	for _, plr in Players:GetPlayers() do
		trackPlayer(plr)
	end
	track(Players.PlayerAdded:Connect(function(plr)
		trackPlayer(plr)
		hookLegacyChat(plr)
		refreshPlayerList()
		if logState.Joins then
			logEvent("join", plr.DisplayName .. " (@" .. plr.Name .. ") joined")
		end
		if logState.Toasts then
			notify(plr.DisplayName .. " joined")
		end
	end))
	track(Players.PlayerRemoving:Connect(function(plr)
		untrackPlayer(plr)
		if spectating == plr then
			stopSpectate()
			notify(plr.DisplayName .. " left")
		end
		if follow.Target == plr then
			follow.Target = nil
			notify("Stopped following, " .. plr.DisplayName .. " left")
		end
		if logState.Joins then
			logEvent("leave", plr.DisplayName .. " (@" .. plr.Name .. ") left")
		end
		if logState.Toasts then
			notify(plr.DisplayName .. " left")
		end
		task.defer(refreshPlayerList)
	end))
	refreshPlayerList()

	--------------------------------------------------------------------------------
	-- Unload
	--------------------------------------------------------------------------------

	local function unload()
		if not running then
			return
		end
		running = false
		pcall(saveConfig) -- save before features get switched off below
		pcall(function()
			RunService:UnbindFromRenderStep(RENDER_BIND)
		end)
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)

		stopSpectate()
		setFreecam(false)
		setFly(false)
		setNoclip(false)
		setCustomJump(false)
		setCustomFov(false)
		visual.Stretch = 0
		setFullbright(false)
		setNoFog(false)
		setNoEffects(false)
		if afk.Capped then
			setFpsCap(0)
		end
		afk.Mode = false
		afk.Render = true
		applyRender()
		follow.Target = nil
		walkToken += 1
		stopAnimation()
		clearObjects()
		restoreHidden()
		setXray(false)
		setZoomUnlock(false)
		setCustomTime(false)

		for plr in espEntries do
			untrackPlayer(plr)
		end
		gui:Destroy()
		espFolder:Destroy()
		if _G.LuciferHubUnload == unload then
			_G.LuciferHubUnload = nil
		end
	end

	_G.LuciferHubUnload = unload
	track(unloadButton.Activated:Connect(unload))

	local savedConfig = readConfig()
	if savedConfig then
		local ok = pcall(applyConfig, savedConfig)
		loadingConfig = false
		if ok then
			notify("Config loaded")
		end
	end

	setHubOpen(true)
	notify("Lucifer Hub loaded 😈")
end

main()
