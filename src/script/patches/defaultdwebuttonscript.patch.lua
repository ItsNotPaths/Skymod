-- pex: open.onactivate 90e00cf1
-- The button went to waiting, played Trigger01 and waited for "done". The event now finishes it.
local rt = require('skymod.rt')

return function(C)
	local Open, Waiting = rt.state(C, "open"), rt.state(C, "waiting")

	function Open:OnActivate(akActivator)
		self:GotoState("waiting")
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("Trigger01")
	end

	function Waiting:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" then return end
		if self.QSTAstrolabeButtonPressX then self.QSTAstrolabeButtonPressX:Play(self.objSelf) end
		self:GotoState("Open")
	end
end
