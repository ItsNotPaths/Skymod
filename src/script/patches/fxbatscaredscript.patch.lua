-- pex: waiting.ontriggerenter 91a4f24b
-- The player scared the bats: they took off, the handler waited for "End" and then 20-30 s before
-- going back to waiting. Now the event starts that rest as a timer.
local rt = require('skymod.rt')

return function(C)
	C.__vars.rest = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(1.0)
	local Waiting, Busy = rt.state(C, "waiting"), rt.state(C, "busy")

	function Waiting:OnTriggerEnter(akActionRef)
		if akActionRef ~= rt.static("Game", "GetPlayer") then return end
		self:GotoState("busy")
		self.mySFX:Play(self)
		self.weapLg:Fire(self, self.myAmmo)
		self:RegisterForAnimationEvent(self, "End")
		self:PlayAnimation("MothTakeoff")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "End" or self.rest ~= rt.None then return end
		self.rest = rt.static("Utility", "RandomInt", 20, 30)
	end

	function Busy:OnTick()
		if self.rest == rt.None or self.rest > 0 then return end
		self.rest = rt.None
		self:GotoState("waiting")
	end
end
