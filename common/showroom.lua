-- The UNIT SHOWROOM's shared logic: the message protocol between the widget (luaui) and the
-- gadget (luarules), where the arena puts the units, and the stats the panel shows.
--
-- Pure: nothing here calls the engine. The callers hand in what it needs (UnitDefs entries,
-- the WeaponDefs table, the DPS helper from common/weapons.lua), so all of it runs in the spec
-- suite (spec/common/showroom_spec.lua) and both sides of the game agree on one definition.
--
-- Loaded with VFS.Include("common/showroom.lua") from the gadget and the widget.
--
--   widget  --Spring.SendLuaRulesMsg(Showroom.Encode(...))-->  gadget:RecvLuaMsg  (decode)
--   gadget  --Spring.SetGameRulesParam(Showroom.PARAM.*)--->  widget reads GetGameRulesParam
--
-- See doc/Showroom.md for the walkthrough.

local Showroom = {}

---Whether this game is a showroom session: the start script (or lobby) sets the showroom
---modoption. Modoptions arrive as strings, and a switched-off bool can arrive as "0", which
---Lua counts as true, so the value is compared, never just tested.
---@param modOptions table? Spring.GetModOptions()
---@return boolean
function Showroom.IsSession(modOptions)
	local value = tostring((modOptions or {}).showroom or "")
	return value == "1" or value == "true"
end

--------------------------------------------------------------------------------
-- Protocol
--------------------------------------------------------------------------------

--- Every showroom message starts with this, so the gadget can ignore everyone else's
--- LuaRules messages with one cheap prefix test.
Showroom.HEADER = "showroom:"

--- Stands in for "no target unit" in a stage message.
Showroom.NONE = "none"

--- What the arena is doing.
---   inspect  both units idle, nobody shoots: look at the model, orbit it
---   target   the subject shoots at the target, which cannot die (range, reload, accuracy)
---   duel     both shoot, both can die; the gadget reports the winner
Showroom.MODES = { "inspect", "target", "duel" }
local isMode = {}
for _, mode in ipairs(Showroom.MODES) do
	isMode[mode] = true
end

--- Commands the widget may send, and how many arguments each takes (min, max).
local COMMANDS = {
	stage = { 1, 2 }, -- stage <subjectDefName> [targetDefName | none]
	mode = { 1, 1 }, --  mode <inspect | target | duel>
	reset = { 0, 0 }, -- reset: put both units back where they started, full health
}

--- Game rules params the gadget publishes and the widget reads. Rules params are the
--- simplest synced -> unsynced channel: every client can read them, they survive a
--- /luaui reload, and only synced code can write them.
Showroom.PARAM = {
	subject = "showroom_subject", -- unitID, or -1
	target = "showroom_target", -- unitID, or -1
	mode = "showroom_mode", -- one of MODES
	result = "showroom_result", -- "" | "subject" | "target" | "draw"
	revision = "showroom_revision", -- bumped on every stage/reset so the widget can re-frame
}

---Builds a message for Spring.SendLuaRulesMsg.
---@param command string "stage" | "mode" | "reset"
---@param ... string arguments
---@return string
function Showroom.Encode(command, ...)
	local parts = { command, ... }
	for i = 1, #parts do
		parts[i] = tostring(parts[i])
	end
	return Showroom.HEADER .. table.concat(parts, ":")
end

---Reads a message back. Anything that is not a well formed showroom message gives nil and
---why, so the gadget never acts on half a command.
---@param msg string
---@return { command: string, args: string[] }? message
---@return string? problem
function Showroom.Decode(msg)
	if type(msg) ~= "string" or msg:sub(1, #Showroom.HEADER) ~= Showroom.HEADER then
		return nil, "not a showroom message"
	end
	local body = msg:sub(#Showroom.HEADER + 1)
	local parts = {}
	for part in (body .. ":"):gmatch("([^:]*):") do
		parts[#parts + 1] = part
	end
	local command = table.remove(parts, 1)
	local arity = COMMANDS[command]
	if not arity then
		return nil, "unknown command '" .. tostring(command) .. "'"
	end
	if #parts < arity[1] or #parts > arity[2] then
		return nil, command .. " takes " .. arity[1] .. "-" .. arity[2] .. " arguments, got " .. #parts
	end
	for i = 1, #parts do
		if parts[i] == "" then
			return nil, command .. ": argument " .. i .. " is empty"
		end
	end
	if command == "mode" and not isMode[parts[1]] then
		return nil, "unknown mode '" .. parts[1] .. "'"
	end
	return { command = command, args = parts }
end

function Showroom.IsMode(mode)
	return isMode[mode] == true
end

--------------------------------------------------------------------------------
-- Arena layout
--------------------------------------------------------------------------------

--- Spacing between the two units, in elmos (8 elmos = 1 map square).
Showroom.MIN_GAP = 250 -- melee and very short range units still get room to be seen
Showroom.MAX_GAP = 1800 -- long range artillery: further apart and the camera cannot frame both
Showroom.GAP_MARGIN = 120 -- start just outside the longer range, so a duel opens with an approach

-- Engine facings for Spring.CreateUnit: 0 south, 1 east, 2 north, 3 west.
local FACING_EAST, FACING_WEST = 1, 3

---Where the units stand: the subject on the west, the target on the east, facing each other
---across the centre of the arena.
---@param centerX number
---@param centerZ number
---@param subjectRange number longest weapon range of the subject (0 if unarmed)
---@param targetRange number? the same for the target; nil when there is no target
---@return { subject: { x: number, z: number, facing: integer }, target: { x: number, z: number, facing: integer }?, gap: number }
function Showroom.Layout(centerX, centerZ, subjectRange, targetRange)
	if targetRange == nil then
		return { subject = { x = centerX, z = centerZ, facing = FACING_EAST }, gap = 0 }
	end
	local longest = math.max(subjectRange or 0, targetRange or 0)
	local gap = math.min(Showroom.MAX_GAP, math.max(Showroom.MIN_GAP, longest + Showroom.GAP_MARGIN))
	return {
		subject = { x = centerX - gap / 2, z = centerZ, facing = FACING_EAST },
		target = { x = centerX + gap / 2, z = centerZ, facing = FACING_WEST },
		gap = gap,
	}
end

--------------------------------------------------------------------------------
-- Stats
--------------------------------------------------------------------------------

---Whether a weapon counts toward DPS and range: dummy weapons (customParams.bogus, used for
---targeting tricks) and interceptors (anti-nuke) do not fight units.
local function isCombatWeapon(weaponDef)
	if not weaponDef then
		return false
	end
	local custom = weaponDef.customParams or {}
	if custom.bogus and custom.bogus ~= "0" then
		return false
	end
	if weaponDef.interceptor and weaponDef.interceptor ~= 0 then
		return false
	end
	return true
end

---The numbers the panel shows for one unit type.
---@param unitDef table an entry of UnitDefs
---@param weaponDefs table the WeaponDefs table
---@param weaponsLib table common/weapons.lua (GetDamagePerSecond)
---@param armorType integer? the armor class the damage is dealt to (UnitDefs[x].armorType of
---the other unit); nil means armor class 0, "default"
---@return table stats
function Showroom.UnitStats(unitDef, weaponDefs, weaponsLib, armorType)
	local dps, range, weapons = 0, 0, 0
	for _, mount in ipairs(unitDef.weapons or {}) do
		local weaponDef = weaponDefs[mount.weaponDef]
		if isCombatWeapon(weaponDef) then
			weapons = weapons + 1
			range = math.max(range, weaponDef.range or 0)
			local damages = weaponDef.damages or {}
			local damage = damages[armorType or 0] or damages[0] or 0
			if damage > 0 then
				local _, pointBlank = weaponsLib.GetDamagePerSecond(weaponDef, damage)
				dps = dps + pointBlank
			end
		end
	end
	return {
		name = unitDef.translatedHumanName or unitDef.humanName or unitDef.name,
		health = unitDef.health or 0,
		metal = unitDef.metalCost or 0,
		energy = unitDef.energyCost or 0,
		buildTime = unitDef.buildTime or 0,
		speed = unitDef.speed or 0,
		sight = unitDef.sightDistance or 0,
		range = range,
		dps = dps,
		weapons = weapons,
	}
end

--- The rows of the stats panel, top to bottom. `better` says which way wins in a comparison:
--- "high" (more is better), "low" (less is better) or nil (no winner, just information).
Showroom.ROWS = {
	{ key = "health", label = "Health", format = "%d", better = "high" },
	{ key = "dps", label = "DPS (vs other)", format = "%.0f", better = "high" },
	{ key = "range", label = "Range", format = "%d", better = "high" },
	{ key = "speed", label = "Speed", format = "%.0f", better = "high" },
	{ key = "sight", label = "Sight", format = "%d", better = "high" },
	{ key = "metal", label = "Metal cost", format = "%d", better = "low" },
	{ key = "energy", label = "Energy cost", format = "%d", better = "low" },
	{ key = "buildTime", label = "Build time", format = "%d", better = "low" },
}

---Which side wins a row: "a", "b" or nil (equal, or the row has no better direction).
---@param row table an entry of Showroom.ROWS
---@param a table stats
---@param b table stats
---@return string?
function Showroom.Better(row, a, b)
	local va, vb = a[row.key], b[row.key]
	if not row.better or va == vb then
		return nil
	end
	if row.better == "high" then
		return va > vb and "a" or "b"
	end
	return va < vb and "a" or "b"
end

---Seconds for `attacker` to kill `defender` at full DPS, every shot landing, no regeneration:
---the "on paper" duel the panel shows next to the real one. nil when it never would.
---@param attacker table stats, dps already worked out against the defender's armor
---@param defender table stats
---@return number?
function Showroom.TimeToKill(attacker, defender)
	if attacker.dps <= 0 then
		return nil
	end
	return defender.health / attacker.dps
end

return Showroom
