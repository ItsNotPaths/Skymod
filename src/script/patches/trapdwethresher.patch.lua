-- pex: firetrap 91361e60
-- fireTrap wound up for initialDelay, raised the blades (TriggerUp01 until BeginAnim, except
-- MovementType 3), looped one spin per pass until EndLoop while Loop held, and lowered them
-- (until "reset" or TransStartUp). Now `run` is the step and the events end each move. TrapBase's
-- trigger states change during a run, so OnTick is on the class.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "Windup", "Rising", "Looping", "Lowering")
	local R = C.Run
	local LOOP_ANIMS = { "LoopStatic", "Loop", "LoopLong", "TriggerUpLoop" } -- by MovementType, 0-based
	C.__vars.run = R.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.lower_event = rt.string("") -- the event that ends the lowering animation playing now
	C.__vars.TickRate = rt.float(0.05)

	-- the head of `while (finishedPlaying == False && isLoaded == true)`, and what follows it
	local function loop_or_stop(self)
		if not self.finishedPlaying and self.isLoaded then
			self.run = R.Looping
			self:RegisterForAnimationEvent(self, "EndLoop")
			self:PlayAnimation(LOOP_ANIMS[self.MovementType])
			return
		end
		self.hitBase:GotoState("CannotHit")
		if not self.isLoaded then
			self.run = R.Idle -- isFiring stays set: OnCellAttach fires again
			return
		end
		self.isFiring = false
		local mt = self.MovementType
		local function begin_lowering(anim)
			self.run = R.Lowering
			self:RegisterForAnimationEvent(self, self.lower_event) -- register before playing
			self:PlayAnimation(anim)
		end
		if mt >= 0 and mt < 3 then
			self.lower_event = "reset"
			return begin_lowering("TriggerDown01")
		elseif mt == 3 then
			self.lower_event = "TransStartUp"
			return begin_lowering("TriggerEndUp")
		else
			self.run = R.Idle
			return self:GotoState("Reset")
		end
	end

	function C:fireTrap()
		if self.run ~= R.Idle then return end -- a run happens once
		self.isFiring = true
		self:ResolveLeveledDamage()
		self.hitBase:GotoState("CanHit")
		self.WindupSound:Play(self)
		self.run = R.Windup
		self.t = self.initialDelay
		self:OnTick()
	end

	function C:OnTick()
		if self.run ~= R.Windup or self.t > 0 then return end
		if self.fireOnlyOnce then self.trapDisarmed = true end
		if self.MovementType == 3 then return loop_or_stop(self) end
		self.run = R.Rising
		self:RegisterForAnimationEvent(self, "BeginAnim")
		self:PlayAnimation("TriggerUp01")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.run == R.Rising and asEventName == "BeginAnim" then
			loop_or_stop(self)
		elseif self.run == R.Looping and asEventName == "EndLoop" then
			self.finishedPlaying = true
			if self.loop then self:ResetLimiter() end
			loop_or_stop(self)
		elseif self.run == R.Lowering and asEventName == self.lower_event then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end

	function C:OnCellDetach()
		rt.parent(self, "TrapDweThresher", "OnCellDetach")
		if self.run == R.Rising or self.run == R.Looping then
			self.run = R.Idle
		elseif self.run == R.Lowering then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end
end
