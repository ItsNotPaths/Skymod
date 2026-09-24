-- pex: enablerituallights 4b187e2f
-- pex: startbattlephase 0cda22fc
-- EnableRitualLights recursed down a linked chain, waiting `delay` per link: now a "current link"
-- fact plus a timer. StartBattlePhase is six branches of waits (and, in phases 0 and 2, waits on
-- EnableRitualLights' own chain finishing); each branch is a flat step list of {wait, action},
-- where RITUAL means "wait for the ritual-light fact, not a clock". The class already ticks (S6
-- split, for ondying.t); we call that first.
local rt = require('skymod.rt')

local Ritual = rt.sequence("Idle", "Waiting")
local RITUAL = "ritual" -- sentinel: this step waits on the ritual-light fact, not bpT

local phase_steps = {
	[1] = { -- newPhase 0
		{ 2.0, function() end },
		{ 0.0, function(self) self:EnableRitualLights(self.dlc2dungyldenhulritual01, 0.2) end },
		{ RITUAL, function() end },
		{ 1.0, function(self)
			self:SetAV("Variable07", 1); self:EvaluatePackage()
			self:MoveTo(self.dlc2dungyldenhulhaknirspawn01, 0.0, 0.0, 0.0, true)
			self.dlc2dungyldenhulhaknirspawn01:PlaceAtMe(self.summonvalortargetfxactivator, 1, false, false)
		end },
		{ 1.0, function(self)
			self:MoveTo(self.dlc2dungyldenhulhaknirspawn01, 0.0, 0.0, 0.0, true)
			self:EnableNoWait(true)
		end },
		{ 1.0, function(self)
			self:SetAV("Variable07", 0); self:EvaluatePackage()
			self:StartCombat(self.player)
			self.player:CreateDetectionEvent(self.player, 75)
		end },
	},
	[2] = { -- newPhase 1
		{ 0.0, function(self)
			self:SetGhost(true); self:DispelAllSpells()
			self:SetAV("Variable07", 1); self:EvaluatePackage()
			self:PlaceAtMe(self.summonvalortargetfxactivator, 1, false, false)
		end },
		{ 1.0, function(self)
			self:SetAlpha(0, true)
			self:MoveTo(self.dlc2dungyldenhulhaknirsafety, 0.0, 0.0, 0.0, true)
		end },
		{ 1.0, function(self) self.dlc2dungyldenhulbattlemanager01:Activate(self, false) end },
		{ 1.0, function(self) self.player:CreateDetectionEvent(self.player, 75) end },
	},
	[3] = { -- newPhase 2
		{ 0.0, function(self) self:EnableRitualLights(self.dlc2dungyldenhulritual02, 0.1) end },
		{ RITUAL, function() end },
		{ 0.0, function(self) self:EnableRitualLights(self.dlc2dungyldenhulritual03, 0.1) end },
		{ RITUAL, function(self)
			self:SetGhost(false)
			if self:GetAVPercentage("Health") < 0.5 then
				local h = self:GetAV("Health")
				self:RestoreAV("Health", h / 2 - (h * self:GetAVPercentage("Health")) / 2)
			end
			self:MoveTo(self.dlc2dungyldenhulhaknirspawn04, 0.0, 0.0, 0.0, true)
			self:PlaceAtMe(self.summonvalortargetfxactivator, 1, false, false)
		end },
		{ 1.0, function(self)
			self.dlc2dungyldenhulbattlemanager02:Activate(self, false)
			self:SetAlpha(0.33, true)
		end },
		{ 1.0, function(self)
			self:SetAV("Variable07", 0); self:EvaluatePackage()
			self:StartCombat(self.player)
			self.player:CreateDetectionEvent(self.player, 75)
		end },
	},
	[4] = { -- newPhase 3, no wait at all
		{ 0.0, function(self)
			self:SetGhost(true); self:DispelAllSpells()
			self:SetAV("Variable07", 1); self:EvaluatePackage()
			self:PlaceAtMe(self.summonvalortargetfxactivator, 1, false, false)
			self:SetAlpha(0, true)
			self:MoveTo(self.dlc2dungyldenhulhaknirsafety, 0.0, 0.0, 0.0, true)
		end },
	},
	[5] = { -- newPhase 4
		{ 2.0, function(self) self.dlc2dungyldenhulbattlemanager03:Activate(self, false) end },
		{ 1.0, function(self) self.player:CreateDetectionEvent(self.player, 75) end },
	},
	[6] = { -- newPhase 5
		{ 2.0, function(self)
			self:SetGhost(false)
			self:MoveTo(self.dlc2dungyldenhulhaknirspawn01, 0.0, 0.0, 0.0, true)
			self:PlaceAtMe(self.summonvalortargetfxactivator, 1, false, false)
		end },
		{ 1.0, function(self) self:SetAlpha(0.33, true) end },
		{ 1.0, function(self)
			self:SetAV("Variable07", 0); self:EvaluatePackage()
			self.dlc2dunhaknirbuff:Cast(self, self)
			self:StartCombat(self.player)
			self.player:CreateDetectionEvent(self.player, 75)
		end },
	},
}

local function step_ready(self, wait)
	if wait == RITUAL then return self.ritual == Ritual.Idle end
	return self.bpT >= wait
end

local function tick_battle(self)
	if not self.bpRunning then return end
	local list = phase_steps[self.bpPhase + 1] -- phase_steps itself keyed explicitly 1..6, not positional
	while self.bpIdx < #list do -- each step list is positional, so 0-based: valid indices 0..#list-1
		local entry = list[self.bpIdx]
		if not step_ready(self, entry[0]) then return end
		if entry[0] == RITUAL then self.bpT = 0.0 else self.bpT = self.bpT - entry[0] end
		entry[1](self)
		self.bpIdx = self.bpIdx + 1
	end
	self.phase = self.bpPhase
	self:RegisterForSingleUpdate(1)
	self.bpRunning = false
end

return function(C)
	C.__vars.ritual = Ritual.Idle
	C.__vars.ritualLink = rt.form("ObjectReference")
	C.__vars.ritualDelay = rt.float(0.0)
	C.__vars.ritualT = rt.timer(0.0)
	C.__vars.bpRunning = rt.bool(false)
	C.__vars.bpPhase = rt.int(0)
	C.__vars.bpIdx = rt.int(0)
	C.__vars.bpT = rt.stopwatch(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:EnableRitualLights(RitualLight, delay)
		if self.ritual ~= Ritual.Idle then return end -- a run happens once
		self.magflamesimpact:Play(RitualLight)
		RitualLight:EnableNoWait(true)
		self.ritual, self.ritualLink, self.ritualDelay, self.ritualT = Ritual.Waiting, RitualLight, delay, delay
	end

	function C:StartBattlePhase(newPhase)
		if self.bpRunning then return end -- a run happens once
		self.bpRunning, self.bpPhase, self.bpIdx, self.bpT = true, newPhase, 0, 0.0
		tick_battle(self)
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.ritual == Ritual.Waiting and self.ritualT <= 0 then
			local link = self.ritualLink
			local nxt = link:GetLinkedRef()
			self.ritual = Ritual.Idle
			if nxt then self:EnableRitualLights(nxt, self.ritualDelay) end
		end
		tick_battle(self)
	end
end
