-- pex: firetrap 0b0d0926
-- fireTrap wound up for initialDelay, then while loaded played Trigger01 and waited for its
-- startDamage, stopDamage and "done" events to arm and disarm the hit base, and finally reset.
-- The loop runs once unless a trigger resets the limiter. Now `fire` is the step, the windup a
-- timer, the events the rest. A cell detach ends the run, as the unloaded wait did.
local rt = require('skymod.rt')

return function(C)
	C.Fire = rt.sequence("Idle", "Windup", "Loop", "Start", "Stop", "Done")
	local S = C.Fire
	C.__vars.fire = S.Idle
	C.__vars.fire_t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local detach = C.__fn.oncelldetach or rt.load("MovingTrap").__fn.oncelldetach

	function C:fireTrap()
		if self.fire ~= S.Idle then return end
		self:ResolveLeveledDamage()
		self.isFiring = true
		if self.WindupSound then self.WindupSound:Play(self) end
		self.fire = S.Windup
		self.fire_t = self.initialDelay
	end

	function C:OnTick()
		if self.fire == S.Idle or self.fire_t > 0 then return end
		if self.fire == S.Windup then
			if self.fireOnlyOnce then self.trapDisarmed = true end
			self.fire = S.Loop
		end
		if self.fire ~= S.Loop then return end
		if not self.finishedPlaying and self.isLoaded then
			self.fire = S.Start
			self:RegisterForAnimationEvent(self, self.startDamage)
			self:RegisterForAnimationEvent(self, self.stopDamage)
			self:RegisterForAnimationEvent(self, "done")
			self:PlayAnimation("Trigger01")
			return
		end
		self.fire = S.Idle
		if self.isLoaded then
			self.isFiring = false
			self:GotoState("Reset")
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.fire == S.Start and asEventName == self.startDamage then
			self.hitBase:GotoState("CanHit")
			self.finishedPlaying = true
			self.fire = S.Stop
		elseif self.fire == S.Stop and asEventName == self.stopDamage then
			self.hitBase:GotoState("CannotHit")
			self.fire = S.Done
		elseif self.fire == S.Done and asEventName == "done" then
			if self.Loop then self:ResetLimiter() end
			self.fire = S.Loop -- wait(0.0): the next pass is the next tick
		end
	end

	function C:OnCellDetach()
		detach(self)
		if self.fire ~= S.Windup then self.fire = S.Idle end
	end
end
