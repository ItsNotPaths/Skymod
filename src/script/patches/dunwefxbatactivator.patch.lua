-- pex: waiting.onactivate 71712989
-- The bats took off and the handler waited for "End" with nothing after it; the activator stays
-- busy either way. Now it only plays the takeoff.
local rt = require('skymod.rt')

return function(C)
	rt.state(C, "waiting").OnActivate = function(self, obj)
		self:GotoState("busy")
		self.mySFX:Play(self)
		self:PlayAnimation("MothTakeoff")
	end
end
