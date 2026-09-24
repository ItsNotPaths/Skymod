-- pex: firetrap fb424714
-- fireTrap armed the hit base, wound up (initialDelay), then while not finished and loaded swung
-- once and waited for "reset" (a looping trap swung again, a tick later); then it disarmed the
-- hit base and reset. Now `swing` is the stage of that run, stepped by the event and OnTick.
-- TrapBase owns the trap's states, so OnTick is on the class and returns at once when idle.
local rt = require('skymod.rt')

return function(C)
	C.Swing = rt.sequence("Idle", "Windup", "Swinging", "Between")
	local S = C.Swing
	C.__vars.swing = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:fireTrap()
		if self.swing ~= S.Idle then return end -- a run happens once
		self:ResolveLeveledDamage()
		self.hitBase:GotoState("CanHit")
		self.isFiring = true
		self.WindupSound:Play(self)
		self.swing = S.Windup
		self.t = self.initialDelay
	end

	local function next_swing(self)
		if not self.finishedPlaying and self.isLoaded then
			self.swing = S.Swinging
			self:RegisterForAnimationEvent(self, "reset")
			self:PlayAnimation("Single")
			return
		end
		self.swing = S.Idle
		if self.isLoaded then
			self.isFiring = false
			self.hitBase:GotoState("CannotHit")
			self:GotoState("Reset")
		end
	end

	function C:OnTick()
		if self.swing == S.Windup and self.t <= 0 then
			if self.fireOnlyOnce then self.trapDisarmed = true end
			next_swing(self)
		elseif self.swing == S.Between then
			next_swing(self)
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if self.swing ~= S.Swinging or akSource ~= self or asEventName ~= "reset" then return end
		self.finishedPlaying = true
		if self.loop then self:resetLimiter() end
		self.swing = S.Between -- Wait(0.0): the next swing comes a tick later
	end

	-- a cell that detaches mid-swing sends no event: the run ends here, OnCellAttach restarts it
	function C:OnCellDetach()
		rt.parent(self, "BladeTrap", "OnCellDetach") -- MovingTrap: isLoaded = false
		if self.swing == S.Swinging then self.swing = S.Idle end
	end
end
