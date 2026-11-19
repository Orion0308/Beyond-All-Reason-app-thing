local Showroom = require("common/showroom")

-- A stand-in for common/weapons.lua: one shot per reload, so DPS = damage / reload and the
-- expected numbers are easy to check by eye.
local weaponsLib = {
	GetDamagePerSecond = function(weaponDef, damage)
		local dps = damage / weaponDef.reload
		return dps, dps
	end,
}

local WEAPON_DEFS = {
	[1] = { range = 200, reload = 2, damages = { [0] = 100, [1] = 20 }, customParams = {} },
	[2] = { range = 500, reload = 1, damages = { [0] = 10 }, customParams = {} },
	[3] = { range = 900, reload = 1, damages = { [0] = 9999 }, customParams = { bogus = "1" } },
	[4] = { range = 7000, reload = 1, damages = { [0] = 9999 }, customParams = {}, interceptor = 1 },
}

local function unitDef(weapons)
	local mounts = {}
	for i, id in ipairs(weapons) do
		mounts[i] = { weaponDef = id }
	end
	return {
		name = "testunit",
		translatedHumanName = "Test Unit",
		health = 1000,
		metalCost = 100,
		energyCost = 1000,
		buildTime = 2000,
		speed = 60,
		sightDistance = 400,
		weapons = mounts,
	}
end

describe("common.showroom", function()
	describe("IsSession", function()
		it("is on for 1 and true, as a string or not", function()
			assert.is_true(Showroom.IsSession({ showroom = "1" }))
			assert.is_true(Showroom.IsSession({ showroom = 1 }))
			assert.is_true(Showroom.IsSession({ showroom = "true" }))
		end)

		it("is off for 0, missing and nil modoptions", function()
			assert.is_false(Showroom.IsSession({ showroom = "0" }))
			assert.is_false(Showroom.IsSession({}))
			assert.is_false(Showroom.IsSession(nil))
		end)
	end)

	describe("Encode and Decode", function()
		it("round trips every command", function()
			local cases = {
				{ "stage", { "armpw", "corak" } },
				{ "stage", { "armpw" } },
				{ "mode", { "duel" } },
				{ "reset", {} },
			}
			for _, case in ipairs(cases) do
				local message = assert(Showroom.Decode(Showroom.Encode(case[1], unpack(case[2]))))
				assert.are.equal(case[1], message.command)
				assert.are.same(case[2], message.args)
			end
		end)

		it("ignores other widgets' messages", function()
			local message, problem = Showroom.Decode("$g$:1:armpw:0:0:0")
			assert.is_nil(message)
			assert.are.equal("not a showroom message", problem)
		end)

		it("rejects unknown commands, unknown modes and wrong argument counts", function()
			assert.is_nil(Showroom.Decode("showroom:explode"))
			assert.is_nil(Showroom.Decode("showroom:mode:dance"))
			assert.is_nil(Showroom.Decode("showroom:mode"))
			assert.is_nil(Showroom.Decode("showroom:stage"))
			assert.is_nil(Showroom.Decode("showroom:stage:a:b:c"))
			assert.is_nil(Showroom.Decode("showroom:reset:now"))
		end)

		it("rejects empty arguments", function()
			assert.is_nil(Showroom.Decode("showroom:stage::corak"))
		end)
	end)

	describe("Layout", function()
		it("puts a lone unit in the centre, facing east", function()
			local layout = Showroom.Layout(1000, 2000, 300, nil)
			assert.are.same({ x = 1000, z = 2000, facing = 1 }, layout.subject)
			assert.is_nil(layout.target)
		end)

		it("spaces a pair just outside the longer range, subject west facing east", function()
			local layout = Showroom.Layout(1000, 1000, 300, 500)
			assert.are.equal(500 + Showroom.GAP_MARGIN, layout.gap)
			assert.are.equal(1000 - layout.gap / 2, layout.subject.x)
			assert.are.equal(1000 + layout.gap / 2, layout.target.x)
			assert.are.equal(1, layout.subject.facing)
			assert.are.equal(3, layout.target.facing)
		end)

		it("clamps the gap for melee units and for artillery", function()
			assert.are.equal(Showroom.MIN_GAP, Showroom.Layout(0, 0, 0, 0).gap)
			assert.are.equal(Showroom.MAX_GAP, Showroom.Layout(0, 0, 5000, 100).gap)
		end)
	end)

	describe("UnitStats", function()
		it("reads the unit's own numbers", function()
			local stats = Showroom.UnitStats(unitDef({}), WEAPON_DEFS, weaponsLib)
			assert.are.equal("Test Unit", stats.name)
			assert.are.equal(1000, stats.health)
			assert.are.equal(100, stats.metal)
			assert.are.equal(0, stats.dps)
			assert.are.equal(0, stats.range)
			assert.are.equal(0, stats.weapons)
		end)

		it("sums DPS over every weapon and takes the longest range", function()
			local stats = Showroom.UnitStats(unitDef({ 1, 2 }), WEAPON_DEFS, weaponsLib)
			assert.are.equal(100 / 2 + 10 / 1, stats.dps)
			assert.are.equal(500, stats.range)
			assert.are.equal(2, stats.weapons)
		end)

		it("deals damage to the other unit's armor class, falling back to default", function()
			local stats = Showroom.UnitStats(unitDef({ 1, 2 }), WEAPON_DEFS, weaponsLib, 1)
			-- weapon 1 has 20 vs armor 1; weapon 2 has no entry for it and uses default (10)
			assert.are.equal(20 / 2 + 10 / 1, stats.dps)
		end)

		it("leaves out dummy weapons and interceptors", function()
			local stats = Showroom.UnitStats(unitDef({ 2, 3, 4 }), WEAPON_DEFS, weaponsLib)
			assert.are.equal(10, stats.dps)
			assert.are.equal(500, stats.range)
			assert.are.equal(1, stats.weapons)
		end)
	end)

	describe("Better", function()
		local function row(key)
			for _, r in ipairs(Showroom.ROWS) do
				if r.key == key then
					return r
				end
			end
		end

		it("prefers more health and less cost", function()
			local a, b = { health = 10, metal = 50 }, { health = 20, metal = 40 }
			assert.are.equal("b", Showroom.Better(row("health"), a, b))
			assert.are.equal("b", Showroom.Better(row("metal"), a, b))
			assert.are.equal("a", Showroom.Better(row("metal"), b, a))
		end)

		it("calls a tie for neither", function()
			assert.is_nil(Showroom.Better(row("health"), { health = 5 }, { health = 5 }))
		end)
	end)

	describe("TimeToKill", function()
		it("is health over DPS, and never without DPS", function()
			assert.are.equal(4, Showroom.TimeToKill({ dps = 50 }, { health = 200 }))
			assert.is_nil(Showroom.TimeToKill({ dps = 0 }, { health = 200 }))
		end)
	end)
end)
