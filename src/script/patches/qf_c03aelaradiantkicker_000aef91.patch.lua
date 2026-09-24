-- pex: fragment_0 1e6a579b
-- Fragment_0 stopped the kicker once KickOffReconQuests had started a recon quest. That call now
-- returns at once, so the Stop waits in state "Kicking" until C00's `reconOwed` is false.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Kicking = rt.state(C, "Kicking")

	function C:Fragment_0()
		if self:GetState() == "Kicking" then return end
		self:GotoState("Kicking")
		self.C00:KickOffReconQuests()
		self:OnTick()
	end

	function Kicking:OnTick()
		if self.C00.reconOwed then return end
		self:GotoState("")
		self:Stop()
	end
end
