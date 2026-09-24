-- pex: waiting.onactivate 7bd756d2
-- The canned dust played anim01 and waited for animEndEvent with nothing after the wait; the state
-- stays DoNothing either way. Now it only plays.
local rt = require('skymod.rt')

return function(C)
	local Waiting = rt.state(C, "waiting")

	function Waiting:OnActivate(triggerRef)
		self:GotoState("DoNothing")
		self.objSelf = rt.cast(self, "ObjectReference")
		self.rockfallSound:Play(self.objSelf)
		rt.static("Game", "ShakeCamera", rt.None, 1.0)
		rt.static("Game", "ShakeController", self.ControllerShakeL, self.ControllerShakeR, self.ControllerShakeDuration)
		if self.cannedHallwayDust then
			self:PlayAnimation(self.anim01)
		else
			self:placeAllThings()
		end
	end
end
