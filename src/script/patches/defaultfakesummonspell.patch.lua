-- pex: summon cad43820
-- Summon placed the summon effect, waited 1 s and enabled the actor. Now `summoning` is that
-- second, None when no summon runs; callers wait for it to be None.
local rt = require('skymod.rt')

return function(C)
	C.__vars.summoning = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)

	function C:Summon()
		if self:IsDead() or self.summoned or self.summoning ~= rt.None then return end
		self:PlaceAtMe(self.summonFX)
		self.summoning = 1.0
	end

	function C:OnTick()
		if self.summoning == rt.None or self.summoning > 0 then return end
		self.summoning = rt.None
		self:Enable(true)
		self.summoned = true
	end
end
