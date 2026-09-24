-- pex: onupdate 654b273c
-- pex: startsurvivalmode 1d64fa37
-- pex: startsurvivalneeds 1ecbe2d7
-- pex: stopsurvivalmode f405d5b6
-- pex: stopsurvivalneeds 56c74423
-- Turning survival on or off waited on each need in turn: StartNeed ran its first update, StopNeed
-- waited for the need's run to end. Now the `needs` run steps through them, waiting on each one's
-- `locked`, and finishes the switch (mode globals, cleanup, update timer) after the last.
local rt = require('skymod.rt')

return function(C)
	C.Needs = rt.sequence("Idle", "Hunger", "Exhaustion", "Cold")
	local N = C.Needs
	C.__vars.needs = N.Idle
	C.__vars.needsOn = rt.bool(false)   -- the run starts the needs, else it stops them
	C.__vars.switching = rt.bool(false) -- Start/StopSurvivalMode ends when the run does
	local Switching = rt.state(C, "Switching")

	local function finish_start(self)
		self.Survival_ModeEnabled:SetValueInt(1)
		self.Survival_ModeEnabledShared:SetValueInt(1)
		rt.static("Debug", "Trace", "Survival Mode is running.")
		self.Updates:RunUpdates()
	end

	local function finish_stop(self)
		self:RemoveSurvivalPerks()
		self:DepopulateSurvivalItems()
		self:RemoveSurvivalDiseases()
		self:RemoveSurvivalAfflictions()
		self:RemoveSurvivalSpells()
		self:StoreHeatSourceTriggerVolumes()
		self.Survival_ModeEnabled:SetValueInt(0)
		self.Survival_ModeEnabledShared:SetValueInt(0)
		rt.static("Debug", "Trace", "Survival Mode is stopped.")
	end

	local function finish(self)
		self.needs = N.Idle
		self:GotoState("")
		if self.switching then
			self.switching = false
			if self.needsOn then finish_start(self) else finish_stop(self) end
		end
		self:RestartUpdateTimer()
	end

	local function step(self)
		while self.needs ~= N.Idle do
			local need = self[self.needs.name]
			if need.locked then return end
			if not self.needsOn then need:StopNeed() end
			if self.needs == N.Cold then return finish(self) end
			self.needs = self.needs + 1
			if self.needsOn then self[self.needs.name]:StartNeed() end
		end
	end

	local function begin(self, on)
		if self.needs ~= N.Idle then return end -- a run happens once
		self.needsOn = on
		self.needs = N.Hunger
		self:GotoState("Switching")
		if on then self.Hunger:StartNeed() end
		step(self)
	end

	function C:StartSurvivalNeeds() begin(self, true) end
	function C:StopSurvivalNeeds() begin(self, false) end
	function Switching:OnTick() step(self) end

	function C:StartSurvivalMode()
		if self.needs ~= N.Idle then return end
		self.Survival_PlayerHasBeenPrompted:SetValueInt(1)
		self.PlayerInfo:StartUpdating()
		self.HeatCheck:StartUpdating()
		self.DialogueDetect:StartUpdating()
		self:AddSurvivalPerks()
		self:PopulateSurvivalItems()
		self.switching = true
		self:StartSurvivalNeeds()
	end

	function C:StopSurvivalMode()
		if self.needs ~= N.Idle then return end
		self.PlayerInfo:StopUpdating()
		self.HeatCheck:StopUpdating()
		self.switching = true
		self:StopSurvivalNeeds()
	end

	function C:OnUpdate()
		if self.needs ~= N.Idle then return end -- a switch is under way; it restarts the timer
		self:PromptToStartSurvivalMode()
		local canBeEnabled = self:ModeCanBeEnabled()
		if self:ModeShouldBeEnabled() and canBeEnabled and self:ModeIsDisabled() then
			self:StartSurvivalMode()
		elseif self:ModeShouldBeDisabled() and self:ModeIsEnabled() then
			self:StopSurvivalMode()
		else
			self:RestartUpdateTimer()
		end
	end
end
