-- pex: firetrap 9ed382fc
-- fireTrap waited initialDelay, then polled every 0.01s firing a dart every firingDelay until
-- shotcount ran out or the trap unloaded. Now a windup timer, then a per-shot cooldown timer.
-- Papyrus spaced the shots far wider than firingDelay: each pass waited a frame per native call
-- (the Wait, every link of GetNthLinkedRef, Fire), so 11 darts took 2-3 s. SHOT_EVERY keeps that.
local rt = require('skymod.rt')
local SHOT_EVERY = 0.22

return function(C)
	C.FireSeq = rt.sequence("Windup", "Firing", "Done")
	C.__vars.firestage = C.FireSeq.Done
	C.__vars.firesw = rt.timer(0.0)
	local S = C.FireSeq

	function C:FireTrap()
		if self.isfiring then return end -- a second start while firing is dropped
		self.isfiring = true
		self:ResolveLeveledWeapon()
		self.windupsound:play(self)
		self.firestage = S.Windup
		self.firesw = self.initialdelay
	end

	function C:OnTick()
		if self.firestage == S.Windup then
			if self.firesw > 0 then return end
			self.trapdisarmed = self.fireonlyonce
			self.shotcount = 0
			self.firestage = S.Firing
			self.firesw = 0.0 -- fire at once, as the first loop pass did
		end
		if self.firestage == S.Firing then
			if self.shotcount > self.numshots or not self.isloaded then
				if self.isloaded then
					self.isfiring = false
					self:GotoState("Reset")
				end
				self.firestage = S.Done
				return
			end
			if self.firesw > 0 then return end
			local firePort = rt.static("utility", "RandomInt", 0, self.numports)
			if firePort > 0 then
				self.currentlink = self:GetNthLinkedRef(firePort)
			else
				self.currentlink = self
			end
			self.dartweapon:fire(self.currentlink, self.dartammo)
			self.shotcount = self.shotcount + 1
			if self.loop then self:ResetLimiter() end
			self.firesw = math.max(self.firingdelay, SHOT_EVERY)
		end
	end
end
