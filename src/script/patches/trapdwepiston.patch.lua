-- pex: firetrap 5a239de9
-- fireTrap wound up for initialDelay (not when it starts swung), fired once (fireAnim until
-- fireEvent, or the startSwung pose at once), checked Loop every 0.5 s and reset (resetAnim until
-- resetEvent). Now `run` is the step, OnTick the windup and the checks, and the events end the
-- moves. TrapBase's trigger states change during a run, so OnTick is on the class.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "Windup", "Attacking", "Holding", "Resetting")
	local R = C.Run
	C.__vars.run = R.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	local pass
	local function finish(self)
		if not self.isLoaded then
			self.run = R.Idle -- isFiring stays set: OnCellAttach fires again
			return
		end
		self.isFiring = false
		self.run = R.Resetting
		self:RegisterForAnimationEvent(self, self.resetEvent)
		self:PlayAnimation(self.resetAnim)
	end

	local function end_pass(self)
		self.finishedPlaying = true
		if self.loop then self:ResetLimiter() end
		pass(self)
	end

	pass = function(self)
		if self.finishedPlaying or not self.isLoaded then return finish(self) end
		if self.hasPlayedAttackAnimOnce then
			self.run = R.Holding
			self.t = 0.5
			return
		end
		self.hasPlayedAttackAnimOnce = true
		if self.startSwung then
			self.startSwung = false
			self:PlayAnimation(self.startSwungAnim)
			return end_pass(self)
		end
		self.run = R.Attacking
		self:RegisterForAnimationEvent(self, self.fireEvent)
		self:PlayAnimation(self.fireAnim)
	end

	function C:fireTrap()
		if self.run ~= R.Idle then return end -- a run happens once
		self.isFiring = true
		self.t = 0.0
		if not self.startSwung then
			if self.WindupSound then self.WindupSound:Play(self) end
			self.t = self.initialDelay
		end
		self.run = R.Windup
		self:OnTick()
	end

	function C:OnTick()
		if self.t > 0 then return end
		if self.run == R.Windup then
			self.hasPlayedAttackAnimOnce = false
			if self.fireOnlyOnce then self.trapDisarmed = true end
			self.finishedPlaying = false
			pass(self)
		elseif self.run == R.Holding then
			end_pass(self)
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.run == R.Attacking and asEventName == self.fireEvent then
			end_pass(self)
		elseif self.run == R.Resetting and asEventName == self.resetEvent then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end

	function C:OnCellDetach()
		rt.parent(self, "TrapDwePiston", "OnCellDetach")
		if self.run == R.Attacking then
			self.run = R.Idle
		elseif self.run == R.Resetting then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end
end
