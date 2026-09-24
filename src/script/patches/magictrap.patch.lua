-- pex: firetrap 076fbabf
-- FireTrap cast once, waited firingSpinup, then waited firingRate (an absolute deadline, polled
-- every 0.3 s so overrideLoop/isLoaded/mySoulGem could cut it short) and repeated while Loop was
-- set. Now a Spinup/Cooldown sequence; the class already has a split OnTick (the "pause" state
-- timer), so this one calls it first.
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", "magictrap " .. tostring(self.form) .. ": " .. msg) end

return function(C)
	local tick_before = C.__fn.ontick -- the S6 split's class-level OnTick (pause.onbeginstate timer)

	C.Fire = rt.sequence("Idle", "Spinup", "Cooldown")
	C.__vars.fire = C.Fire.Idle
	C.__vars.fireClock = rt.timer(0.0)

	local function concentration(self)
		return self.aaspelltocast == 2 or self.aaspelltocast == 5 or self.aaspelltocast == 7
	end

	local function alive(self)
		return self.isloaded and self.mysoulgem and self.mysoulgem:isEnabled()
	end

	local function stop_firing(self)
		self.fire = C.Fire.Idle
		if self.isloaded then
			self.isfiring = false
			self:GotoState("Reset")
		end
	end

	function C:FireTrap()
		self.isfiring = true
		self.overrideloop = false
		if not self.gemtested and self:GetLinkedRef():isEnabled() then
			self:TestRefIsSoulGem(self.trapself:GetLinkedRef())
		end
		self:ResetLimiter() -- finishedFiring = false
		if not alive(self) then
			trace(self, "not loaded or no soul gem, not firing")
			return stop_firing(self)
		end
		self.fire, self.fireClock = C.Fire.Spinup, self.firingspinup
		trace(self, "spinup, cast in " .. tostring(self.firingspinup) .. "s")
	end

	function C:OnTick()
		tick_before(self)
		if self.fire == C.Fire.Idle then return end
		if self.fire == C.Fire.Cooldown and (self.overrideloop or not alive(self)) then
			trace(self, "overrideLoop or unloaded, stopping early")
			if concentration(self) then
				self.concentrationcastloop = false
				self:InterruptCast()
			end
			return stop_firing(self)
		end
		if self.fireClock > 0 then return end
		if self.fire == C.Fire.Spinup then
			if not alive(self) then return stop_firing(self) end
			if concentration(self) then
				if not self.concentrationcastloop then
					self:FireByCastingType()
					self.concentrationcastloop = true
				end
			else
				self:FireByCastingType()
			end
			self.finishedfiring = true
			self.fire, self.fireClock = C.Fire.Cooldown, self.firingrate
			trace(self, "cast, cooldown " .. tostring(self.firingrate) .. "s")
		elseif self.fire == C.Fire.Cooldown then
			if concentration(self) then
				self.concentrationcastloop = false
				self:InterruptCast()
			end
			if self.loop then
				self:ResetLimiter()
				self.fire, self.fireClock = C.Fire.Spinup, self.firingspinup
				trace(self, "loop: spinup again in " .. tostring(self.firingspinup) .. "s")
			else
				trace(self, "not looping, done")
				stop_firing(self)
			end
		end
	end
end
