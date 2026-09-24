-- pex: ontriggerenter 157ccaa6
-- The trigger raised the stair (another ref) and waited for its "done" with `busy` set. Now the
-- Animating state polls the stair's animation.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Animating = rt.state(C, "Animating")

	function C:OnTriggerEnter(actronaut)
		if self.busy then return end
		if not self.animOnEnter or self.animOnEnter == "" or not self.isParentTrig or self.isStairUp then return end
		self.busy = true
		self.objectToAnimate:PlayAnimation(self.animOnEnter)
		self:GotoState("Animating")
		self:OnTick()
	end

	function Animating:OnTick()
		if self.objectToAnimate:IsAnimRunning(self.animOnEnter) then return end
		self.isStairUp = true
		self.busy = false
		self:GotoState("")
	end
end
