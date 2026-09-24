-- pex: firetrap 43ce30ce
-- fireTrap wound up for initialDelay, fired once (fireAnim until fireEvent), checked Loop every
-- 0.5 s, waited ReturnDelay and returned (resetAnim until resetEvent). Now `run` is the step,
-- OnTick the timers, and the events end the moves. TrapBase's trigger states change during a
-- run, so OnTick is on the class.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "Windup", "Attacking", "Holding", "Returning", "Resetting")
	local R = C.Run
	C.__vars.run = R.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	local pass
	local function end_loop(self)
		self.myHazardBase:GotoState("CannotHit")
		self.resetSpeedString = self.resetAnim
		self:SetAnimationVariableFloat(self.resetSpeedString, self.ReturnSpeed)
		self.run = R.Returning
		self.t = self.ReturnDelay
	end

	local function end_pass(self)
		self.finishedPlaying = true
		if self.loop then self:ResetLimiter() end
		pass(self)
	end

	pass = function(self)
		if self.finishedPlaying or not self.isLoaded then return end_loop(self) end
		if self.hasPlayedAttackAnimOnce then
			self.run = R.Holding
			self.t = 0.5
			return
		end
		self.fireSpeedString = self.FireAnim -- Papyrus dropped its `+ "s"`
		self:SetAnimationVariableFloat(self.fireSpeedString, self.FireSpeed)
		self.run = R.Attacking
		self:RegisterForAnimationEvent(self, self.fireEvent)
		self:PlayAnimation(self.fireAnim)
	end

	function C:fireTrap()
		if self.run ~= R.Idle then return end -- a run happens once
		self.isFiring = true
		self.myHazardBase:GotoState("CanHit")
		self.WindupSound:Play(self)
		self:ResolveLeveledDamage()
		self:SetResetAnim()
		self:SetFireAnim()
		self.run = R.Windup
		self.t = self.initialDelay
		self:OnTick()
	end

	function C:OnTick()
		if self.t > 0 then return end
		if self.run == R.Windup then
			self.hasPlayedAttackAnimOnce = false
			if self.fireOnlyOnce then self.trapDisarmed = true end
			pass(self)
		elseif self.run == R.Holding then
			end_pass(self)
		elseif self.run == R.Returning then
			if not self.isLoaded then
				self.run = R.Idle -- isFiring stays set: OnLoad fires again
				return
			end
			self.isFiring = false
			self.run = R.Resetting
			self:RegisterForAnimationEvent(self, self.resetEvent)
			self:PlayAnimation(self.resetAnim)
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.run == R.Attacking and asEventName == self.fireEvent then
			self.hasPlayedAttackAnimOnce = true
			end_pass(self)
		elseif self.run == R.Resetting and asEventName == self.resetEvent then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end

	function C:OnCellDetach()
		rt.parent(self, "TrapNorPlatform", "OnCellDetach")
		if self.run == R.Attacking then
			self.run = R.Idle
		elseif self.run == R.Resetting then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end
end
