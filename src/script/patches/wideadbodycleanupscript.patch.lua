-- pex: ondeath 0661a661
-- OnDeath went to Dead and checked every DaysBeforeCleanup game days until the body could be cleaned
-- up. The check is now Dead's OnTick, so the living tick not at all.
local rt = require('skymod.rt')

return function(C)
	C.__fn.ontick = nil
	local Dead = rt.state(C, "Dead")

	local function wait_a_while(self)
		self.vars["ondeath.t"] = self.vars["::daysbeforecleanup_var"] * 24
	end

	function C:OnDeath(akKiller)
		self:GotoState("Dead")
		if self.vars["::deathcontainer_var"] then wait_a_while(self) end
	end

	function Dead:OnTick()
		local t = self.vars["ondeath.t"]
		if t == rt.None or t > 0 then return end
		if self:checkForCleanup() then
			self.vars["ondeath.t"] = rt.None
		else
			wait_a_while(self)
		end
	end
end
