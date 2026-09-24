-- pex: onequipped b44c0dd0
-- OnEquipped polled IsWeaponDrawn every 0.1s, then (once, per doOnce) waited 0.3s and played the
-- streak effect. Both waits are now timers, gated by OnTick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.pendingActor = rt.form("Actor")
	C.__vars.waiting = rt.bool(false)
	C.__vars.fxT = rt.timer(-1.0) -- negative: no streak-effect wait pending

	function C:OnEquipped(akActor)
		if self.waiting or self.fxT >= 0 then return end -- a second start is dropped
		self.pendingActor = akActor
		self.waiting = true
	end

	function C:OnTick()
		if self.waiting then
			if not self.pendingActor:IsWeaponDrawn() then return end
			self.waiting = false
			if self.doonce == 0 then self.fxT = 0.3 end
			return
		end
		if self.fxT < 0 or self.fxT > 0 then return end
		self.fxT = -1.0
		self.fxdraugrmagicswordstreakeffect:Play(self.pendingActor, -1)
		self.doonce = 1
	end
end
