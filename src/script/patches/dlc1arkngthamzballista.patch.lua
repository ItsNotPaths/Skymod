-- pex: firetrap 66915c07
-- pex: onload 6b491190
-- fireTrap wound up (initialDelay), then per volley played a fire animation, fired, waited for
-- its FTrans event and played the reset, waiting for RTrans. Now OnTick ends the windup and the
-- two events step each volley; `volley` is the suffix of the running one ("All" or "01".."03").
-- OnLoad's tail only posed the arms; after a resumed volley the reset already did that.
local rt = require('skymod.rt')

return function(C)
	C.Fire = rt.sequence("Idle", "Windup", "Firing", "Resetting")
	local S = C.Fire
	C.__vars.fire = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.volley = rt.string("")
	C.__vars.TickRate = rt.float(0.1)
	local unload = C.__fn.onunload

	local function finish(self)
		self.fire = S.Idle
		if self.isLoaded then
			self.isFiring = false
			self:GotoState("Reset")
		end
	end

	-- one pass of the Papyrus while loop
	local function volley(self)
		if self.shotCount <= 0 or self.shotFired or not self.isLoaded then return finish(self) end
		local me = self.form
		if self.fireAllShots then
			self.volley, self.fire = "All", S.Firing -- set before firing: re-entry after a budget cut sees a run under way
			self:PlayAnimation("TriggerAll")
			self.ballistaWeaponM:Fire(me, self.ballistaAmmo)
			self.ballistaWeaponL:Fire(me, self.ballistaAmmo)
			self.ballistaWeaponR:Fire(me, self.ballistaAmmo)
			self.shotCount = self.shotCount - 3
		else
			local n = 4 - self.shotCount -- 3 shots: arm 01, 2: 02, 1: 03
			if n < 1 or n > 3 then return finish(self) end
			self.volley, self.fire = "0" .. n, S.Firing
			self:PlayAnimation("Trigger0" .. n)
			self[({ "ballistaWeaponM", "ballistaWeaponL", "ballistaWeaponR" })[n - 1]]:Fire(me, self.ballistaAmmo)
			self.shotCount = self.shotCount - 1
		end
		self:RegisterForAnimationEvent(self, "FTrans" .. self.volley)
	end

	function C:fireTrap()
		if self.TrapDisarmed or self.fire ~= S.Idle then return end
		self.isFiring = true
		if not self.weaponResolved then self:ResolveLeveledWeapon() end
		self.WindupSound:Play(self)
		self.fire = S.Windup
		self.t = self.initialDelay
		self:OnTick()
	end

	function C:OnTick()
		if self.fire == S.Windup and self.t <= 0 then volley(self) end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.fire == S.Firing and asEventName == "FTrans" .. self.volley then
			self.fire = S.Resetting
			self:RegisterForAnimationEvent(self, "RTrans" .. self.volley)
			self:PlayAnimation("Reset" .. self.volley)
		elseif self.fire == S.Resetting and asEventName == "RTrans" .. self.volley then
			self.shotFired = true
			if self.loop then self:ResetLimiter() end
			volley(self)
		end
	end

	-- an unloaded ballista sends no more events: the volley ends and OnLoad starts it again
	function C:OnUnload()
		unload(self)
		self.fire = S.Idle
	end

	local poses = { [3] = "Reset03", [2] = "Reset01", [1] = "Reset02" }
	function C:OnLoad()
		self.isLoaded = true
		if self.isFiring then return self:fireTrap() end
		if poses[self.shotCount] then self:PlayAnimation(poses[self.shotCount]) end
	end
end
