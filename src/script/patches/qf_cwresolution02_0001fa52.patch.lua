-- pex: fragment_12 a9ebf952
-- Stage 205 (time expired) stopped this quest only after AdvanceCampaignPhase returned, and the
-- advance could wait for the player to leave the faction leader. The stop now waits for the
-- campaign's IsAdvancing() to go false.
local rt = require('skymod.rt')

return function(C)
	C.__vars.stopOwed = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting")

	local function campaign(self) return rt.cast(self, "CWResolution02Script").CWCampaignS end

	function C:Fragment_12()
		if self.stopOwed then return end
		local q = campaign(self)
		q.FailedMission = 1
		self.stopOwed = true
		self:GotoState("Waiting")
		q:AdvanceCampaignPhase(-1)
		self:OnTick()
	end

	function Waiting:OnTick()
		if campaign(self):IsAdvancing() then return end
		self.stopOwed = false
		self:GotoState("")
		self:UnregisterForUpdate()
		self:Stop()
	end
end
