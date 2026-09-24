-- pex: positiondown.onactivate 24e4abf6
-- pex: positionup.onactivate 0e333ae7
-- The switch moved and waited for TransitionComplete in the busy state; the event now ends the
-- move, and bIsInDownState says where it went.
local rt = require('skymod.rt')

return function(C)
	local Up, Down, Busy = rt.state(C, "PositionUp"), rt.state(C, "PositionDown"), rt.state(C, "Busy")

	local function flip(self, down, anim)
		self:GotoState("Busy")
		self.bIsInDownState = down
		self.ActivateSound:Play(self)
		self:RegisterForAnimationEvent(self, "TransitionComplete")
		self:PlayAnimation(anim)
	end

	function Up:OnActivate(akActionRef) flip(self, true, "Stage2") end
	function Down:OnActivate(akActionRef) flip(self, false, "Stage1") end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "TransitionComplete" then return end
		self:GotoState(self.bIsInDownState and "PositionDown" or "PositionUp")
	end
end
