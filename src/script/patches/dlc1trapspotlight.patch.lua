-- pex: firetrap 4bcab599
-- fireTrap waited initialDelay, then cast once and waited 7 s per cycle, repeating only while
-- `loop` stayed true and the trap was loaded; the cast itself ran once (concentrationCastLoop
-- guards it). Now a stage plus one timer carries the windup and the repeat.
local rt = require('skymod.rt')

local Fire = rt.sequence("Idle", "Windup", "Casting")

return function(C)
	C.__vars.fire = Fire.Idle
	C.__vars.fireT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:fireTrap()
		self.isfiring = true
		if not self.weaponresolved then
			self:ResolveLeveledWeapon()
			self.weaponresolved = true
		end
		if self.trapdisarmed ~= false then return end
		if self.fire ~= Fire.Idle then return end -- a run happens once
		self.fire, self.fireT = Fire.Windup, self.initialdelay
	end

	function C:OnTick()
		if self.fire == Fire.Idle or self.fireT > 0 then return end
		if self.fire == Fire.Windup then
			self:resetLimiter()
			self:PlayAnimation("On")
			if not self.concentrationcastloop then
				self.magicweapon:Cast(self, rt.None)
				self.concentrationcastloop = true
			end
			self.fire, self.fireT = Fire.Casting, 7.0
			return
		end
		-- Fire.Casting: repeat every 7 s while looping and loaded, else stop
		if not self.loop or not self.isloaded then
			self:PlayAnimation("Off")
			self.concentrationcastloop = false
			self:interruptCast()
			if self.isloaded then
				self.isfiring = false
				self:GotoState("Reset")
			end
			self.fire = Fire.Idle
			return
		end
		self:resetLimiter()
		self.fireT = self.fireT + 7.0
	end
end
