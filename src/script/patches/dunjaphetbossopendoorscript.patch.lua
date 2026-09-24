-- pex: ondeath 687dd218
-- Japhet's death opened his six poles one after another (each SetOpen waited for its animation).
-- Now `pole_at` is the pole being opened; OnTick in Opening waits while it animates.
local rt = require('skymod.rt')

return function(C)
	C.__vars.pole_at = rt.int(0)
	C.__vars.TickRate = rt.float(0.1)
	local Opening = rt.state(C, "Opening")

	local function pole(self, n) return rt.cast(self["pole0" .. n], "default2StateActivator") end

	function C:OnDeath(akKiller)
		if self:GetState() == "Opening" then return end
		self.pole_at = 1
		pole(self, 1):SetOpen(true)
		self:GotoState("Opening")
	end

	function Opening:OnTick()
		if pole(self, self.pole_at).isAnimating then return end
		if self.pole_at == 6 then return self:GotoState("") end
		self.pole_at = self.pole_at + 1
		pole(self, self.pole_at):SetOpen(true)
	end
end
