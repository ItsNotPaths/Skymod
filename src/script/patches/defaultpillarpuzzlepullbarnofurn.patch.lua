-- pex: waiting.onactivate c64ddf3b
-- The bar went busy, played Pull and waited for Reset. The event now returns it to waiting.
local rt = require('skymod.rt')

return function(C)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "busy")

	function Waiting:OnActivate(triggerRef)
		self:GotoState("busy")
		self:doorOrDarts()
		self:RegisterForAnimationEvent(self, "Reset")
		self:PlayAnimation("Pull")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "Reset" then self:GotoState("Waiting") end
	end
end
