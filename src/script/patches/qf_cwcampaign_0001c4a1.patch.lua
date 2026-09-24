-- pex: fragment_0 792b66bd
-- Stage 0 set up a campaign in one call: the purchased garrisons (setOwner waited for their
-- resets), then the phase advance (which could wait for the player to leave the faction leader).
-- Now `setup` waits on CWScript's resettingGarrisons, then on the campaign's IsAdvancing().
local rt = require('skymod.rt')

return function(C)
	C.Setup = rt.sequence("Idle", "Garrisons", "Advancing")
	local S = C.Setup
	C.__vars.setup = S.Idle
	C.__vars.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting")

	local function campaign(self) return rt.cast(self, "CWCampaignScript") end

	function C:Fragment_0()
		if self.setup ~= S.Idle then return end
		local q = campaign(self)
		q.CWs.CampaignRunning = 1 -- busy setting up
		q:ForceFieldHQAliases()
		q:SetCWCampaignFieldCOAliases()
		q:ResetCampaign()
		self.setup = S.Garrisons
		self:GotoState("Waiting")
		q:PurchaseGarrisons()
		self:OnTick()
	end

	function Waiting:OnTick()
		local q = campaign(self)
		if self.setup == S.Garrisons then
			if q.CWs.resettingGarrisons then return end
			self.setup = S.Advancing
			q:AdvanceCampaignPhase(-1)
		end
		if q:IsAdvancing() then return end
		self.setup = S.Idle
		self:GotoState("")
		q.CWs.CampaignRunning = 2 -- done setting up
		rt.cast(self.Alias_FieldCO, "CWCampaignFieldCOScript"):StartTraveling(q:GetFieldHQMarker(), 1000.0)
		rt.cast(self.Alias_EnemyFieldCO, "CWCampaignFieldCOScript"):StartTraveling(q:GetEnemyFieldHQMarker(), 1000.0)
	end
end
