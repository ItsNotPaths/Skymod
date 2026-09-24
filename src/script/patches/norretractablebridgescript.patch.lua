-- pex: loweredposition.onactivate 00db6f5e
-- pex: raisedposition.onactivate 06594b48
-- The bridge went busy, moved and waited for trans02 or trans01. The event now sets isOpen and the
-- rest state.
local rt = require('skymod.rt')

return function(C)
	local Lowered, Raised, Busy = rt.state(C, "LoweredPosition"), rt.state(C, "RaisedPosition"), rt.state(C, "busy")

	local function move(self, anim, done)
		self:GotoState("busy")
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Lowered:OnActivate(triggerRef) move(self, "lower", "trans02") end
	function Raised:OnActivate(triggerRef) move(self, "raise", "trans01") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "trans02" then
			self.isOpen = true
			self:GotoState("RaisedPosition")
		elseif asEventName == "trans01" then
			self.isOpen = false
			self:GotoState("LoweredPosition")
		end
	end
end
