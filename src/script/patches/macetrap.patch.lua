-- pex: firetrap abe15943
-- FireTrap ran once (doOnce): windup wait(initialDelay), two impulses, then wait(hitTime) before
-- the hit window closes. Now a two-stage sequence; each wait is read once, at its stage's start.
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", "macetrap " .. tostring(self.form) .. ": " .. msg) end

return function(C)
	C.Fire = rt.sequence("Idle", "Windup", "HitWindow", "Done")
	C.__vars.fire = C.Fire.Idle
	C.__vars.fireClock = rt.timer(0.0)

	function C:FireTrap()
		if self.fire ~= C.Fire.Idle then return end -- doOnce
		self.fire, self.fireClock = C.Fire.Windup, self.initialdelay
		trace(self, "windup, hits in " .. self.initialdelay .. "s")
		self.hitbase:GotoState("CanHit")
		self:SetMotionType(1, true)
		self.windupsound:play(self)
		self:ResolveLeveledDamage()
	end

	function C:OnTick()
		if self.fire == C.Fire.Idle or self.fire == C.Fire.Done or self.fireClock > 0 then return end
		if self.fire == C.Fire.Windup then
			trace(self, "hit")
			self:ApplyHavokImpulse(0.0, 0.0, -1.0, 15.0)
			self:ApplyHavokImpulse(0.0, 0.0, -1.0, 50.0)
			if self.hittime > 0 then
				self.fire, self.fireClock = C.Fire.HitWindow, self.hittime
			else
				self.fire = C.Fire.Done
			end
		elseif self.fire == C.Fire.HitWindow then
			trace(self, "hit window closes")
			self.hitbase:GotoState("CannotHit")
			self.fire = C.Fire.Done
		end
	end
end
