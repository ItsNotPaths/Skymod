-- pex: firetrap 12e72769
-- fireTrap waited initialDelay for the windup, then fired and waited for fireEvent, again while
-- `loop` held, and reset. Now `firing` is the step: OnTick ends the windup, the event ends each
-- shot. The trap's states belong to TrapBase (they take activations during a run), so the run
-- lives at class level; a detach mid-shot ends the run, and the attach fires again as before.
local rt = require('skymod.rt')

return function(C)
	C.Fire = rt.sequence("Idle", "Windup", "Shooting")
	local F = C.Fire
	C.__vars.firing = F.Idle
	C.__vars.windup = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)
	local detach = C.__fn.oncelldetach

	local function finish(self)
		self.firing = F.Idle
		if not self.isLoaded then return end
		self.isFiring = false
		self.hitBase:GotoState("CannotHit")
		self:GotoState("Reset")
	end

	local function shoot(self)
		if self.finishedPlaying or not self.isLoaded then return finish(self) end
		self.firing = F.Shooting
		self:RegisterForAnimationEvent(self, self.fireEvent)
		self:PlayAnimation(self.fireAnim)
	end

	function C:fireTrap()
		if self.firing ~= F.Idle then return end
		self.isFiring = true
		self:ResolveLeveledDamage()
		self.hitBase:GotoState("CanHit")
		if self.WindupSound then self.WindupSound:Play(self) end
		self.firing = F.Windup
		self.windup = self.initialDelay
		self:OnTick()
	end

	function C:OnTick()
		if self.firing ~= F.Windup or self.windup > 0 then return end
		if self.fireOnlyOnce then self.trapDisarmed = true end
		self.finishedPlaying = false
		shoot(self)
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if self.firing ~= F.Shooting or akSource ~= self or asEventName ~= self.fireEvent then return end
		self.finishedPlaying = true
		if self.Loop then self:ResetLimiter() end
		shoot(self)
	end

	function C:OnCellDetach()
		detach(self)
		if self.firing == F.Shooting then self.firing = F.Idle end -- no end event comes now
	end
end
