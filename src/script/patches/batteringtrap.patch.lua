-- pex: firetrap 055b400b
-- fireTrap wound up (initialDelay), then while not finished and loaded swung (waiting for
-- BackSwing) and polled every 0.5 s for the "reset" event; a looping trap swung again. At the end
-- it reset. Now `swing` is the stage of that run, stepped by the events and OnTick. TrapBase owns
-- the trap's states, so OnTick is on the class and returns at once when no run is under way.
local rt = require('skymod.rt')

return function(C)
	C.Swing = rt.sequence("Idle", "Windup", "Swinging", "AwaitReset")
	local S = C.Swing
	C.__vars.swing = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local converted_event = C.__fn.onanimationevent -- sets resetEventRecieved on "reset"

	function C:fireTrap()
		if self.swing ~= S.Idle then return end -- a run happens once
		self.WindupSound:Play(self)
		self:ResolveLeveledDamage()
		self.swing = S.Windup
		self.t = self.initialDelay
	end

	local function next_swing(self)
		if self.finishedPlaying or not self.isLoaded then
			self.swing = S.Idle
			self:UnregisterForAnimationEvent(self, "reset")
			self:GotoState("Reset")
			self:PlayAnimation("reset") -- nothing followed its wait
			return
		end
		self.hitBase:GotoState("CanHit")
		self.swing = S.Swinging
		self:RegisterForAnimationEvent(self, "BackSwing")
		self:PlayAnimation("Trigger")
	end

	function C:OnTick()
		if self.swing == S.Idle then return end
		if self.swing == S.Windup and self.t <= 0 then
			self:RegisterForAnimationEvent(self, "reset")
			if self.fireOnlyOnce then self.trapDisarmed = true end
			next_swing(self)
		elseif self.swing == S.AwaitReset and (self.resetEventRecieved or not self.isLoaded) then
			self.finishedPlaying = true
			self.resetEventRecieved = false
			if self.loop then self:resetLimiter() end
			next_swing(self)
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		converted_event(self, akSource, asEventName)
		if self.swing == S.Swinging and akSource == self and asEventName == "BackSwing" then
			self.hitBase:GotoState("CannotHit")
			self.swing = S.AwaitReset
			self:OnTick()
		end
	end

	-- a cell that detaches mid-swing sends no event: the run ends here, OnCellAttach restarts it
	function C:OnCellDetach()
		rt.parent(self, "BatteringTrap", "OnCellDetach") -- MovingTrap: isLoaded = false
		if self.swing == S.Swinging then self.swing = S.Idle end
	end
end
