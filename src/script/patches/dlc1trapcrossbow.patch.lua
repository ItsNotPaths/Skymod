-- pex: firetrap 1bd0d8aa 45a9b054
-- pex: oncellattach 1bdf7efb 70fe5095
-- pex: reset.onbeginstate 3c36d7d1 86bfb21e
-- fireTrap wound up (initialDelay), then per shot fired and waited for "Trans02". Reset played
-- its reload and waited, with nothing after. Now OnTick ends the windup and the event steps each
-- shot. OnCellAttach's first-load check no longer waits for a resumed shot: a trap can only be
-- firing after it has loaded once.
local rt = require('skymod.rt')

return function(C)
	C.Fire = rt.sequence("Idle", "Windup", "Firing")
	local S = C.Fire
	C.__vars.fire = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Reset = rt.state(C, "Reset")
	local detach = C.__fn.oncelldetach

	local function shot(self)
		if self.shotCount <= 0 or self.shotFired or not self.isLoaded then
			self.fire = S.Idle
			if self.isLoaded then
				self.isFiring = false
				self:GotoState("Idle")
			end
			return
		end
		self:PlayAnimation("Trigger")
		self.TrapCrossbowWeapon:Fire(self.form, self.TrapCrossbowAmmo)
		self.shotCount = self.shotCount - 1
		self:RegisterForAnimationEvent(self, "Trans02")
		self.fire = S.Firing
	end

	function C:fireTrap()
		if self.lastActivateRef == rt.static("Game", "GetPlayer") then return self:playerActivated() end
		if self.TrapDisarmed or self.fire ~= S.Idle then return end
		self.isFiring = true
		if not self.weaponResolved then self:ResolveLeveledWeapon() end
		self.WindupSound:Play(self)
		self.fire = S.Windup
		self.t = self.initialDelay
		self:OnTick()
	end

	function C:OnTick()
		if self.fire == S.Windup and self.t <= 0 then shot(self) end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or self.fire ~= S.Firing or asEventName ~= "Trans02" then return end
		self.shotFired = true
		if self.loop then self:ResetLimiter() end
		shot(self)
	end

	function C:OnCellAttach()
		self.isLoaded = true
		if self.isFiring then self:fireTrap() end
		if not self.hasLoadedOnce then
			self.hasLoadedOnce = true
			if self.startDisarmed then self:GotoState("Disarmed") end
		end
	end

	-- a detached trap sends no more events: the shot ends and OnCellAttach starts it again
	function C:OnCellDetach()
		if detach then detach(self) else self.isLoaded = false end
		self.fire = S.Idle
	end

	function Reset:OnBeginState()
		self.shotCount = 1
		self:GotoState("Idle")
		self:PlayAnimation("Reset")
	end
end
