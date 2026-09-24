-- pex: pulledposition.onactivate a341012b
-- pex: pushedposition.onactivate ddd015c9
-- The lever went busy, moved and waited for its end event. The event now sets the new position;
-- the two event names say which one.
local rt = require('skymod.rt')

return function(C)
	local Pulled, Pushed, Busy = rt.state(C, "pulledPosition"), rt.state(C, "pushedPosition"), rt.state(C, "busy")

	local function move(self, pull, anim, done)
		self:GotoState("busy")
		self.isInPullPosition = pull
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Pulled:OnActivate(triggerRef) move(self, false, "FullPush", "FullPushedUp") end
	function Pushed:OnActivate(triggerRef) move(self, true, "FullPull", "FullPulledDown") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "FullPushedUp" then
			self:GotoState("pushedPosition")
		elseif asEventName == "FullPulledDown" then
			self:GotoState("pulledPosition")
		end
	end
end
