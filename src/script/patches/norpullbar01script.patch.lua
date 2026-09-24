-- pex: waiting.onactivate 15aa4a3c
-- The bar blocked activation, played Pull and waited for Reset. Now the event unblocks it;
-- `pulling` drops an activation during the pull (Papyrus ran it in parallel).
local rt = require('skymod.rt')

return function(C)
	C.__vars.pulling = rt.bool(false)
	local Waiting = rt.state(C, "Waiting")

	function Waiting:OnActivate(triggerRef)
		if self.pulling then return end
		self.pulling = true
		self:BlockActivation(true)
		self:RegisterForAnimationEvent(self, "Reset")
		self:PlayAnimation("Pull")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if not self.pulling or akSource ~= self or asEventName ~= "Reset" then return end
		self.pulling = false
		self:BlockActivation(false)
	end
end
