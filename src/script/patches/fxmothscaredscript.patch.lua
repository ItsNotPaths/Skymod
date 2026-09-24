-- pex: flying.onbeginstate f7386e07
-- Flying played the takeoff and waited for "End" before resetting. The event now resets it.
local rt = require('skymod.rt')

return function(C)
	local Flying = rt.state(C, "flying")

	function Flying:OnBeginState()
		self:RegisterForAnimationEvent(self, "End")
		self:PlayAnimation("MothTakeoff")
	end

	function Flying:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "End" then self:GotoState("reset") end
	end
end
