-- pex: fragment_15 27d8ca3e
-- pex: fragment_19 58ebfcc1
-- pex: fragment_20 902c083f
-- pex: fragment_21 55ca1974
-- pex: fragment_23 cf5fe0ab
-- pex: fragment_25 1fdf689a
-- pex: fragment_27 efb19b18
-- pex: fragment_29 40ac869b
-- pex: fragment_30 53beef32
-- pex: fragment_32 5e3d23c7
-- pex: fragment_36 03058db4
-- pex: fragment_38 ff0170c9
-- Debug quick starts. Each polled once a second for the war, a campaign or a siege quest, waited
-- 1-30 s between steps, or (36, 38) blocked in setOwner before its "DONE" box. Each fragment is
-- now its own run of named stages; the quest ticks in "Waiting" until every run is Idle.
local rt = require('skymod.rt')

-- Force a campaign, start a siege, move the player. `where` nil: the war start brings the siege.
local SIEGES = {
	f15 = { attacker = 2, hold = 4, war = 2, where = "WhiterunLocation", quest = "CWSiegeWhiterunAttackQST", marker = "CWSiegeWhiterunAttackStartMarker", settle = true },
	f21 = { attacker = 1, hold = 9, war = 1, where = "RiftenLocation", quest = "CWSiegeRiftenAttackQST", marker = "RiftenAttackStart", settle = true, dusk = true },
	f23 = { attacker = 2, hold = 4, war = 1, where = "WhiterunLocation", quest = "CWSiegeWhiterunDefendQST", marker = "CWSiegeWhiterunDefenseStartRef", dusk = true, alikir = true },
	f27 = { attacker = 2, hold = 4, war = 2, where = "MarkarthLocation", quest = "CWSiegeMarkarthAttackQst", marker = "CWSiegeMarkarthAttackStartMarker", settle = true },
	f29 = { attacker = 2, hold = 4, war = 2, quest = "CWFortSiege" },
	f30 = { attacker = 2, hold = 4, war = 1, quest = "CWFortSiege" },
}

-- Set a stage of this quest, wait for a Whiterun siege quest, then step in.
local CITY = {
	f19 = { stage = 100, quest = "CWSiegeWhiterunAttackQST", settle = 3.0 },
	f25 = { stage = 101, quest = "CWSiegeWhiterunDefendQST", settle = 3.0 },
	f32 = { stage = 101, quest = "CWSiegeWhiterunDefendQST", settle = 5.0, prepare = true },
}

return function(C)
	C.Siege = rt.sequence("Idle", "Forcing", "Campaign", "Running", "Settling")
	C.City = rt.sequence("Idle", "Running", "Settling", "Preparing")
	C.Start = rt.sequence("Idle", "Init", "Forcing", "Starting")
	local S, Y, W = C.Siege, C.City, C.Start
	local v = C.__vars
	for f in pairs(SIEGES) do v[f], v[f .. "T"] = S.Idle, rt.timer(0.0) end
	for f in pairs(CITY) do v[f], v[f .. "T"] = Y.Idle, rt.timer(0.0) end
	v.f20, v.f20T = W.Idle, rt.timer(0.0)
	v.holdsGivenTo = rt.int(0) -- 36, 38: every hold goes to this side; "DONE" once the resets end
	v.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting")

	local function kmy(self) return rt.cast(self, "CWFunctions") end
	local function cw(q) return rt.cast(q.CW, "CWScript") end
	local function player() return rt.static("Game", "GetPlayer") end

	local function force(q, attacker, hold)
		local cws = cw(q)
		cws.CWDebugForceAttacker:SetValue(attacker)
		cws.CWDebugForceHold:SetValue(hold)
	end

	local function forced(q)
		local cws = cw(q)
		return cws.CWDebugForceAttacker:GetValue() ~= 0 and cws.CWDebugForceHold:GetValue() ~= 0
	end

	local function arrive(q, spec)
		if spec.alikir then
			q.MS08AlikirWarrior1Ref:Disable()
			q.MS08AlikirWarrior2Ref:Disable()
		end
		player():MoveTo(q[spec.marker])
		if spec.dusk then q.GameHour:SetValue(17) end
	end

	local function siege_tick(self, f)
		if self[f] == S.Idle then return end
		local spec, q = SIEGES[f], kmy(self)
		if self[f] == S.Forcing then
			if not forced(q) then return end
			self[f] = spec.where and S.Campaign or S.Running
			q.CW:SetStage(spec.war)
		end
		if self[f] == S.Campaign then
			if cw(q).countCampaigns == 0 then return end
			self[f] = S.Running
			q.CWSiegeStart:SendStoryEvent(q[spec.where])
		end
		if self[f] == S.Running then
			local siege = q[spec.quest]
			if not siege:IsRunning() then return end
			if not spec.marker then
				self[f] = S.Idle
				rt.static("Debug", "MessageBox", "CWFunctions CWFortSiege quest isRunning! ")
			elseif spec.settle then
				self[f] = S.Settling
				self[f .. "T"] = 1.0
				siege:SetStage(1)
			else
				self[f] = S.Idle
				arrive(q, spec)
			end
		end
		if self[f] == S.Settling and self[f .. "T"] <= 0 then
			self[f] = S.Idle
			arrive(q, spec)
		end
	end

	local function city_tick(self, f)
		if self[f] == Y.Idle then return end
		local spec, q = CITY[f], kmy(self)
		if self[f] == Y.Running then
			local siege = q[spec.quest]
			if not siege:IsRunning() then return end
			self[f] = Y.Settling
			self[f .. "T"] = spec.settle -- NPCs settle into position
			if not spec.prepare then siege:SetStage(50) end
		end
		if self[f] == Y.Settling then
			if self[f .. "T"] > 0 then return end
			if spec.prepare then
				self[f] = Y.Preparing
				q.CWPrepareCityStart:SendStoryEvent(q.WhiterunLocation)
			else
				self[f] = Y.Idle
				player():MoveTo(q.COCMarkerWhiterun)
			end
		end
		if self[f] == Y.Preparing and q.CWPrepareCity:IsRunning() then
			self[f] = Y.Idle
			rt.static("Debug", "MessageBox", "CWDefend Quest Ready")
		end
	end

	-- 20: force Whiterun for the Sons from campaign phase 4, then clear the forcing 30 s later.
	local function start_tick(self)
		if self.f20 == W.Idle then return end
		local q = kmy(self)
		local cws = cw(q)
		if self.f20 == W.Init then
			if cws.Init == 0 then return end
			self.f20 = W.Forcing
			cws.TutorialMissionComplete = 1
			cws.debugSkipSetOwnerCalls = 1
			cws.DebugOn:SetValue(1)
			force(q, 2, 4)
		end
		if self.f20 == W.Forcing then
			if not forced(q) then return end
			cws.debugStartingCampaignPhase = 4
			self.f20 = W.Starting
			self.f20T = 30.0
			q.CW:SetStage(1)
		end
		if self.f20 == W.Starting and self.f20T <= 0 then
			self.f20 = W.Idle
			force(q, 0, 0)
			cws.debugStartingCampaignPhase = 0
		end
	end

	local function holds_tick(self)
		if self.holdsGivenTo == 0 or cw(kmy(self)).resettingGarrisons then return end
		local side = self.holdsGivenTo == 1 and "Imperials" or "Stormcloaks"
		self.holdsGivenTo = 0
		rt.static("Debug", "MessageBox", "CWFunctions DONE setting everything owned by the " .. side .. ".")
	end

	local function busy(self)
		for f in pairs(SIEGES) do if self[f] ~= S.Idle then return true end end
		for f in pairs(CITY) do if self[f] ~= Y.Idle then return true end end
		return self.f20 ~= W.Idle or self.holdsGivenTo ~= 0
	end

	function Waiting:OnTick()
		for f in pairs(SIEGES) do siege_tick(self, f) end
		for f in pairs(CITY) do city_tick(self, f) end
		start_tick(self)
		holds_tick(self)
		if not busy(self) then self:GotoState("") end
	end

	local function run(self, f, stage)
		if self[f] ~= stage.seq.Idle then return false end -- a run happens once
		self[f] = stage
		self:GotoState("Waiting")
		return true
	end

	local function quick_siege(self, f)
		if not run(self, f, S.Forcing) then return end
		local spec, q = SIEGES[f], kmy(self)
		cw(q).DebugOn:SetValue(1.0)
		force(q, spec.attacker, spec.hold)
		self:OnTick()
	end

	local function quick_city(self, f)
		if not run(self, f, Y.Running) then return end
		self:SetStage(CITY[f].stage)
		self:OnTick()
	end

	local function give_all_holds(self, side)
		local q = kmy(self)
		q.CWDebugOn:SetValue(1)
		self.holdsGivenTo = side
		self:GotoState("Waiting")
		for hold = 1, 9 do cw(q):SetHoldOwnerByInt(hold, side, false) end
		self:OnTick()
	end

	function C:Fragment_15() quick_siege(self, "f15") end
	function C:Fragment_21() quick_siege(self, "f21") end
	function C:Fragment_23() quick_siege(self, "f23") end
	function C:Fragment_27() quick_siege(self, "f27") end
	function C:Fragment_29() quick_siege(self, "f29") end
	function C:Fragment_30() quick_siege(self, "f30") end
	function C:Fragment_19() quick_city(self, "f19") end
	function C:Fragment_25() quick_city(self, "f25") end
	function C:Fragment_32() quick_city(self, "f32") end
	function C:Fragment_36() give_all_holds(self, 1) end
	function C:Fragment_38() give_all_holds(self, 2) end

	function C:Fragment_20()
		if not run(self, "f20", W.Init) then return end
		self:OnTick()
	end
end
