-- pex: downposition.onactivate 5e0b1886
-- pex: upposition.onactivate 491b4ce8
-- The portcullis went busy, moved and waited for "opening" or "closing". The event now sets isOpen
-- and the rest state.
local rt = require('skymod.rt')

return function(C)
	local Up, Down, Busy = rt.state(C, "upPosition"), rt.state(C, "downPosition"), rt.state(C, "busy")

	local function move(self, anim, done)
		self:GotoState("busy")
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Up:OnActivate(triggerRef) move(self, "open", "opening") end
	function Down:OnActivate(triggerRef) move(self, "close", "closing") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "opening" then
			self.isOpen = true
			self:GotoState("downPosition")
		elseif asEventName == "closing" then
			self.isOpen = false
			self:GotoState("upPosition")
		end
	end
end
