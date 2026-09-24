-- pex: advancecampaignphase 891f22e2
-- pex: callsetownerforpurchasedlocations d7952737
-- pex: playerjoinsactivecampaign d86f0bbb
-- pex: stoptutorialmission 8ab8a2f3
-- AdvanceCampaignPhase polled every 10 s until the player left the faction leader's town;
-- stopTutorialMission waited for CWMission00 to stop. Now `advancing` has a 10 s timer, and the
-- CWMission00 wait is CWScript.finishCampaign's. Callers read IsAdvancing().
-- CallSetOwnerForPurchasedLocations: no change, setOwner returns at once.
local rt = require('skymod.rt')

return function(C)
	C.__vars.advancing = rt.bool(false) -- a default advance waits for the player to leave
	C.__vars.advanceT = rt.timer(0.0)
	C.__vars.tutorialOwed = rt.bool(false) -- the player joined; the tutorial starts once missions settle
	C.__vars.TickRate = rt.float(1.0)
	local Waiting = rt.state(C, "Waiting")

	local function player_near_leader(self)
		local leader = self.CWs.AliasFactionLeader:GetReference()
		local player = rt.static("Game", "GetPlayer")
		return leader:GetCurrentLocation():IsSameLocation(player:GetCurrentLocation(), self.LocTypeHabitation)
	end

	local function advance(self, phaseToSetTo)
		local phase = self.CWCampaignPhase
		if phaseToSetTo > 0 then
			phase:SetValue(phaseToSetTo)
		else
			phase:SetValue(phase:GetValue() + 1)
		end
		local debugStart = self.CWs.debugStartingCampaignPhase
		if debugStart ~= 0 and phase:GetValue() < debugStart then phase:SetValue(debugStart) end
		local debugOn = self.DebugOn:GetValue() == 1
		if debugOn then rt.static("Debug", "Notification", rt.concat("CWCampaignPhase: ", phase:GetValue())) end
		self.NextPhaseDay = self.GameDaysPassed:GetValue() + self.AcceptDays
		self.Mission1Type, self.Mission2Type, self.Mission3Type = 0, 0, 0
		self.AcceptedHooks, self.AcceptedMission = 0, 0
		self:SetCurrentAttackDelta()
		self:StartMissions()
		if debugOn then rt.static("Debug", "MessageBox", "CWCampaignScript: Ready to start campaign.") end
	end

	-- True while an advance waits, or while the missions it started are resolving off screen.
	function C:IsAdvancing()
		return self.advancing or self.CWs.finishingCampaign
	end

	rt.params(C, "AdvanceCampaignPhase", { { "OptionalPhaseToSetTo", -1 } })
	function C:AdvanceCampaignPhase(OptionalPhaseToSetTo)
		if self.CWCampaignPhase:GetValue() ~= 0 and OptionalPhaseToSetTo == -1 then
			if self.advancing then return end -- a run happens once
			if player_near_leader(self) then
				self.advancing = true
				self.advanceT = 10.0
				self:GotoState("Waiting")
				return
			end
		end
		advance(self, OptionalPhaseToSetTo)
	end

	function C:PlayerJoinsActiveCampaign()
		if self.tutorialOwed then return end
		self:ForceFieldHQAliases()
		self:SetCWCampaignFieldCOAliases()
		self:UpdateCWCampaignObjAliases()
		self:AdvanceCampaignPhase(1)
		self.tutorialOwed = true
		self:GotoState("Waiting")
		self:OnTick()
	end

	function C:stopTutorialMission()
		self.CWMission00:Stop()
	end

	function Waiting:OnTick()
		if self.advancing and self.advanceT <= 0 then
			if player_near_leader(self) then
				self.advanceT = self.advanceT + 10.0
			else
				self.advancing = false
				advance(self, -1)
			end
		end
		if self.tutorialOwed and not self.CWs.finishingCampaign then
			self.tutorialOwed = false
			self:startTutorialMission()
		end
		if not self.advancing and not self.tutorialOwed then self:GotoState("") end
	end
end
