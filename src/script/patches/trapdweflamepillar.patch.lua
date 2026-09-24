-- pex: firetrap 41f0f4eb
-- fireTrap wound up for initialDelay, turned once (Trigger01 until Trans01), then checked Loop
-- every 0.5 s, and reset (Reset01 until Trans02). Now `run` is the step, OnTick the windup and
-- the checks, and the events end the turns. TrapBase's trigger states change during a run, so
-- OnTick is on the class.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "Windup", "Attacking", "Holding", "Resetting")
	local R = C.Run
	C.__vars.run = R.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	local function hit(self) return rt.cast(self, "TrapDweFlamePillarHit") end

	local pass
	local function finish(self)
		hit(self):GotoState("CannotHit")
		if not self.isLoaded then
			self.run = R.Idle -- isFiring stays set: OnCellAttach fires again
			return
		end
		self.isFiring = false
		self.run = R.Resetting
		self:RegisterForAnimationEvent(self, "Trans02")
		self:PlayAnimation("Reset01")
	end

	local function end_pass(self)
		self.finishedPlaying = true
		if self.loop then self:ResetLimiter() end
		pass(self)
	end

	-- one pass of `while !finishedPlaying && isLoaded`
	pass = function(self)
		if self.finishedPlaying or not self.isLoaded then return finish(self) end
		self.isFiring = true
		if self.hasPlayedAttackAnimOnce then
			self.run = R.Holding
			self.t = 0.5
			return
		end
		self.hasPlayedAttackAnimOnce = true
		self.run = R.Attacking
		self:RegisterForAnimationEvent(self, "Trans01")
		self:PlayAnimation("Trigger01")
	end

	function C:fireTrap()
		if self.run ~= R.Idle then return end -- a run happens once
		self.isFiring = true
		hit(self):GotoState("CanHitLocal")
		if self.WindupSound then self.WindupSound:Play(self) end
		self.hasPlayedAttackAnimOnce = false
		self.run = R.Windup
		self.t = self.initialDelay
		self:OnTick()
	end

	function C:OnTick()
		if self.t > 0 then return end
		if self.run == R.Windup then
			if self.fireOnlyOnce then self.trapDisarmed = true end
			pass(self)
		elseif self.run == R.Holding then
			end_pass(self)
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.run == R.Attacking and asEventName == "Trans01" then
			end_pass(self)
		elseif self.run == R.Resetting and asEventName == "Trans02" then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end

	-- a detached trap sends no animation event: the run ends, as Papyrus's thread stalled there
	function C:OnCellDetach()
		rt.parent(self, "TrapDweFlamePillar", "OnCellDetach")
		if self.run == R.Attacking then
			self.run = R.Idle
		elseif self.run == R.Resetting then
			self.run = R.Idle
			self:GotoState("Reset")
		end
	end
end
