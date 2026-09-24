-- pex: closed.incrementpillarslit 7ed8f0a0
-- pex: open.onactivate 513ad1a0
-- With two pillars lit the button opened and waited for "Done" before going Open; a press played
-- Trigger01 and stayed in waiting. Now the event ends the opening; `opening` tells it from a press.
local rt = require('skymod.rt')

return function(C)
	C.__vars.opening = rt.bool(false)
	local Closed, Open, Waiting = rt.state(C, "closed"), rt.state(C, "open"), rt.state(C, "waiting")

	function Closed:incrementPillarsLit()
		self.PillarsLit = self.PillarsLit + 1
		if self.PillarsLit < 2 then return end
		self:GotoState("waiting")
		self.opening = true
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Open")
	end

	function Open:OnActivate(akActivator)
		self:GotoState("waiting")
		self:PlayAnimation("Trigger01") -- nothing followed the wait
	end

	function Waiting:OnAnimationEvent(akSource, asEventName)
		if not self.opening or akSource ~= self or asEventName ~= "Done" then return end
		self.opening = false
		self:GotoState("Open")
		self:BlockActivation(false)
	end
end
