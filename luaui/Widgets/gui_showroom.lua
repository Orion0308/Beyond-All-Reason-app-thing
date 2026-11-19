local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Showroom",
		desc = "Unit showroom: a close-up orbit camera on the staged units, a stats panel, and the controls for inspect, target practice and duels",
		author = "Orion",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 1000000, -- above the game interface, which it hides anyway
		enabled = true,
	}
end

-- The UNSYNCED half of the unit showroom (the gadget is luarules/gadgets/game_showroom.lua, the
-- shared protocol common/showroom.lua, the walkthrough doc/Showroom.md).
--
-- A widget cannot create units or decide who shoots; it ASKS the gadget with
-- Spring.SendLuaRulesMsg and READS the answer from game rules params. What it owns is the
-- presentation: the camera, the panel, and the player's input.
--
-- Not gated through the enabled field, for the reason cmd_map_editor_session.lua gives: once a
-- normal game saves the widget as off, the field is never read again. Stopping the file here
-- means an ordinary game defines no call-ins and pays nothing.
local Showroom = VFS.Include("common/showroom.lua")

if not Showroom.IsSession(Spring.GetModOptions()) then
	return
end

local CameraMath = VFS.Include("common/camera_math.lua")
local weaponsLib = require("common/weapons")

local spGetGameRulesParam = Spring.GetGameRulesParam
local spGetUnitPosition = Spring.GetUnitPosition
local spGetUnitDefID = Spring.GetUnitDefID
local spGetUnitHealth = Spring.GetUnitHealth
local spValidUnitID = Spring.ValidUnitID
local spGetGroundHeight = Spring.GetGroundHeight
local spSetCameraState = Spring.SetCameraState
local spSendLuaRulesMsg = Spring.SendLuaRulesMsg
local spGetConfigInt = Spring.GetConfigInt
local spSetConfigInt = Spring.SetConfigInt

local glColor = gl.Color
local glRect = gl.Rect

local max, min, exp, rad, floor = math.max, math.min, math.exp, math.rad, math.floor

--------------------------------------------------------------------------------
-- Settings: the knobs to tune the feel
--------------------------------------------------------------------------------

local HIDE_REASON = "showroom"
local FPS_CAMERA_MODE = 0
local CLAMP_CONFIG = "FPSClampPos" -- the fps camera is kept inside the map unless this is 0

local CAMERA = {
	fov = 38, -- degrees; narrower than the game's 45 for a "product shot" look
	pitch = rad(18), -- looking down by this much (0 = level, pi/2 = straight down)
	minPitch = rad(2),
	maxPitch = rad(80),
	yaw = 0, -- compass bearing: 0 looks north, so the west subject is on the LEFT, the target on the RIGHT
	dragSpeed = 0.006, -- radians per pixel
	zoomStep = 0.12, -- share of the distance per wheel notch
	followRate = 4, -- how quickly the focus catches a moving unit (1/seconds); higher = stiffer
	autoRotate = 0.12, -- radians per second when idle-spinning a lone unit
	minClearance = 15, -- elmos the eye stays above the ground
}

local PANEL = {
	heightShare = 0.30, -- of the screen height
	background = { 0.04, 0.05, 0.07, 0.86 },
	line = { 1, 1, 1, 0.08 },
	text = "\255\220\225\235",
	dim = "\255\140\145\155",
	win = "\255\120\235\140",
	lose = "\255\235\130\120",
	button = { 0.15, 0.17, 0.22, 0.95 },
	buttonActive = { 0.25, 0.45, 0.75, 0.95 },
	buttonHover = { 0.22, 0.25, 0.32, 0.95 },
}

--- Matchups the < > keys step through. Any unit names work with /showroom <unit> [target].
local PRESETS = {
	{ "armpw", "corak" },
	{ "armwar", "corthud" },
	{ "armstump", "corraid" },
	{ "armflash", "corgator" },
	{ "armham", "legcen" },
	{ "armbull", "correap" },
	{ "armfido", "cormort" },
	{ "armsnipe", "corsumo" },
	{ "armllt", "corak" },
	{ "corvamp", Showroom.NONE },
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local vsx, vsy = Spring.GetViewGeometry()
local font
local savedClamp

local camera = {
	yaw = CAMERA.yaw,
	pitch = CAMERA.pitch,
	distance = 600,
	focus = nil, ---@type { x: number, y: number, z: number }?
	dragging = false,
	spin = false, -- idle auto-rotate
}

local view = {
	subjectID = -1,
	targetID = -1,
	subjectDefID = nil, ---@type integer?
	targetDefID = nil, ---@type integer?
	mode = "inspect",
	result = "",
	revision = -1,
	presetIndex = 1,
	stats = nil, ---@type { subject: table, target: table? }?
	mouseX = 0,
	mouseY = 0,
}

local buttons = {} -- filled each draw: { x1, y1, x2, y2, action = function, active = bool, label }

--------------------------------------------------------------------------------
-- Talking to the gadget
--------------------------------------------------------------------------------

local function send(command, ...)
	spSendLuaRulesMsg(Showroom.Encode(command, ...))
end

local function stagePreset(index)
	view.presetIndex = ((index - 1) % #PRESETS) + 1
	local preset = PRESETS[view.presetIndex]
	send("stage", preset[1], preset[2])
end

--- Reads what the gadget published. Cheap enough to do every frame: a handful of table reads.
local function readArena()
	local revision = spGetGameRulesParam(Showroom.PARAM.revision) or 0
	view.subjectID = spGetGameRulesParam(Showroom.PARAM.subject) or -1
	view.targetID = spGetGameRulesParam(Showroom.PARAM.target) or -1
	view.mode = spGetGameRulesParam(Showroom.PARAM.mode) or "inspect"
	view.result = spGetGameRulesParam(Showroom.PARAM.result) or ""
	if revision ~= view.revision then
		view.revision = revision
		return true -- a new stage: re-frame the camera and recompute stats
	end
	return false
end

--------------------------------------------------------------------------------
-- Stats
--------------------------------------------------------------------------------

local function computeStats()
	view.subjectDefID = view.subjectID >= 0 and spGetUnitDefID(view.subjectID) or nil
	view.targetDefID = view.targetID >= 0 and spGetUnitDefID(view.targetID) or nil
	if not view.subjectDefID then
		view.stats = nil
		return
	end
	local subjectDef = UnitDefs[view.subjectDefID]
	local targetDef = view.targetDefID and UnitDefs[view.targetDefID]
	-- DPS is worked out against the OTHER unit's armor class, so "vs other" is the real number.
	view.stats = {
		subject = Showroom.UnitStats(subjectDef, WeaponDefs, weaponsLib, targetDef and targetDef.armorType),
		target = targetDef and Showroom.UnitStats(targetDef, WeaponDefs, weaponsLib, subjectDef.armorType) or nil,
	}
end

--------------------------------------------------------------------------------
-- Camera
--------------------------------------------------------------------------------

--- The point the camera looks at: the middle of whichever staged units are alive.
local function arenaCentre()
	local sx, sy, sz, n = 0, 0, 0, 0
	for _, unitID in ipairs({ view.subjectID, view.targetID }) do
		if unitID >= 0 and spValidUnitID(unitID) then
			local x, y, z = spGetUnitPosition(unitID)
			if x then
				sx, sy, sz, n = sx + x, sy + y, sz + z, n + 1
			end
		end
	end
	if n == 0 then
		return nil
	end
	return { x = sx / n, y = sy / n + 20, z = sz / n }
end

--- A distance that frames what is on stage: a lone unit by its size, a pair by their spacing.
local function framingDistance()
	local radius = 30
	for _, defID in ipairs({ view.subjectDefID or -1, view.targetDefID or -1 }) do
		if UnitDefs[defID] then
			radius = max(radius, UnitDefs[defID].radius or 30)
		end
	end
	local spread = 0
	if
		view.subjectID >= 0
		and view.targetID >= 0
		and spValidUnitID(view.subjectID)
		and spValidUnitID(view.targetID)
	then
		local ax, _, az = spGetUnitPosition(view.subjectID)
		local bx, _, bz = spGetUnitPosition(view.targetID)
		spread = math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
	end
	return max(radius * 7, spread * 1.05 + radius * 4)
end

local function applyCamera(dt)
	local wanted = arenaCentre()
	if not wanted then
		return
	end
	-- Ease the focus toward the units instead of snapping: frame-rate independent smoothing.
	if not camera.focus then
		camera.focus = wanted
	else
		local k = 1 - exp(-CAMERA.followRate * dt)
		local f = camera.focus
		f.x, f.y, f.z = f.x + (wanted.x - f.x) * k, f.y + (wanted.y - f.y) * k, f.z + (wanted.z - f.z) * k
	end
	if camera.spin and not camera.dragging then
		camera.yaw = camera.yaw + CAMERA.autoRotate * dt
	end

	local f = camera.focus
	local ex, ey, ez = CameraMath.EyeFromTarget(f.x, f.y, f.z, camera.pitch, camera.yaw, camera.distance)
	-- Never under the ground: lift the eye and re-aim it at the focus.
	ey = max(ey, spGetGroundHeight(ex, ez) + CAMERA.minClearance)
	local rx, ry = CameraMath.LookAtRotation(ex, ey, ez, f.x, f.y, f.z, camera.yaw)
	local dx, dy, dz = CameraMath.FwdFromRot(rx, ry)
	spSetCameraState({
		name = "fps",
		mode = FPS_CAMERA_MODE,
		px = ex,
		py = ey,
		pz = ez,
		dx = dx,
		dy = dy,
		dz = dz,
		rx = rx,
		ry = ry,
		rz = 0,
		fov = CAMERA.fov,
	}, 0)
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function panelTop()
	return floor(vsy * PANEL.heightShare)
end

local function setMode(mode)
	send("mode", mode)
end

local function addButton(x1, y1, x2, y2, label, action, active)
	buttons[#buttons + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, label = label, action = action, active = active }
end

local function buttonAt(x, y)
	for _, b in ipairs(buttons) do
		if x >= b.x1 and x <= b.x2 and y >= b.y1 and y <= b.y2 then
			return b
		end
	end
end

local function layoutButtons(top, size)
	buttons = {}
	local h = size * 2.2
	local w = size * 7.5
	local gap = size * 0.6
	local y2 = top - size * 0.8
	local y1 = y2 - h
	local x = vsx - (w + gap) * 6 - gap
	local entries = {
		{
			"Inspect [1]",
			function()
				setMode("inspect")
			end,
			view.mode == "inspect",
		},
		{
			"Target [2]",
			function()
				setMode("target")
			end,
			view.mode == "target",
		},
		{
			"Duel [3]",
			function()
				setMode("duel")
			end,
			view.mode == "duel",
		},
		{
			"Reset [R]",
			function()
				send("reset")
			end,
			false,
		},
		{
			"< Prev [",
			function()
				stagePreset(view.presetIndex - 1)
			end,
			false,
		},
		{
			"Next ] >",
			function()
				stagePreset(view.presetIndex + 1)
			end,
			false,
		},
	}
	for _, e in ipairs(entries) do
		addButton(x, y1, x + w, y2, e[1], e[2], e[3])
		x = x + w + gap
	end
end

local function healthText(unitID)
	if unitID < 0 or not spValidUnitID(unitID) then
		return PANEL.lose .. "destroyed"
	end
	local health, maxHealth = spGetUnitHealth(unitID)
	if not health then
		return ""
	end
	return string.format("%s%d / %d", PANEL.text, health, maxHealth)
end

local function resultText()
	local stats = view.stats
	if view.result == "" or not stats then
		return nil
	end
	if view.result == "draw" then
		return "Draw: both destroyed"
	end
	local winner = view.result == "subject" and stats.subject or stats.target
	return (winner and winner.name or "?") .. " wins"
end

local function drawPanel()
	local top = panelTop()
	local size = max(12, floor(vsy / 60))
	local pad = size * 1.5

	glColor(PANEL.background)
	glRect(0, 0, vsx, top)
	glColor(PANEL.line)
	glRect(0, top - 1, vsx, top)

	layoutButtons(top, size)
	for _, b in ipairs(buttons) do
		local hover = view.mouseX >= b.x1 and view.mouseX <= b.x2 and view.mouseY >= b.y1 and view.mouseY <= b.y2
		glColor(b.active and PANEL.buttonActive or hover and PANEL.buttonHover or PANEL.button)
		glRect(b.x1, b.y1, b.x2, b.y2)
	end
	glColor(1, 1, 1, 1)

	font:Begin()
	for _, b in ipairs(buttons) do
		font:Print(PANEL.text .. b.label, (b.x1 + b.x2) / 2, (b.y1 + b.y2) / 2 - size * 0.35, size, "c")
	end

	local stats = view.stats
	if not stats then
		font:Print(
			PANEL.dim .. "Waiting for the arena...  /showroom <unit> [target]",
			pad,
			top - pad * 1.5,
			size * 1.2,
			"o"
		)
		font:End()
		return
	end

	-- Header: names and live health
	local colLabel, colA, colB = pad, pad + size * 14, pad + size * 30
	local y = top - pad * 1.6
	font:Print(PANEL.dim .. "STATS", colLabel, y, size, "o")
	font:Print(PANEL.text .. stats.subject.name, colA, y, size * 1.25, "o")
	if stats.target then
		font:Print(PANEL.dim .. "vs", colA + size * 12, y, size, "o")
		font:Print(PANEL.text .. stats.target.name, colB, y, size * 1.25, "o")
	end
	y = y - size * 1.5
	font:Print(PANEL.dim .. "Live health", colLabel, y, size, "o")
	font:Print(healthText(view.subjectID), colA, y, size, "o")
	if stats.target then
		font:Print(healthText(view.targetID), colB, y, size, "o")
	end

	-- Rows: green where a unit is better, red where worse
	y = y - size * 0.6
	for _, row in ipairs(Showroom.ROWS) do
		y = y - size * 1.35
		if y < pad then
			break
		end
		local better = stats.target and Showroom.Better(row, stats.subject, stats.target)
		local ca = better == "a" and PANEL.win or better == "b" and PANEL.lose or PANEL.text
		local cb = better == "b" and PANEL.win or better == "a" and PANEL.lose or PANEL.text
		font:Print(PANEL.dim .. row.label, colLabel, y, size, "o")
		font:Print(ca .. string.format(row.format, stats.subject[row.key]), colA, y, size, "o")
		if stats.target then
			font:Print(cb .. string.format(row.format, stats.target[row.key]), colB, y, size, "o")
		end
	end

	-- Right side: the "on paper" duel and the real outcome
	if stats.target then
		local x = vsx - pad
		local ry = top - size * 5.5
		local ttkA = Showroom.TimeToKill(stats.subject, stats.target)
		local ttkB = Showroom.TimeToKill(stats.target, stats.subject)
		font:Print(PANEL.dim .. "On paper (every shot hits, point blank)", x, ry, size, "or")
		ry = ry - size * 1.4
		font:Print(
			PANEL.text .. stats.subject.name .. " kills in " .. (ttkA and string.format("%.1fs", ttkA) or "never"),
			x,
			ry,
			size,
			"or"
		)
		ry = ry - size * 1.3
		font:Print(
			PANEL.text .. stats.target.name .. " kills in " .. (ttkB and string.format("%.1fs", ttkB) or "never"),
			x,
			ry,
			size,
			"or"
		)
		local result = resultText()
		if result then
			ry = ry - size * 2.2
			font:Print(PANEL.win .. result, x, ry, size * 1.6, "or")
		end
	end

	font:Print(
		PANEL.dim .. "Drag: orbit   Wheel: zoom   O: auto-rotate   /showroom <unit> [target]",
		vsx - pad,
		pad * 0.6,
		size * 0.85,
		"or"
	)
	font:End()
end

--------------------------------------------------------------------------------
-- Commands and input
--------------------------------------------------------------------------------

-- /showroom armpw corak   or   /showroom armpw   (no target)
local function showroomCommand(_, line)
	local words = {}
	for word in tostring(line or ""):gmatch("%S+") do
		words[#words + 1] = word
	end
	if not words[1] then
		Spring.Echo("usage: /showroom <unit> [target]   e.g. /showroom armpw corak")
		return true
	end
	send("stage", words[1], words[2] or Showroom.NONE)
	return true
end

-- Key codes come from Spring.GetKeyCode(name). (KEYSYMS is NOT available to widgets: it is
-- not in luaui/system.lua, so reading it at load time kills the whole widget.) A key the
-- engine cannot resolve is skipped rather than breaking the table.
local KEY_ACTIONS = {}
local function bindKey(name, action)
	local code = Spring.GetKeyCode(name)
	if code and code > 0 then
		KEY_ACTIONS[code] = action
	end
end
bindKey("1", function()
	setMode("inspect")
end)
bindKey("2", function()
	setMode("target")
end)
bindKey("3", function()
	setMode("duel")
end)
bindKey("r", function()
	send("reset")
end)
bindKey("o", function()
	camera.spin = not camera.spin
end)
bindKey("[", function()
	stagePreset(view.presetIndex - 1)
end)
bindKey("]", function()
	stagePreset(view.presetIndex + 1)
end)

-- Keys are a convenience: the widget handler runs keybind ACTIONS before widget KeyPress, so a
-- key your keybind preset already uses never reaches here. The panel buttons always work.
function widget:KeyPress(key, mods, isRepeat)
	if isRepeat or mods.ctrl or mods.alt then
		return false -- leave chat, quit menu and engine shortcuts alone
	end
	local action = KEY_ACTIONS[key]
	if action then
		action()
		return true
	end
	return false
end

function widget:MousePress(x, y, button)
	if y < panelTop() then
		local b = buttonAt(x, y)
		if b and button == 1 then
			b.action()
		end
		return true -- the panel eats clicks: nothing behind it should get them
	end
	-- Above the panel is the stage: any button drags the orbit.
	camera.dragging = true
	camera.spin = false
	return true -- returning true makes this widget the mouse owner: MouseMove/Release come here
end

function widget:MouseMove(x, y, dx, dy)
	if camera.dragging then
		camera.yaw = camera.yaw + dx * CAMERA.dragSpeed
		camera.pitch = math.clamp(camera.pitch - dy * CAMERA.dragSpeed, CAMERA.minPitch, CAMERA.maxPitch)
	end
end

function widget:MouseRelease()
	camera.dragging = false
	return false
end

function widget:MouseWheel(up)
	local factor = up and (1 - CAMERA.zoomStep) or (1 + CAMERA.zoomStep)
	camera.distance = math.clamp(camera.distance * factor, 60, 4000)
	return true -- consumed: the game's camera must not zoom too
end

function widget:IsAbove(x, y)
	return true -- the whole screen is ours: no tooltips or clicks for hidden widgets
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function widget:ViewResize()
	vsx, vsy = Spring.GetViewGeometry()
	font = WG.fonts and WG.fonts.getFont() -- the game's shared font (luaui/Widgets/gui_fonthandler.lua)
end

function widget:Initialize()
	widget:ViewResize()
	-- Hide every other widget's screen drawing and input, keeping ours and the chat (so the
	-- /showroom command can be typed). Only game (zip/sdd) widgets get HideInterface; a copy in
	-- the user's LuaUI folder would not, so it still works there, just with the HUD showing.
	if widgetHandler.HideInterface then
		widgetHandler:HideInterface(HIDE_REASON, { "Showroom", "Chat" })
	end
	-- The fps camera is clamped inside the map unless this is off; the overlay flag (true)
	-- means the change is not saved to the player's springsettings.
	savedClamp = spGetConfigInt(CLAMP_CONFIG, 1)
	spSetConfigInt(CLAMP_CONFIG, 0, true)
	widgetHandler:AddAction("showroom", showroomCommand, nil, "t")
end

function widget:Shutdown()
	if widgetHandler.ShowInterface then
		widgetHandler:ShowInterface(HIDE_REASON)
	end
	if savedClamp then
		spSetConfigInt(CLAMP_CONFIG, savedClamp, true)
	end
	widgetHandler:RemoveAction("showroom", "t")
end

local requestedFirstStage = false

function widget:GameFrame()
	-- The first preset goes out once the game runs (the gadget only acts on messages in-game).
	if not requestedFirstStage then
		requestedFirstStage = true
		if (spGetGameRulesParam(Showroom.PARAM.subject) or -1) < 0 then
			stagePreset(1)
		end
	end
end

function widget:Update(dt)
	view.mouseX, view.mouseY = Spring.GetMouseState()
	if readArena() then
		computeStats()
		camera.focus = nil
		camera.distance = framingDistance()
		camera.spin = view.targetID < 0 -- a lone unit turns on the turntable by default
	elseif view.stats == nil and view.subjectID >= 0 then
		computeStats() -- the unit appears a frame after the revision when the message raced it
	end
	applyCamera(dt)
end

function widget:DrawScreen()
	font = font or (WG.fonts and WG.fonts.getFont())
	if font then
		drawPanel()
	end
end
