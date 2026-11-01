--[[
	FEED THE FIRE — REPLAY-STREAM AUTOPILOT
	Game: MyFireRebuild  (PlaceId 77993383305312)
	Executor target: Delta (Android).  Client-sided LocalScript.

	HOW IT WORKS (read this, it matters):
	  This game is a deterministic client sim. The ONLY gameplay channel to the
	  server is Remotes.SubmitInput, which streams a binary buffer of input ticks.
	  The server REPLAYS that buffer through the same sim to derive your save, then
	  SaveGuard.sanitise() clamps embers to a max of 1e15. There is no "give money"
	  packet — embers are earned, never set.

	  The Host records every input tick through Replay.recorder():push(frame). That
	  push() both (a) returns the canonical frame the LOCAL sim ticks and (b) is what
	  gets encoded into the SubmitInput buffer. So if we hook push() and force
	  down=true at a valid aim, the local sim AND the server-replayed buffer become
	  identical and productive — the game itself feeds the fire and earns embers.

	  We do NOT flood the stream. The Host calls push() once per game tick (~60 Hz),
	  so we stay at realtime pace and never trip Authority's burst/bank budget. We
	  only change WHAT each natural frame contains. It is indistinguishable from a
	  human holding fire on a good target — because it is exactly that.

	  "What you see earn locally is what the server banks." Calibrate aim by watching
	  your own embers climb; if it climbs locally, the server replays the same thing.

	AIM MODES:
	  • Hold-only  : forces down=true, keeps the game's own aim (you still point).
	  • Locked aim : forces down=true at a captured mx,my (hands-off / AFK farm).

	SAFETY:
	  • Embers cap: autopilot auto-stops when embers reach your cap (keep it under
	    1e15 — default 1e12). Overshooting toward the hard clamp looks dumb; don't.
	  • You must be IN A ROUND for push() to fire. In menus it just waits.
]]

--=====================================================================
--  0. SERVICES / EXECUTOR SHIMS
--=====================================================================
local Players           = game:GetService("Players")
local UserInputService  = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")

local LocalPlayer       = Players.LocalPlayer

-- Executor function resolution (Delta names, with fallbacks).
-- Referencing an undefined global returns nil in Luau (never errors), and
-- getgenv() (when present) exposes the executor's global table directly.
local G             = (getgenv and getgenv()) or _G
local _getgc        = getgc        or G.getgc
local _getupvalues  = getupvalues  or G.getupvalues  or (debug and debug.getupvalues)
local _getupvalue   = getupvalue   or G.getupvalue   or (debug and debug.getupvalue)
local _gethui       = gethui       or G.gethui
local _protectgui   = (syn and syn.protect_gui) or protect_gui or G.protect_gui

assert(_getgc, "[Autopilot] getgc not available on this executor")
assert(_getupvalues or _getupvalue, "[Autopilot] getupvalues not available")

-- Return the upvalues of a function as an array, whichever API exists.
local function upvalsOf(fn)
	if _getupvalues then
		local ok, ups = pcall(_getupvalues, fn)
		if ok and type(ups) == "table" then return ups end
	end
	if _getupvalue then
		local out, i = {}, 1
		while true do
			local ok, v = pcall(_getupvalue, fn, i)
			if not ok or v == nil then break end
			out[i] = v
			i += 1
			if i > 256 then break end -- safety
		end
		return out
	end
	return {}
end

--=====================================================================
--  1. DISCOVER THE LIVE HOST OBJECTS
--     recorder (push/take/pendingTicks), SubmitInput remote, sim (exportSave/tick)
--=====================================================================
local Found = {
	recorder = nil, -- Replay.recorder() instance the Host streams through
	remote   = nil, -- Remotes.SubmitInput RemoteEvent
	sim      = nil, -- Game.create(...) instance (for embers readout)
}

-- A recorder is a table with these function fields.
local function looksLikeRecorder(t)
	return type(t) == "table"
		and type(rawget(t, "push")) == "function"
		and type(rawget(t, "take")) == "function"
		and type(rawget(t, "pendingTicks")) == "function"
		and type(rawget(t, "pending")) == "function"
end

-- The sim is a table exposing both exportSave and tick.
local function looksLikeSim(t)
	return type(t) == "table"
		and type(rawget(t, "exportSave")) == "function"
		and type(rawget(t, "tick")) == "function"
		and type(rawget(t, "shopOpen")) == "function"
end

-- Find the pumpStream/tick closure: it holds the SubmitInput remote AND the
-- Host's recorder as upvalues. That pins the EXACT recorder that feeds the
-- SubmitInput stream (party recorders feed PartyInput, so we skip those).
local function discover()
	local gc = _getgc(true)
	for _, v in ipairs(gc) do
		if type(v) == "function" then
			local ups = upvalsOf(v)
			local remote, rec
			for _, u in pairs(ups) do
				if typeof(u) == "Instance"
					and u:IsA("RemoteEvent")
					and u.Name == "SubmitInput" then
					remote = u
				elseif looksLikeRecorder(u) then
					rec = u
				end
			end
			if remote and rec then
				Found.remote, Found.recorder = remote, rec
				break
			end
		end
	end

	-- Sim can be found independently (any closure holding it, or in gc directly).
	if not Found.sim then
		for _, v in ipairs(gc) do
			if looksLikeSim(v) then
				Found.sim = v
				break
			end
		end
	end
	if not Found.sim then
		for _, v in ipairs(gc) do
			if type(v) == "function" then
				for _, u in pairs(upvalsOf(v)) do
					if looksLikeSim(u) then
						Found.sim = u
						break
					end
				end
			end
			if Found.sim then break end
		end
	end

	return Found.recorder ~= nil and Found.remote ~= nil
end

--=====================================================================
--  2. STATE / CONFIG
--=====================================================================
local State = {
	on         = false,     -- autopilot master
	mode       = "hold",    -- "hold" | "locked" | "points"
	aim        = nil,       -- {x=,y=} captured mx,my for locked mode
	capturing  = false,     -- arm single-aim capture on next frame
	points     = {},        -- up to 5 {x,y} aim points for "points" cycle mode
	ptIdx      = 1,         -- which point the cycle is on right now
	ptDwell    = 1,         -- ticks spent per point before advancing (1 = fastest)
	ptTick     = 0,         -- internal dwell counter
	walk       = 0,         -- -1 / 0 / 1, forced movement (0 = leave game's)
	advance    = true,      -- auto-skip cutscenes (dead-time killer)
	autoRevive = false,     -- tap the revive button on death (opt-in)
	antiIdle   = true,      -- defeat the 20-min AFK kick
	autoRejoin = false,     -- teleport back in on disconnect (opt-in)
	cap        = 1e12,      -- auto-stop embers threshold (keep < 1e15)
	forced     = 0,         -- count of frames we've forced (rate feedback)
	lastAim    = {x = 0, y = 0}, -- last seen live aim (for quick-lock)
	embers     = nil,       -- throttled readout
	phase      = "?",       -- last read sim.state() for the status line
	lastPhase  = "?",       -- previous phase (for round-transition counting)
	rounds     = 0,         -- rounds entered this session
	startEmbers = nil,      -- embers when autopilot first started (session base)
	rate       = 0,         -- embers/sec (rolling)
	_rT        = 0,         -- last rate-sample clock
	_rE        = nil,       -- last rate-sample embers
	minimized  = false,
	installed  = false,
}
local HARD_CLAMP = 1e15    -- SaveGuard.sanitise embers ceiling
local REVIVE_C  = { x = 480, y = 300 } -- centre of REVIVE_BTN {330,273,300,54}

-- Current phase string from the sim: "round","won","dead","flash","rain",
-- "intro","cutscene","results","upgrade","rearrange","board","menu","place",
-- "zed". Light (returns one upvalue). Declared before the hook so the hook
-- closure captures it. We only FEED during "round" — fuel exists only then,
-- and forcing down in menu/shop/results phases would click UI at the aim.
local function simState()
	if not Found.sim then return nil end
	local ok, v = pcall(Found.sim.state)
	if ok and type(v) == "string" then return v end
	return nil
end

--=====================================================================
--  3. THE PUSH HOOK  (single point of control)
--=====================================================================
local origPush

local function installHook()
	if State.installed then return true end
	if not Found.recorder then return false end

	origPush = Found.recorder.push

	Found.recorder.push = function(frame)
		-- Always learn the live aim so "Quick Lock" has something to grab.
		if type(frame) == "table" then
			if type(frame.mx) == "number" then State.lastAim.x = frame.mx end
			if type(frame.my) == "number" then State.lastAim.y = frame.my end

			if State.capturing then
				State.aim = { x = frame.mx or 0, y = frame.my or 0 }
				State.capturing = false
			end
			if State.on then
				local st = simState()
				-- Count a new round each time we transition INTO "round".
				if st == "round" and State.lastPhase ~= "round" then
					State.rounds += 1
				end
				State.lastPhase = st or State.lastPhase
				State.phase = st or "?"

				if st == "dead" and State.autoRevive then
					-- AUTO-REVIVE: tap the revive button (server replays the click).
					-- If no revive is offered, this coordinate is harmless.
					frame.down = true
					frame.mx   = REVIVE_C.x
					frame.my   = REVIVE_C.y
				elseif st == "round" or st == nil then
					-- FEED: force fire held at a valid aim. Mutating the frame BEFORE
					-- origPush means the local sim tick AND the streamed buffer both
					-- carry it — the server replays identical productive input.
					-- st == nil => sim wasn't found; fall back to always-feed so the
					-- recorder-only case still works (you just lose phase gating).
					frame.down = true
					if State.mode == "locked" and State.aim then
						frame.mx = State.aim.x
						frame.my = State.aim.y
					elseif State.mode == "points" and #State.points > 0 then
						-- POINT CYCLE: aim at the current point, then step to the next
						-- after ptDwell ticks (1 = flick to a new point every tick).
						local p = State.points[State.ptIdx] or State.points[1]
						frame.mx = p.x
						frame.my = p.y
						State.ptTick += 1
						if State.ptTick >= State.ptDwell then
							State.ptTick = 0
							State.ptIdx = (State.ptIdx % #State.points) + 1
						end
					end
					if State.walk ~= 0 then
						frame.walk = State.walk
					end
					State.forced += 1
				elseif st == "cutscene" and State.advance then
					-- AUTO-ADVANCE: hold skip through story cutscenes (0.85s skips to
					-- intro). Cosmetic-only; never touches down, so no misclicks.
					frame.skip = true
				end
				-- Any other phase (won/dead/intro/flash/rain/results/upgrade/menu/…)
				-- is left untouched — those advance on their own timers, and forcing
				-- down there would click menus/shops at the locked coordinate.
			end
		end
		return origPush(frame)
	end

	State.installed = true
	return true
end

local function uninstallHook()
	if State.installed and origPush and Found.recorder then
		Found.recorder.push = origPush
		State.installed = false
	end
end

--=====================================================================
--  4. EMBERS READOUT  (throttled; exportSave is heavy)
--=====================================================================
local function readEmbers()
	if not Found.sim then return nil end
	local ok, save = pcall(Found.sim.exportSave)
	if ok and type(save) == "table" and type(save.embers) == "number" then
		return save.embers
	end
	return nil
end

--=====================================================================
--  5. GUI  (mobile-friendly, draggable, self-contained — no deps)
--=====================================================================
local function fmt(n)
	if not n then return "?" end
	local u = {"", "K", "M", "B", "T", "Qa", "Qi"}
	local i = 1
	while n >= 1000 and i < #u do n /= 1000; i += 1 end
	return string.format("%.2f%s", n, u[i])
end

local gui = Instance.new("ScreenGui")
gui.Name            = "FeedFireAutopilot"
gui.ResetOnSpawn    = false
gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
gui.IgnoreGuiInset  = true
pcall(function() if _protectgui then _protectgui(gui) end end)
gui.Parent = (_gethui and _gethui())
	or (gethui and gethui())
	or LocalPlayer:WaitForChild("PlayerGui")

-- Root panel
local root = Instance.new("Frame")
root.Name                   = "Root"
root.AnchorPoint            = Vector2.new(0, 0)
root.Position               = UDim2.fromOffset(16, 90)
root.Size                   = UDim2.fromOffset(250, 0)
root.AutomaticSize          = Enum.AutomaticSize.Y  -- grows/shrinks to content
root.BackgroundColor3       = Color3.fromRGB(18, 16, 20)
root.BackgroundTransparency = 0.05
root.BorderSizePixel        = 0
root.Active                 = true
root.Parent                 = gui
Instance.new("UICorner", root).CornerRadius = UDim.new(0, 12)
local stroke = Instance.new("UIStroke", root)
stroke.Color = Color3.fromRGB(255, 138, 48)
stroke.Thickness = 1.5
stroke.Transparency = 0.2

local pad = Instance.new("UIPadding", root)
pad.PaddingTop    = UDim.new(0, 8)
pad.PaddingBottom = UDim.new(0, 8)
pad.PaddingLeft   = UDim.new(0, 10)
pad.PaddingRight  = UDim.new(0, 10)

local list = Instance.new("UIListLayout", root)
list.SortOrder   = Enum.SortOrder.LayoutOrder
list.Padding     = UDim.new(0, 6)
list.FillDirection = Enum.FillDirection.Vertical

-- Title bar (drag handle)
local title = Instance.new("TextLabel")
title.Name               = "Title"
title.LayoutOrder        = 1
title.Size               = UDim2.new(1, 0, 0, 26)
title.BackgroundTransparency = 1
title.Font               = Enum.Font.GothamBold
title.Text               = "🔥 Feed The Fire — Autopilot"
title.TextSize           = 14
title.TextColor3         = Color3.fromRGB(255, 180, 90)
title.TextXAlignment     = Enum.TextXAlignment.Left
title.Parent             = root

-- Minimize button lives inside the title (not in the list layout).
local btnMin = Instance.new("TextButton")
btnMin.Name                 = "Min"
btnMin.AnchorPoint          = Vector2.new(1, 0.5)
btnMin.Position             = UDim2.new(1, 0, 0.5, 0)
btnMin.Size                 = UDim2.fromOffset(24, 20)
btnMin.BackgroundColor3     = Color3.fromRGB(40, 36, 44)
btnMin.Font                 = Enum.Font.GothamBold
btnMin.TextSize             = 14
btnMin.TextColor3           = Color3.fromRGB(240, 240, 240)
btnMin.Text                 = "–"
btnMin.BorderSizePixel      = 0
btnMin.Parent               = title
Instance.new("UICorner", btnMin).CornerRadius = UDim.new(0, 6)

-- Helper: make a full-width button
local function mkButton(text, order, color)
	local b = Instance.new("TextButton")
	b.LayoutOrder            = order
	b.Size                   = UDim2.new(1, 0, 0, 34)
	b.BackgroundColor3       = color or Color3.fromRGB(40, 36, 44)
	b.AutoButtonColor        = true
	b.Font                   = Enum.Font.GothamSemibold
	b.TextSize               = 14
	b.TextColor3             = Color3.fromRGB(240, 240, 240)
	b.Text                   = text
	b.BorderSizePixel        = 0
	b.Parent                 = root
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
	return b
end

-- Helper: status/label line
local function mkLabel(order)
	local l = Instance.new("TextLabel")
	l.LayoutOrder            = order
	l.Size                   = UDim2.new(1, 0, 0, 18)
	l.BackgroundTransparency = 1
	l.Font                   = Enum.Font.Gotham
	l.TextSize               = 12
	l.TextColor3             = Color3.fromRGB(190, 190, 200)
	l.TextXAlignment         = Enum.TextXAlignment.Left
	l.Text                   = ""
	l.Parent                 = root
	return l
end

local btnMaster  = mkButton("▶  START", 2, Color3.fromRGB(32, 90, 44))
local btnMode    = mkButton("Mode: Hold-only", 3)
local btnAddPt   = mkButton("➕ Add Point (0/5)", 4)
local btnClearPt = mkButton("🗑 Clear Points", 5)
local btnSpeed   = mkButton("Cycle speed: 1 tick/pt", 6)
local btnCapture = mkButton("📍  Lock Aim (point first)", 7)
local btnAdvance = mkButton("Auto-advance: ON (skip cutscenes)", 8)
local btnWalk    = mkButton("Walk: Off", 9)
local btnRevive  = mkButton("Auto-revive: OFF", 10)
local btnIdle    = mkButton("Anti-idle: ON", 11)
local btnRejoin  = mkButton("Auto-rejoin: OFF", 12)

-- Cap input row
local capBox = Instance.new("TextBox")
capBox.LayoutOrder        = 13
capBox.Size               = UDim2.new(1, 0, 0, 30)
capBox.BackgroundColor3   = Color3.fromRGB(40, 36, 44)
capBox.Font               = Enum.Font.Gotham
capBox.TextSize           = 13
capBox.TextColor3         = Color3.fromRGB(240, 240, 240)
capBox.PlaceholderText    = "Stop at embers (e.g. 1e12)"
capBox.Text               = "1e12"
capBox.ClearTextOnFocus   = false
capBox.BorderSizePixel    = 0
capBox.Parent             = root
Instance.new("UICorner", capBox).CornerRadius = UDim.new(0, 8)

local lblEmbers = mkLabel(14)
local lblStats  = mkLabel(15)
local lblStatus = mkLabel(16)

--=====================================================================
--  6. DRAG  (touch + mouse)
--=====================================================================
do
	local dragging, dragStart, startPos
	local function begin(input)
		dragging  = true
		dragStart = input.Position
		startPos  = root.Position
	end
	local function update(input)
		local d = input.Position - dragStart
		root.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + d.X,
			startPos.Y.Scale, startPos.Y.Offset + d.Y)
	end
	title.Active = true
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			begin(input)
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			update(input)
		end
	end)
end

--=====================================================================
--  7. WIRING
--=====================================================================
-- Reflect State onto every toggle's label.
local function modeName()
	return (State.mode == "hold" and "Hold-only")
		or (State.mode == "locked" and "Locked aim")
		or "Points cycle"
end

local function refreshButtons()
	btnMode.Text    = "Mode: " .. modeName()
	btnAddPt.Text   = string.format("➕ Add Point (%d/5)", #State.points)
	btnSpeed.Text   = "Cycle speed: " .. State.ptDwell .. " tick/pt"
	btnAdvance.Text = "Auto-advance: " .. (State.advance and "ON (skip cutscenes)" or "OFF")
	btnWalk.Text    = "Walk: " .. (State.walk == 0 and "Off" or (State.walk < 0 and "◀ Left" or "Right ▶"))
	btnRevive.Text  = "Auto-revive: " .. (State.autoRevive and "ON" or "OFF")
	btnIdle.Text    = "Anti-idle: " .. (State.antiIdle and "ON" or "OFF")
	btnRejoin.Text  = "Auto-rejoin: " .. (State.autoRejoin and "ON" or "OFF")
	capBox.Text     = tostring(State.cap)
end

-- Settings persistence (executor filesystem; all guarded — never load-bearing).
local CFG_PATH    = "ftf_autopilot.json"
local HttpService = game:GetService("HttpService")
local _writefile  = writefile or G.writefile
local _readfile   = readfile  or G.readfile
local _isfile     = isfile    or G.isfile

local function saveCfg()
	if not _writefile then return end
	pcall(function()
		_writefile(CFG_PATH, HttpService:JSONEncode({
			mode = State.mode, walk = State.walk, advance = State.advance,
			autoRevive = State.autoRevive, antiIdle = State.antiIdle,
			autoRejoin = State.autoRejoin, cap = State.cap, aim = State.aim,
			points = State.points, ptDwell = State.ptDwell,
		}))
	end)
end

local function loadCfg()
	if not _readfile then return end
	local ok, raw = pcall(function()
		if _isfile and not _isfile(CFG_PATH) then return nil end
		return _readfile(CFG_PATH)
	end)
	if ok and type(raw) == "string" then
		local ok2, d = pcall(function() return HttpService:JSONDecode(raw) end)
		if ok2 and type(d) == "table" then
			if type(d.mode) == "string" then State.mode = d.mode end
			if type(d.walk) == "number" then State.walk = d.walk end
			if type(d.advance) == "boolean" then State.advance = d.advance end
			if type(d.autoRevive) == "boolean" then State.autoRevive = d.autoRevive end
			if type(d.antiIdle) == "boolean" then State.antiIdle = d.antiIdle end
			if type(d.autoRejoin) == "boolean" then State.autoRejoin = d.autoRejoin end
			if type(d.cap) == "number" and d.cap > 0 then
				State.cap = math.min(d.cap, HARD_CLAMP * 0.999)
			end
			if type(d.aim) == "table" and type(d.aim.x) == "number"
				and type(d.aim.y) == "number" then
				State.aim = { x = d.aim.x, y = d.aim.y }
			end
			if type(d.ptDwell) == "number" and d.ptDwell >= 1 then
				State.ptDwell = math.floor(d.ptDwell)
			end
			if type(d.points) == "table" then
				local pts = {}
				for _, p in ipairs(d.points) do
					if type(p) == "table" and type(p.x) == "number"
						and type(p.y) == "number" and #pts < 5 then
						pts[#pts + 1] = { x = p.x, y = p.y }
					end
				end
				State.points = pts
			end
		end
	end
	refreshButtons()
end

local function setMaster(v)
	State.on = v and State.installed
	if State.on then
		btnMaster.Text = "⏸  STOP"
		btnMaster.BackgroundColor3 = Color3.fromRGB(120, 40, 40)
	else
		btnMaster.Text = "▶  START"
		btnMaster.BackgroundColor3 = Color3.fromRGB(32, 90, 44)
	end
end

btnMaster.MouseButton1Click:Connect(function()
	if not State.installed then return end
	setMaster(not State.on)
end)

btnMode.MouseButton1Click:Connect(function()
	-- hold -> locked -> points -> hold
	State.mode = (State.mode == "hold" and "locked")
		or (State.mode == "locked" and "points")
		or "hold"
	btnMode.Text = "Mode: " .. modeName()
	saveCfg()
end)

btnAddPt.MouseButton1Click:Connect(function()
	-- Capture where you're pointing right now as the next cycle point (max 5).
	if #State.points >= 5 then
		btnAddPt.Text = "➕ Full (5/5) — Clear first"
		task.delay(1.2, function()
			btnAddPt.Text = string.format("➕ Add Point (%d/5)", #State.points)
		end)
		return
	end
	State.points[#State.points + 1] = { x = State.lastAim.x, y = State.lastAim.y }
	btnAddPt.Text = string.format("➕ Added #%d (%d/5)", #State.points, #State.points)
	task.delay(1.2, function()
		btnAddPt.Text = string.format("➕ Add Point (%d/5)", #State.points)
	end)
	saveCfg()
end)

btnClearPt.MouseButton1Click:Connect(function()
	State.points = {}
	State.ptIdx, State.ptTick = 1, 0
	btnAddPt.Text = "➕ Add Point (0/5)"
	saveCfg()
end)

btnSpeed.MouseButton1Click:Connect(function()
	-- Cycle through dwell values: 1 -> 2 -> 4 -> 8 -> 1 ticks per point.
	State.ptDwell = (State.ptDwell == 1 and 2)
		or (State.ptDwell == 2 and 4)
		or (State.ptDwell == 4 and 8)
		or 1
	btnSpeed.Text = "Cycle speed: " .. State.ptDwell .. " tick/pt"
	saveCfg()
end)

btnAdvance.MouseButton1Click:Connect(function()
	State.advance = not State.advance
	btnAdvance.Text = State.advance
		and "Auto-advance: ON (skip cutscenes)"
		or  "Auto-advance: OFF"
	saveCfg()
end)

btnCapture.MouseButton1Click:Connect(function()
	-- Lock to the aim seen on the very next streamed frame (point first, then tap).
	State.capturing = true
	-- Also grab last-known immediately as a fallback.
	State.aim = { x = State.lastAim.x, y = State.lastAim.y }
	btnCapture.Text = "📍  Captured: " .. math.floor(State.aim.x) .. "," .. math.floor(State.aim.y)
	task.delay(1.5, function()
		btnCapture.Text = "📍  Lock Aim (point first)"
	end)
	saveCfg()
end)

btnWalk.MouseButton1Click:Connect(function()
	State.walk = (State.walk == 0 and -1) or (State.walk == -1 and 1) or 0
	btnWalk.Text = "Walk: " .. (State.walk == 0 and "Off" or (State.walk < 0 and "◀ Left" or "Right ▶"))
	saveCfg()
end)

capBox.FocusLost:Connect(function()
	local n = tonumber(capBox.Text)
	if n and n > 0 then
		State.cap = math.min(n, HARD_CLAMP * 0.999)
		capBox.Text = tostring(State.cap)
	else
		capBox.Text = tostring(State.cap)
	end
	saveCfg()
end)

btnRevive.MouseButton1Click:Connect(function()
	State.autoRevive = not State.autoRevive
	btnRevive.Text = "Auto-revive: " .. (State.autoRevive and "ON" or "OFF")
	saveCfg()
end)

btnIdle.MouseButton1Click:Connect(function()
	State.antiIdle = not State.antiIdle
	btnIdle.Text = "Anti-idle: " .. (State.antiIdle and "ON" or "OFF")
	saveCfg()
end)

btnRejoin.MouseButton1Click:Connect(function()
	State.autoRejoin = not State.autoRejoin
	btnRejoin.Text = "Auto-rejoin: " .. (State.autoRejoin and "ON" or "OFF")
	saveCfg()
end)

-- Minimize: hide body controls; the auto-sized panel shrinks to the title.
local bodyControls = {
	btnMaster, btnMode, btnAddPt, btnClearPt, btnSpeed, btnCapture, btnAdvance,
	btnWalk, btnRevive, btnIdle, btnRejoin, capBox, lblEmbers, lblStats, lblStatus,
}
local function setMinimized(v)
	State.minimized = v
	for _, c in ipairs(bodyControls) do c.Visible = not v end
	btnMin.Text = v and "+" or "–"
end
btnMin.MouseButton1Click:Connect(function() setMinimized(not State.minimized) end)

-- Hotkey: RightShift hides/shows the whole panel (desktop convenience).
UserInputService.InputBegan:Connect(function(input, gp)
	if not gp and input.KeyCode == Enum.KeyCode.RightShift then
		root.Visible = not root.Visible
	end
end)

--=====================================================================
--  8. STATUS LOOP
--=====================================================================
task.spawn(function()
	while gui.Parent do
		-- Embers readout + rate + session earned + cap enforcement.
		local e = readEmbers()
		if e then
			State.embers = e
			if State.startEmbers == nil then State.startEmbers = e end
			-- Rolling embers/sec over the sample gap.
			local now = os.clock()
			if State._rE ~= nil and now > State._rT then
				State.rate = (e - State._rE) / (now - State._rT)
			end
			State._rE, State._rT = e, now

			lblEmbers.Text = "Embers: " .. fmt(e) .. "  /  cap " .. fmt(State.cap)
			lblStats.Text = string.format("+%s/s · session +%s · rounds %d",
				fmt(math.max(0, State.rate)),
				fmt(math.max(0, e - (State.startEmbers or e))),
				State.rounds)

			if State.on and e >= State.cap then
				setMaster(false)
				lblStatus.Text = "Status: reached cap — stopped ✅"
			end
		else
			lblEmbers.Text = "Embers: (enter a round to read)"
			lblStats.Text  = "rounds " .. State.rounds
		end

		if not State.on then
			if State.installed then
				if not (lblStatus.Text:find("cap")) then
					lblStatus.Text = "Status: idle · hook ready"
				end
			else
				lblStatus.Text = "Status: searching for game…"
			end
		else
			local pend = 0
			if Found.recorder then
				local ok, p = pcall(Found.recorder.pendingTicks)
				if ok then pend = p end
			end
			local act = (State.phase == "round") and "FEEDING"
				or (State.phase == "cutscene" and State.advance) and "SKIPPING"
				or "WAITING"
			local extra = ""
			if State.mode == "points" and #State.points > 0 then
				extra = string.format(" · pt %d/%d", State.ptIdx, #State.points)
			end
			lblStatus.Text = string.format(
				"%s · %s%s · pend %d", act, State.phase, extra, pend)
		end
		task.wait(0.5)
	end
end)

--=====================================================================
--  8b. LOAD SETTINGS · ANTI-IDLE · AUTO-REJOIN
--=====================================================================
loadCfg()

-- Anti-idle: defeat the ~20-minute AFK disconnect by nudging VirtualUser.
pcall(function()
	local VirtualUser = game:GetService("VirtualUser")
	LocalPlayer.Idled:Connect(function()
		if State.antiIdle then
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new())
			end)
		end
	end)
end)

-- Auto-rejoin (best-effort, varies by executor): when the disconnect prompt
-- appears, teleport back into the same place. Only scans while enabled.
task.spawn(function()
	local TeleportService = game:GetService("TeleportService")
	local CoreGui = game:GetService("CoreGui")
	while task.wait(3) do
		if State.autoRejoin then
			local disc = false
			pcall(function()
				for _, g in ipairs(CoreGui:GetDescendants()) do
					if g:IsA("TextLabel") or g:IsA("TextButton") then
						local t = string.lower(tostring(g.Text))
						if t:find("disconnect") or t:find("lost connection")
							or t:find("reconnect") or t:find("rejoin") then
							disc = true
							break
						end
					end
				end
			end)
			if disc then
				pcall(function()
					TeleportService:Teleport(game.PlaceId, LocalPlayer)
				end)
				task.wait(10) -- let the teleport resolve; don't spam
			end
		end
	end
end)

--=====================================================================
--  9. BOOT  (retry discovery until the Host is up & you're in a round)
--=====================================================================
task.spawn(function()
	lblStatus.Text = "Status: searching for game…"
	local tries = 0
	while not (Found.recorder and Found.remote) and tries < 120 do
		pcall(discover)
		if Found.recorder and Found.remote then break end
		tries += 1
		task.wait(1)
	end
	if Found.recorder and Found.remote then
		installHook()
		lblStatus.Text = Found.sim
			and "Status: ready ✅  (press START)"
			or  "Status: ready ✅ (no embers readout)"
	else
		lblStatus.Text = "Status: couldn't find the input stream ❌"
		btnMaster.Text = "unavailable"
	end
end)

-- Clean up the hook if the GUI is destroyed.
gui.Destroying:Connect(function()
	State.on = false
	pcall(uninstallHook)
end)

print("[Feed The Fire Autopilot] loaded. Enter a round, point at the fire, Lock Aim, START.")
