-- pex: power.onactivate e251fc5d
-- The button went done, played Trigger01 and waited for "done" before its sound. The event now
-- plays the sound; `pressing` marks the one press.
local rt = require('skymod.rt')

return function(C)
	C.__vars.pressing = rt.bool(false)
	local Power, Done = rt.state(C, "power"), rt.state(C, "done")

	function Power:OnActivate(akActivator)
		self:GotoState("done")
		self.pressing = true
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("Trigger01")
	end

	function Done:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" or not self.pressing then return end
		self.pressing = false
		if self.QSTAstrolabeButtonPressX then self.QSTAstrolabeButtonPressX:Play(self.objSelf) end
	end
end
