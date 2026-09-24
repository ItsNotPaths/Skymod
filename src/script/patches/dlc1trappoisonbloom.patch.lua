-- pex: disarmed.onbeginstate 0fc259ae ca1e8f6e
-- pex: onupdate db5e4cc5 1b3d6eef
-- pex: reset.onbeginstate 18518c54 3067188b
-- Reset, Disarmed and OnUpdate waited for the warning animation's "End" (Active registered it).
-- Then OnUpdate played the explosion and waited poisonReleaseDelay before the gas. Now the "End"
-- event finishes each, in the state that waits for it, and a timer releases the gas.
local rt = require('skymod.rt')

return function(C)
	C.__vars.release = rt.timer(rt.None) -- counts down to the gas once the bloom explodes
	local Reset, Disarmed, Firing = rt.state(C, "Reset"), rt.state(C, "disarmed"), rt.state(C, "Firing")
	local base_tick = rt.load("TrapTriggerBase").__fn.ontick

	local function warn_over(self)
		self:UnregisterForAnimationEvent(self, "End")
		self.waitingForWarnEnd = false
	end

	function Reset:OnBeginState()
		self:UnregisterForUpdate()
	end

	function Reset:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "End" then return end
		rt.static("Sound", "StopInstance", self.mySoundInstance)
		self:PlayAnimation("Reset")
		warn_over(self)
		self:GotoState("Inactive")
	end

	local function picked(self)
		warn_over(self)
		self:PlayAnimation("Picked")
		self:SetDestroyed()
	end

	function Disarmed:OnBeginState()
		if not self.waitingForWarnEnd then picked(self) end
	end

	function Disarmed:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "End" and self.waitingForWarnEnd then picked(self) end
	end

	function C:OnUpdate()
		if self.objectsInTrigger > 0 and self:GetState() ~= "disarmed" then
			self:GotoState("Firing")
		elseif self.objectsInTrigger == 0 then
			self:PlayAnimation("Reset")
		end
	end

	function Firing:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "End" or self.release ~= rt.None then return end
		warn_over(self)
		rt.static("Sound", "StopInstance", self.mySoundInstance)
		if self.releaseSound then self.releaseSound:Play(self) end
		self:PlayAnimation("Explode")
		self.release = self.poisonReleaseDelay
	end

	function C:OnTick()
		if base_tick then base_tick(self) end
		if self.release == rt.None or self.release > 0 then return end
		self.release = rt.None
		self:Activate(self, true)
		self:GotoState("done")
	end
end
