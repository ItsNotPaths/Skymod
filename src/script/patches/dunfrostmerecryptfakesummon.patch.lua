-- pex: summon a526eb25
-- Summon placed its FX, waited 1 s, then enabled. A timer now gates the enable.
local rt = require('skymod.rt')

return function(C)
	C.__vars.smT = rt.timer(0.0)
	C.__vars.smPending = rt.bool(false)

	function C:Summon()
		if self:IsDead() or self.summoned then return end
		if self.smPending then return end -- a second start while one runs is dropped
		self:PlaceAtMe(self.SummonFX)
		self.smPending = true
		self.smT = 1.0 -- fresh wait: smT idles between Summon/Banish cycles
	end

	function C:OnTick()
		if not self.smPending or self.smT > 0 then return end
		self.smPending = false
		self:EnableNoWait(true)
		self.summoned = true
	end
end
