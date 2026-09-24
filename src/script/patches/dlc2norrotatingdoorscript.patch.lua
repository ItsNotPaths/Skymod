-- pex: waiting.onactivate ea39cc5f
-- The door went busy, rotated and waited for Trans01 or Trans02. The event now returns it to
-- waiting.
local rt = require('skymod.rt')

return function(C)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	function Waiting:OnActivate(triggerRef)
		self:GotoState("Busy")
		self.startOpen = not self.startOpen
		local anim, done = "RotateOpen", "Trans02"
		if self.startOpen then anim, done = "RotateClosed", "Trans01" end
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource == self and (asEventName == "Trans01" or asEventName == "Trans02") then self:GotoState("Waiting") end
	end
end
