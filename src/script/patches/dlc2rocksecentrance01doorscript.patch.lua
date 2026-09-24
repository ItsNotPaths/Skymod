-- pex: waiting.onactivate e85d2ab3
-- The door went busy, opened or closed and waited for Opened or Closed; unless doOnce it then
-- went back to waiting. The event now does that.
local rt = require('skymod.rt')

return function(C)
	local Waiting, Busy = rt.state(C, "waiting"), rt.state(C, "busy")

	function Waiting:OnActivate(triggerRef)
		self:GotoState("busy")
		self.opened = not self.opened
		local anim, done = "Close", "Closed"
		if self.opened then anim, done = "Open", "Opened" end
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or (asEventName ~= "Opened" and asEventName ~= "Closed") then return end
		if not self.doOnce then self:GotoState("waiting") end
	end
end
