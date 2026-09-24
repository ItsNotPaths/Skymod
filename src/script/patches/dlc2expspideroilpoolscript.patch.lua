-- pex: onload 27b93b2f
-- The oil cloud waited fLifetime, played StopEffect and waited for "End", then removed itself.
-- Now a timer in the Burning state and the End event do that. OnCellDetach still removes it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Burning, Stopping = rt.state(C, "Burning"), rt.state(C, "Stopping")

	function C:OnLoad()
		self.t = self.fLifetime
		self:GotoState("Burning")
	end

	function Burning:OnLoad() end -- a run happens once

	function Burning:OnTick()
		if self.t > 0 then return end
		self:GotoState("Stopping")
		self:RegisterForAnimationEvent(self, "End")
		self:PlayAnimation("StopEffect")
	end

	function Stopping:OnLoad() end

	function Stopping:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "End" then return end
		self:DisableNoWait()
		self:Delete()
	end
end
