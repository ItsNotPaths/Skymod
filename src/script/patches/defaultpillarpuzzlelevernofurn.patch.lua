-- pex: pulledposition.onactivate b427997e
-- pex: pushedposition.onactivate d3bf8455
-- The lever went busy, played its move and waited for the end event. The event now sets the new
-- position; the two event names say which one.
local rt = require('skymod.rt')

return function(C)
	local Pulled, Pushed, Busy = rt.state(C, "pulledPosition"), rt.state(C, "pushedPosition"), rt.state(C, "busy")

	local function move(self, anim, done)
		self:GotoState("busy")
		self:doorOrDarts()
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function Pulled:OnActivate(triggerRef) move(self, "FullPush", "FullPushedUp") end
	function Pushed:OnActivate(triggerRef) move(self, "FullPull", "FullPulledDown") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "FullPushedUp" then
			self:GotoState("pushedPosition")
		elseif asEventName == "FullPulledDown" then
			self:GotoState("pulledPosition")
		end
	end
end
