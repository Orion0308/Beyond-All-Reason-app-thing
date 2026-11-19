local gadget = gadget ---@type Gadget

function gadget:GetInfo()
	return {
		name = "Unit Showroom",
		desc = "Stages one unit (and an optional target) in the arena for close-up inspection, target practice and duels",
		author = "Orion",
		date = "2026",
		license = "GNU GPL, v2 or later",
		layer = 0,
		enabled = true,
	}
end

-- The SYNCED half of the unit showroom (the widget is luaui/Widgets/gui_showroom.lua, the shared
-- protocol common/showroom.lua, the walkthrough doc/Showroom.md).
--
-- Only synced code may create units, give them orders and decide damage, and every client runs
-- it identically, so this is where the arena lives. It listens for the widget's messages,
-- stages the units, and publishes what it did through game rules params.
--
-- Loaded in a showroom session only: the start script sets the showroom modoption. Everywhere
-- else the file stops here and costs nothing.
local Showroom = VFS.Include("common/showroom.lua")

if not Showroom.IsSession(Spring.GetModOptions()) or not gadgetHandler:IsSyncedCode() then
	return false
end

local spCreateUnit = Spring.CreateUnit
local spDestroyUnit = Spring.DestroyUnit
local spDestroyFeature = Spring.DestroyFeature
local spValidUnitID = Spring.ValidUnitID
local spValidFeatureID = Spring.ValidFeatureID
local spGiveOrderToUnit = Spring.GiveOrderToUnit
local spGetGroundHeight = Spring.GetGroundHeight
local spSetGameRulesParam = Spring.SetGameRulesParam
local spGetTeamUnits = Spring.GetTeamUnits
local spGetPlayerInfo = Spring.GetPlayerInfo

local CMD_FIRE_STATE = CMD.FIRE_STATE
local CMD_MOVE_STATE = CMD.MOVE_STATE
local CMD_ATTACK = CMD.ATTACK
local CMD_STOP = CMD.STOP
local FIRE_HOLD, FIRE_AT_WILL = 0, 2
local MOVE_HOLD, MOVE_ROAM = 0, 2

-- The start script's two teams: the player's (the subject) and an empty enemy team (the target).
-- They sit in different allyteams so the units are enemies and will shoot each other.
local SUBJECT_TEAM = 0
local TARGET_TEAM = 1

local arena = {
	subjectDefName = nil, ---@type string?
	targetDefName = nil, ---@type string?
	subjectID = nil, ---@type integer?
	targetID = nil, ---@type integer?
	mode = "inspect",
	revision = 0,
	protected = {}, ---@type table<integer, true> unitIDs that take no damage right now
	wrecks = {}, ---@type table<integer, true> features created since staging, cleared on reset
}

--------------------------------------------------------------------------------
-- Publishing: everything the widget needs to know goes out as rules params
--------------------------------------------------------------------------------

local function publish(result)
	spSetGameRulesParam(Showroom.PARAM.subject, arena.subjectID or -1)
	spSetGameRulesParam(Showroom.PARAM.target, arena.targetID or -1)
	spSetGameRulesParam(Showroom.PARAM.mode, arena.mode)
	spSetGameRulesParam(Showroom.PARAM.revision, arena.revision)
	if result ~= nil then
		spSetGameRulesParam(Showroom.PARAM.result, result)
	end
end

--------------------------------------------------------------------------------
-- Staging
--------------------------------------------------------------------------------

local function longestRange(unitDef)
	local range = 0
	for _, mount in ipairs(unitDef.weapons or {}) do
		local weaponDef = WeaponDefs[mount.weaponDef]
		if weaponDef and not (weaponDef.customParams and weaponDef.customParams.bogus) then
			range = math.max(range, weaponDef.range or 0)
		end
	end
	return range
end

--- Removes everything a previous stage left: both teams' units and the wrecks they dropped.
--- Map features (trees, rocks) are left alone: only features created since staging are ours.
local clearing = false -- true while clearArena removes units, so UnitDestroyed ignores them

local function clearArena()
	clearing = true
	for _, teamID in ipairs({ SUBJECT_TEAM, TARGET_TEAM }) do
		for _, unitID in ipairs(spGetTeamUnits(teamID) or {}) do
			-- selfd = false, reclaimed = true: vanish without an explosion or a wreck
			spDestroyUnit(unitID, false, true)
		end
	end
	for featureID in pairs(arena.wrecks) do
		if spValidFeatureID(featureID) then
			spDestroyFeature(featureID)
		end
	end
	arena.wrecks = {}
	arena.protected = {}
	arena.subjectID, arena.targetID = nil, nil
	clearing = false
end

local function spawn(unitDef, spot, teamID)
	local y = spGetGroundHeight(spot.x, spot.z)
	return spCreateUnit(unitDef.id, spot.x, y, spot.z, spot.facing, teamID)
end

local function setStates(unitID, fireState, moveState)
	if unitID and spValidUnitID(unitID) then
		spGiveOrderToUnit(unitID, CMD_FIRE_STATE, { fireState }, 0)
		spGiveOrderToUnit(unitID, CMD_MOVE_STATE, { moveState }, 0)
		spGiveOrderToUnit(unitID, CMD_STOP, {}, 0)
	end
end

local function attack(attackerID, victimID)
	if attackerID and victimID and spValidUnitID(attackerID) and spValidUnitID(victimID) then
		-- An attack order on a unit: a mobile attacker closes to its range by itself, a turret
		-- waits until the victim walks in.
		spGiveOrderToUnit(attackerID, CMD_ATTACK, { victimID }, 0)
	end
end

--- Puts the arena into a mode: who may shoot, who may die.
local function applyMode(mode)
	arena.mode = mode
	arena.protected = {}
	local s, t = arena.subjectID, arena.targetID
	if mode == "inspect" then
		-- Nobody shoots, nobody dies: a turntable.
		setStates(s, FIRE_HOLD, MOVE_HOLD)
		setStates(t, FIRE_HOLD, MOVE_HOLD)
		if s then
			arena.protected[s] = true
		end
		if t then
			arena.protected[t] = true
		end
	elseif mode == "target" then
		-- The subject shoots, the target stands still and cannot die: a firing range.
		setStates(s, FIRE_AT_WILL, MOVE_ROAM)
		setStates(t, FIRE_HOLD, MOVE_HOLD)
		if s then
			arena.protected[s] = true
		end
		if t then
			arena.protected[t] = true
		end
		attack(s, t)
	elseif mode == "duel" then
		-- Both shoot, both can die.
		setStates(s, FIRE_AT_WILL, MOVE_ROAM)
		setStates(t, FIRE_AT_WILL, MOVE_ROAM)
		attack(s, t)
		attack(t, s)
	end
	publish("")
end

local function stage(subjectDefName, targetDefName)
	local subjectDef = UnitDefNames[subjectDefName]
	if not subjectDef then
		Spring.Echo("[showroom] unknown unit '" .. tostring(subjectDefName) .. "'")
		return
	end
	local targetDef = targetDefName and targetDefName ~= Showroom.NONE and UnitDefNames[targetDefName] or nil
	if targetDefName and targetDefName ~= Showroom.NONE and not targetDef then
		Spring.Echo("[showroom] unknown target '" .. tostring(targetDefName) .. "', staging without one")
	end

	clearArena()
	arena.subjectDefName = subjectDefName
	arena.targetDefName = targetDef and targetDefName or nil

	local layout = Showroom.Layout(
		Game.mapSizeX / 2,
		Game.mapSizeZ / 2,
		longestRange(subjectDef),
		targetDef and longestRange(targetDef) or nil
	)
	arena.subjectID = spawn(subjectDef, layout.subject, SUBJECT_TEAM)
	if targetDef then
		arena.targetID = spawn(targetDef, layout.target, TARGET_TEAM)
	end
	arena.revision = arena.revision + 1

	-- Without a target there is nothing to shoot at: target practice and duel fall back.
	local mode = arena.mode
	if not arena.targetID then
		mode = "inspect"
	end
	applyMode(mode)
end

--------------------------------------------------------------------------------
-- Call-ins
--------------------------------------------------------------------------------

local function revealArena()
	-- The player sees everything in the arena: an artillery target out past the subject's sight
	-- would otherwise be a radar blip. GetTeamInfo's 6th return is the allyteam.
	local _, _, _, _, _, allyTeamID = Spring.GetTeamInfo(SUBJECT_TEAM, false)
	if allyTeamID and Spring.SetGlobalLos then
		Spring.SetGlobalLos(allyTeamID, true)
	end
end

function gadget:Initialize()
	revealArena()
	publish("")
end

function gadget:GameStart()
	revealArena()
end

function gadget:RecvLuaMsg(msg, playerID)
	-- Cheap reject first: this call-in sees every LuaRules message from every widget.
	if msg:sub(1, #Showroom.HEADER) ~= Showroom.HEADER then
		return
	end
	local _, _, spectator = spGetPlayerInfo(playerID, false)
	if spectator then
		return true
	end
	local message, problem = Showroom.Decode(msg)
	if not message then
		Spring.Echo("[showroom] ignored message: " .. tostring(problem))
		return true
	end
	local args = message.args
	if message.command == "stage" then
		stage(args[1], args[2])
	elseif message.command == "mode" then
		if args[1] ~= "inspect" and not arena.targetID then
			Spring.Echo("[showroom] '" .. args[1] .. "' needs a target: /showroom <unit> <target>")
		elseif
			(arena.subjectID and not spValidUnitID(arena.subjectID))
			or (arena.targetID and not spValidUnitID(arena.targetID))
		then
			-- A duel ended: start the next mode from a fresh stage.
			arena.mode = args[1]
			stage(arena.subjectDefName, arena.targetDefName or Showroom.NONE)
		else
			applyMode(args[1])
		end
	elseif message.command == "reset" then
		if arena.subjectDefName then
			stage(arena.subjectDefName, arena.targetDefName or Showroom.NONE)
		end
	end
	return true
end

-- Damage is decided here, in synced code: returning 0 cancels it. Only the two staged units can
-- be protected, so the cost is one table lookup per hit.
function gadget:UnitPreDamaged(unitID)
	if arena.protected[unitID] then
		return 0, 0
	end
end

function gadget:UnitDestroyed(unitID)
	if clearing or arena.mode ~= "duel" then
		return
	end
	if unitID == arena.subjectID or unitID == arena.targetID then
		local subjectAlive = unitID ~= arena.subjectID and arena.subjectID and spValidUnitID(arena.subjectID)
		local targetAlive = unitID ~= arena.targetID and arena.targetID and spValidUnitID(arena.targetID)
		local result = subjectAlive and "subject" or targetAlive and "target" or "draw"
		-- The survivor stops and stays safe until the next stage or mode.
		local survivor = subjectAlive and arena.subjectID or targetAlive and arena.targetID or nil
		if survivor then
			arena.protected[survivor] = true
			setStates(survivor, FIRE_HOLD, MOVE_HOLD)
		end
		publish(result)
	end
end

function gadget:FeatureCreated(featureID)
	-- Wrecks and heaps from the fight; cleared on the next stage. Map features exist before the
	-- game starts, so they never land here once a stage is up.
	if arena.subjectDefName then
		arena.wrecks[featureID] = true
	end
end
