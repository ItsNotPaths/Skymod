-- pex: waiting.onactivate 6f2035ec
-- OnActivate stayed Busy while StartPlayerInteraction set up and cast (about 5 s). That call now
-- returns at once, so the supplies stay Busy until the system's `cast` run is Idle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	function Waiting:OnActivate(akActivatorRef)
		self:GotoState("Busy")
		if akActivatorRef == rt.static("Game", "GetPlayer") then self.FishingSystem:StartPlayerInteraction(self) end
		self:OnTick()
	end

	function Busy:OnTick()
		if self.FishingSystem.cast.name ~= "Idle" then return end
		self:GotoState("Waiting")
	end
end
