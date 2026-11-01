--[[
	IMPOSSIBLE ANIMALS — AUTO-EVERYTHING
	PlaceId 119929094294460 · Client-sided LocalScript · Delta (Android)

	HOW IT WORKS
	  This game is server-authoritative: every value change is a request
	  (RemoteFunction:InvokeServer(action, payload)) and the server decides.
	  So instead of forging packets, this script drives the game's OWN client
	  objects (found with getgc) and walks your character like a player would:

	  WILD FARM
	    • Attacks with the game's real WildController:attack() — it already
	      handles sequence numbers, target picking (nearest enemy in range,
	      same tier) and the Attack request. We only keep you in range.
	    • Claims are proximity-driven by the game itself: clear a biome, walk
	      to its goal → Claim; walk onto unlocked chests/eggs → ClaimChest /
	      ClaimEgg. The bot just paths there with Humanoid:MoveTo.
	    • Auto-start: enters The Wild and picks your hybrid. It LEARNS which
	      hybrid by watching the first time you pick one yourself.

	  HUB
	    • Auto pen upgrade (game's own upgrade(), only when you can afford it)
	    • Auto offline-earnings claim · Auto free gift · Anti-idle

	FIRST RUN: start the script, then enter The Wild once and pick a hybrid
	manually. After that it remembers and auto-starts runs on its own.
]]

--=====================================================================
-- 0. SERVICES / SHIMS
--=====================================================================
local Players      = game:GetService("Players")
local RS           = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local UIS          = game:GetService("UserInputService")
local HttpService  = game:GetService("HttpService")
local LP           = Players.LocalPlayer

local IA = RS:WaitForChild("ImpossibleAnimals", 30)
assert(IA, "[IA] ImpossibleAnimals folder not found — wrong game?")

local Remote = {
	Request = IA:WaitForChild("Request", 30),
	Wild    = IA:WaitForChild("WildRequest", 30),
	Shop    = IA:WaitForChild("ShopRequest", 30),
}

local G             = (getgenv and getgenv()) or _G
local _getgc        = getgc or G.getgc
local _getupvalues  = getupvalues or G.getupvalues or (debug and debug.getupvalues)
local _getupvalue   = getupvalue or G.getupvalue or (debug and debug.getupvalue)
local _hookmm       = hookmetamethod or G.hookmetamethod
local _getncm       = getnamecallmethod or G.getnamecallmethod
local _newcc        = newcclosure or G.newcclosure or function(f) return f end
local _gethui       = gethui or G.gethui
local _protectgui   = (syn and syn.protect_gui) or protect_gui or G.protect_gui
local _writefile    = writefile or G.writefile
local _readfile     = readfile or G.readfile
local _isfile       = isfile or G.isfile

assert(_getgc, "[IA] getgc not available on this executor")

local function upvals(fn)
	if _getupvalues then
		local ok, u = pcall(_getupvalues, fn)
		if ok and type(u) == "table" then return u end
	end
	local out = {}
	if _getupvalue then
		for i = 1, 200 do
			local ok, v = pcall(_getupvalue, fn, i)
			if not ok or v == nil then break end
			out[i] = v
		end
	end
	return out
end

local function rg(t, k)
	local ok, v = pcall(rawget, t, k)
	if ok then return v end
	return nil
end

local function safeRequire(name)
	local mod = IA:FindFirstChild(name)
	if not mod then return nil end
	local ok, m = pcall(require, mod)
	if ok then return m end
	return nil
end

local WildRules  = safeRequire("WildRules")
local PenEconomy = safeRequire("PenEconomy")
local Income     = safeRequire("CreatureIncome")
local Money      = Income and Income.Money
local ATTACK_RANGE = (WildRules and tonumber(WildRules.ATTACK_RANGE)) or 10

--=====================================================================
-- 1. STATE / CONFIG
--=====================================================================
local S = {
	on        = false,
	wild      = true,   -- fight + path in runs
	autoStart = true,   -- enter The Wild and pick the remembered hybrid
	restart   = true,   -- leave + restart once a run is fully cleared
	loot      = true,   -- walk to unlocked chests / eggs
	pen       = true,   -- auto pen upgrade when affordable
	offline   = true,   -- claim offline earnings
	gift      = true,   -- redeem the free gift when available
	antiIdle  = true,
	hybridId  = nil,    -- learned from your first manual pick
	action    = "idle",
	minimized = false,
}

local CFG = "ia_autofarm.json"
local SAVE_KEYS = { "wild", "autoStart", "restart", "loot", "pen", "offline", "gift", "antiIdle", "hybridId" }

local function saveCfg()
	if not _writefile then return end
	local d = {}
	for _, k in ipairs(SAVE_KEYS) do d[k] = S[k] end
	pcall(function() _writefile(CFG, HttpService:JSONEncode(d)) end)
end

local function loadCfg()
	if not _readfile then return end
	local ok, raw = pcall(function()
		if _isfile and not _isfile(CFG) then return nil end
		return _readfile(CFG)
	end)
	if not (ok and type(raw) == "string") then return end
	local ok2, d = pcall(function() return HttpService:JSONDecode(raw) end)
	if not (ok2 and type(d) == "table") then return end
	for _, k in ipairs(SAVE_KEYS) do
		if k == "hybridId" then
			if type(d[k]) == "string" or type(d[k]) == "number" then S[k] = d[k] end
		elseif type(d[k]) == "boolean" then
			S[k] = d[k]
		end
	end
end
loadCfg()

--=====================================================================
-- 2. FIND THE GAME'S OWN OBJECTS (getgc)
--=====================================================================
local F = { W = nil, C = nil, E = nil, P = nil, pick = nil }

local function isW(t) -- WildUI state object
	return type(rg(t, "predictRescue")) == "function" and type(rg(t, "setPage")) == "function"
end
local function isC(t) -- WildController (matched by its method set)
	return type(rg(t, "attack")) == "function"
		and type(rg(t, "confirmStart")) == "function"
		and type(rg(t, "setHealth")) == "function"
end
local function isE(t) -- EconomyUI object
	local d = rg(t, "data")
	return type(rg(t, "upgrade")) == "function" and type(d) == "table" and d.penLevel ~= nil
end
local function isP(t) -- WildPicker object
	return type(rg(t, "single")) == "table" and type(rg(t, "open")) == "function"
		and rg(t, "visible") ~= nil
end

local function scan()
	local ok, gc = pcall(_getgc, true)
	if not ok or type(gc) ~= "table" then return end
	for _, v in ipairs(gc) do
		if type(v) == "table" then
			if not F.W and isW(v) then F.W = v
			elseif not F.C and isC(v) then F.C = v
			elseif not F.E and isE(v) then F.E = v
			elseif not F.P and isP(v) then F.P = v
			end
		end
	end
	-- The picker's local `pick(id)` closure: matched by its debug name + upvalue.
	if F.P and not F.pick and debug and debug.info then
		for _, v in ipairs(gc) do
			if type(v) == "function" then
				local okn, n = pcall(debug.info, v, "n")
				if okn and n == "pick" then
					for _, u in pairs(upvals(v)) do
						if u == F.P then F.pick = v break end
					end
					if F.pick then break end
				end
			end
		end
	end
end

local function allFound()
	return F.W and F.C and F.E and F.P and F.pick
end

--=====================================================================
-- 3. LEARN YOUR HYBRID (read-only __namecall watch on WildRequest)
--=====================================================================
if _hookmm and _getncm then
	local old
	old = _hookmm(game, "__namecall", _newcc(function(self, ...)
		if self == Remote.Wild then
			local m = _getncm()
			if m == "InvokeServer" then
				local a, b = ...
				if a == "Ready" and type(b) == "table" and b[1] ~= nil and b[1] ~= S.hybridId then
					local id = b[1]
					task.defer(function()
						S.hybridId = id
						saveCfg()
					end)
				end
			end
		end
		return old(self, ...)
	end))
end

--=====================================================================
-- 4. CHARACTER / MOVEMENT
--=====================================================================
local function getChar()
	local ch = F.W and F.W.runCharacter
	if typeof(ch) ~= "Instance" or not ch.Parent then ch = LP.Character end
	if not ch then return nil end
	return ch, ch:FindFirstChildOfClass("Humanoid"), ch:FindFirstChild("HumanoidRootPart")
end

local function flatDist(a, b)
	local d = a - b
	return Vector3.new(d.X, 0, d.Z).Magnitude
end

local stuck = { pos = nil, t = 0 }
local function moveTo(hum, hrp, pos)
	hum:MoveTo(pos)
	local now = os.clock()
	if stuck.pos and (hrp.Position - stuck.pos).Magnitude < 1 then
		if now - stuck.t > 1.5 then
			hum.Jump = true -- hop over whatever we're snagged on
			stuck.t = now
		end
	else
		stuck.pos, stuck.t = hrp.Position, now
	end
end

--=====================================================================
-- 5. WILD FARM
--=====================================================================
local function lootTargets(vis, my)
	local best, bestD = nil, math.huge
	for _, grp in ipairs({ vis.chests, vis.eggs }) do
		if type(grp) == "table" and type(grp.items) == "table" then
			local collected = grp.collected or {}
			for id, it in pairs(grp.items) do
				if it.unlocked and not collected[id] and typeof(it.model) == "Instance" then
					local ok, p = pcall(function() return it.model:GetPivot().Position end)
					if ok then
						local d = flatDist(p, my)
						if d < bestD then best, bestD = p, d end
					end
				end
			end
		end
	end
	return best, bestD
end

-- Returns an action string, or nil when you're not in a run.
local function wildStep()
	local W = F.W
	if not W then return "finding WildUI…" end
	if W.page ~= "run" or not W.run or not W.visuals then return nil end
	local vis, run = W.visuals, W.run

	local _, hum, hrp = getChar()
	if not (hum and hrp) or hum.Health <= 0 then return "waiting for character" end
	local my = hrp.Position

	-- Enemies (non-owner units with health) + alive count per tier.
	local eBest, eD, alive = nil, math.huge, {}
	if type(vis.units) == "table" then
		for _, u in pairs(vis.units) do
			local desc, st = u.description, u.state
			if desc and st and not desc.owner and (st.health or 0) > 0
				and typeof(u.position) == "Vector3" then
				local tier = desc.tier or 0
				alive[tier] = (alive[tier] or 0) + 1
				local d = flatDist(u.position, my)
				if d < eD then eBest, eD = u.position, d end
			end
		end
	end

	-- Biome goals that are cleared but not yet rescued.
	local gBest, gD = nil, math.huge
	local plan = vis.plan
	if type(plan) == "table" and type(plan.biomes) == "table" then
		for i, b in ipairs(plan.biomes) do
			local claimed = false
			if WildRules and WildRules.rewardClaimed then
				local ok, c = pcall(WildRules.rewardClaimed, run.cycle, "animal", i)
				claimed = ok and c == true
			end
			if not claimed and (alive[i] or 0) == 0 and typeof(b.goal) == "Vector3" then
				local d = flatDist(b.goal, my)
				if d < gD then gBest, gD = b.goal, d end
			end
		end
	end

	local lBest, lD = nil, math.huge
	if S.loot then lBest, lD = lootTargets(vis, my) end

	-- Swing whenever something's in range (attack() self-gates at 0.4s).
	if eBest and eD <= ATTACK_RANGE and F.C and F.C.run then
		pcall(F.C.attack, F.C)
	end

	-- Priority: nearby loot > enemies > rescue goal > far loot.
	if lBest and lD < 35 then
		moveTo(hum, hrp, lBest); return "looting"
	elseif eBest then
		if eD > ATTACK_RANGE - 2 then moveTo(hum, hrp, eBest) else hum:MoveTo(my) end
		return "fighting"
	elseif gBest then
		moveTo(hum, hrp, gBest); return "rescuing"
	elseif lBest then
		moveTo(hum, hrp, lBest); return "looting"
	end
	return "cleared"
end

local lastStart = 0
local function tryStartRun()
	local W = F.W
	if not W then return "finding WildUI…" end
	if W.startPrediction or W.pendingReady or W.pendingCreate then return "starting run…" end
	if S.hybridId == nil then return "pick a hybrid once (I'll remember it)" end
	if os.clock() - lastStart < 12 then return "waiting to start" end
	lastStart = os.clock()

	task.spawn(function()
		pcall(function() W:create(true) end) -- same call the game's own button makes
		local t0 = os.clock()
		while os.clock() - t0 < 8 do
			if W.page == "run" and W.run then return end
			if F.P and F.P.visible then break end
			task.wait(0.2)
		end
		if F.P and not F.P.visible then
			pcall(function() F.P:open(false) end)
			task.wait(0.5)
		end
		if F.pick and F.P and F.P.visible then
			pcall(F.pick, S.hybridId) -- the picker's own pick(): sends Ready + updates UI
		else
			pcall(function() Remote.Wild:InvokeServer("Ready", { S.hybridId }) end)
		end
	end)
	return "starting run"
end

local clearedSince = nil
local function leaveRun()
	task.spawn(function()
		local W = F.W
		if W and type(W.call) == "function" then
			pcall(W.call, "Leave", nil)
		else
			pcall(function() Remote.Wild:InvokeServer("Leave") end)
		end
	end)
end

--=====================================================================
-- 6. HUB AUTOMATION
--=====================================================================
local lastPen = 0
local function penStep()
	local E = F.E
	if not (E and type(E.data) == "table" and PenEconomy and Money) then return end
	if os.clock() - lastPen < 2 or E.busy or not E.world then return end
	local okP, price = pcall(PenEconomy.nextPrice, E.data.penLevel)
	if not okP or not price then return end -- maxed or unknown
	local okL, poor = pcall(Money.lt, E.data.cash, price)
	if okL and not poor then
		lastPen = os.clock()
		pcall(E.upgrade, E)
	end
end

local lastOffline = -1e9
local function offlineStep()
	if os.clock() - lastOffline < 300 then return end
	lastOffline = os.clock()
	task.spawn(function()
		pcall(function() Remote.Request:InvokeServer("OfflineChoice", { choice = "claim" }) end)
	end)
end

local lastGift = -1e9
local function giftStep()
	if os.clock() - lastGift < 120 then return end
	lastGift = os.clock()
	task.spawn(function()
		local ok, snap = pcall(function() return Remote.Shop:InvokeServer("FreeSnapshot") end)
		if ok and type(snap) == "table" and snap.ok and not snap.claimed
			and type(snap.offer) == "table" and snap.offer.id ~= nil then
			pcall(function() Remote.Shop:InvokeServer("RedeemFree", { offerId = snap.offer.id }) end)
		end
	end)
end

--=====================================================================
-- 7. GUI (mobile-friendly, draggable, minimizable)
--=====================================================================
local gui = Instance.new("ScreenGui")
gui.Name, gui.ResetOnSpawn, gui.IgnoreGuiInset = "IA_Autofarm", false, true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
pcall(function() if _protectgui then _protectgui(gui) end end)
gui.Parent = (_gethui and _gethui()) or LP:WaitForChild("PlayerGui")

local root = Instance.new("Frame")
root.Position = UDim2.fromOffset(16, 90)
root.Size = UDim2.fromOffset(250, 0)
root.AutomaticSize = Enum.AutomaticSize.Y
root.BackgroundColor3 = Color3.fromRGB(16, 20, 18)
root.BorderSizePixel = 0
root.Active = true
root.Parent = gui
Instance.new("UICorner", root).CornerRadius = UDim.new(0, 12)
local stroke = Instance.new("UIStroke", root)
stroke.Color, stroke.Thickness = Color3.fromRGB(110, 220, 140), 1.5
local pad = Instance.new("UIPadding", root)
pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 10), UDim.new(0, 10)
local list = Instance.new("UIListLayout", root)
list.SortOrder, list.Padding = Enum.SortOrder.LayoutOrder, UDim.new(0, 5)

local order = 0
local function nextOrder() order += 1; return order end

local title = Instance.new("TextLabel")
title.LayoutOrder = nextOrder()
title.Size = UDim2.new(1, 0, 0, 24)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(150, 235, 170)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "🦁 Impossible Animals — Auto"
title.Active = true
title.Parent = root

local btnMin = Instance.new("TextButton")
btnMin.AnchorPoint, btnMin.Position = Vector2.new(1, 0.5), UDim2.new(1, 0, 0.5, 0)
btnMin.Size = UDim2.fromOffset(24, 20)
btnMin.BackgroundColor3 = Color3.fromRGB(36, 44, 40)
btnMin.Font, btnMin.TextSize = Enum.Font.GothamBold, 14
btnMin.TextColor3, btnMin.Text = Color3.fromRGB(240, 240, 240), "–"
btnMin.BorderSizePixel = 0
btnMin.Parent = title
Instance.new("UICorner", btnMin).CornerRadius = UDim.new(0, 6)

local body = {}
local function mkButton(text, color)
	local b = Instance.new("TextButton")
	b.LayoutOrder = nextOrder()
	b.Size = UDim2.new(1, 0, 0, 30)
	b.BackgroundColor3 = color or Color3.fromRGB(36, 44, 40)
	b.Font, b.TextSize = Enum.Font.GothamSemibold, 13
	b.TextColor3, b.Text = Color3.fromRGB(240, 240, 240), text
	b.BorderSizePixel = 0
	b.Parent = root
	Instance.new("UICorner", b).CornerRadius = UDim.new(0, 8)
	table.insert(body, b)
	return b
end
local function mkLabel()
	local l = Instance.new("TextLabel")
	l.LayoutOrder = nextOrder()
	l.Size = UDim2.new(1, 0, 0, 16)
	l.BackgroundTransparency = 1
	l.Font, l.TextSize = Enum.Font.Gotham, 12
	l.TextColor3 = Color3.fromRGB(190, 205, 195)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.Text = ""
	l.Parent = root
	table.insert(body, l)
	return l
end

local btnMaster = mkButton("▶  START", Color3.fromRGB(32, 90, 50))

local toggles = {}
local function mkToggle(label, key)
	local b = mkButton("")
	local function paint() b.Text = label .. ": " .. (S[key] and "ON" or "OFF") end
	paint()
	b.MouseButton1Click:Connect(function()
		S[key] = not S[key]
		paint()
		saveCfg()
	end)
	toggles[key] = paint
	return b
end

mkToggle("Wild farm", "wild")
mkToggle("Auto-start runs", "autoStart")
mkToggle("Restart when cleared", "restart")
mkToggle("Collect chests/eggs", "loot")
mkToggle("Auto pen upgrade", "pen")
mkToggle("Auto offline claim", "offline")
mkToggle("Auto free gift", "gift")
mkToggle("Anti-idle", "antiIdle")
local btnForget = mkButton("🔄 Forget remembered hybrid")

local lblStatus = mkLabel()
local lblFound  = mkLabel()
local lblHybrid = mkLabel()
local lblCash   = mkLabel()

btnMaster.MouseButton1Click:Connect(function()
	S.on = not S.on
	btnMaster.Text = S.on and "⏸  STOP" or "▶  START"
	btnMaster.BackgroundColor3 = S.on and Color3.fromRGB(120, 40, 40) or Color3.fromRGB(32, 90, 50)
	if not S.on then
		local _, hum, hrp = getChar()
		if hum and hrp then pcall(function() hum:MoveTo(hrp.Position) end) end
	end
end)

btnForget.MouseButton1Click:Connect(function()
	S.hybridId = nil
	saveCfg()
end)

btnMin.MouseButton1Click:Connect(function()
	S.minimized = not S.minimized
	for _, c in ipairs(body) do c.Visible = not S.minimized end
	btnMin.Text = S.minimized and "+" or "–"
end)

UIS.InputBegan:Connect(function(input, gp)
	if not gp and input.KeyCode == Enum.KeyCode.RightShift then
		root.Visible = not root.Visible
	end
end)

do -- drag (touch + mouse)
	local dragging, startIn, startPos
	title.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			dragging, startIn, startPos = true, input.Position, root.Position
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then dragging = false end
			end)
		end
	end)
	UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
			or input.UserInputType == Enum.UserInputType.Touch) then
			local d = input.Position - startIn
			root.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
				startPos.Y.Scale, startPos.Y.Offset + d.Y)
		end
	end)
end

--=====================================================================
-- 8. ANTI-IDLE
--=====================================================================
pcall(function()
	local VirtualUser = game:GetService("VirtualUser")
	LP.Idled:Connect(function()
		if S.antiIdle then
			pcall(function()
				VirtualUser:CaptureController()
				VirtualUser:ClickButton2(Vector2.new())
			end)
		end
	end)
end)

--=====================================================================
-- 9. MAIN LOOP (10 Hz decisions)
--=====================================================================
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	if not S.on then return end
	acc += dt
	if acc < 0.1 then return end
	acc = 0

	local status = "idle"
	if S.wild then
		local ok, res = pcall(wildStep)
		if not ok then
			status = "wild error"
		elseif res == nil then
			clearedSince = nil
			if S.autoStart then
				local ok2, r2 = pcall(tryStartRun)
				status = ok2 and r2 or "start error"
			else
				status = "not in a run"
			end
		else
			status = res
			if res == "cleared" then
				clearedSince = clearedSince or os.clock()
				if S.restart and os.clock() - clearedSince > 8 then
					clearedSince = nil
					leaveRun()
					status = "run cleared — restarting"
				end
			else
				clearedSince = nil
			end
		end
	end
	if S.pen then pcall(penStep) end
	if S.offline then pcall(offlineStep) end
	if S.gift then pcall(giftStep) end
	S.action = status
end)

--=====================================================================
-- 10. STATUS + RESCAN
--=====================================================================
local function mark(x) return x and "✓" or "✗" end
task.spawn(function()
	local lastScan = -1e9
	while gui.Parent do
		if not allFound() and os.clock() - lastScan > 10 then
			lastScan = os.clock()
			pcall(scan)
		end
		lblStatus.Text = "Status: " .. (S.on and S.action or "stopped")
		lblFound.Text = string.format("Wild %s · Ctrl %s · Econ %s · Picker %s/%s",
			mark(F.W), mark(F.C), mark(F.E), mark(F.P), mark(F.pick))
		lblHybrid.Text = "Hybrid: " .. (S.hybridId ~= nil and tostring(S.hybridId)
			or "pick one manually once")
		local cash = F.E and type(F.E.data) == "table" and F.E.data.cash
		lblCash.Text = "Cash: " .. (cash ~= nil and tostring(cash) or "?")
			.. (F.E and type(F.E.data) == "table" and ("  ·  Pen " .. tostring(F.E.data.penLevel)) or "")
		task.wait(0.5)
	end
end)

print("[IA Auto] loaded — press START. First time: enter The Wild and pick a hybrid once.")
