-- pex: ontriggerenter 2ee034ca
-- The whole handler is one chain (wait 10, disable fx, and only when OneTimeTrigger set the flag,
-- wait 3 more and disable again) since Papyrus falls straight from the first if into the second.
-- Now a two-step sequence; the broken field is still the guard, exactly as Papyrus reads it.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "Waiting", "Waiting2")
	C.__vars.stage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:OnTriggerEnter(akActionRef)
		if self.stage ~= C.Stage.Idle or self.broken ~= 0 then return end
		if self.OneTimeTrigger > 0 then self.broken = 1 end -- set before the wait it guards
		self:SetAnimationVariableFloat("fToggleBlend", 1)
		if self.TriggerPlacedFX then self.myfx = self:PlaceAtMe(self.TriggerPlacedFX, 1) end
		if self.TriggeredSound then self.TriggeredSound:Play(self) end
		self.stage = C.Stage.Waiting
		self.t = 10.0
	end

	function C:OnTick()
		if self.t > 0 then return end
		if self.stage == C.Stage.Waiting then
			self.myfx:Disable()
			if self.broken == 1 then
				self.stage = C.Stage.Waiting2
				self.t = self.t + 3.0
			else
				self.stage = C.Stage.Idle
			end
		elseif self.stage == C.Stage.Waiting2 then
			self.myfx:Disable()
			self.broken = 2
			self.stage = C.Stage.Idle
		end
	end
end
