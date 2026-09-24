-- pex: waiting.onactivate 2ed6ec42
-- With waitForEndEvent, the activator played anim01 in DoNothing and waited for animEndEvent.
-- The event now returns it to waiting.
local rt = require('skymod.rt')

return function(C)
	local Waiting, DoNothing = rt.state(C, "waiting"), rt.state(C, "DoNothing")

	function Waiting:OnActivate(triggerRef)
		if not self.waitForEndEvent then return self:PlayAnimation(self.anim01) end
		self:GotoState("DoNothing")
		self:RegisterForAnimationEvent(self, self.animEndEvent)
		self:PlayAnimation(self.anim01)
	end

	function DoNothing:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == self.animEndEvent then self:GotoState("waiting") end
	end
end
