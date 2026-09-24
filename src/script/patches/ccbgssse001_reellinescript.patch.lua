-- pex: waiting.onactivate dc0882d7
-- OnActivate stayed Busy while the system reeled in (catch result, fanfare) or set up again. Those
-- calls now return at once, so the activator stays Busy until the system's `cast` and `handling`
-- runs are Idle.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy = rt.state(C, "Waiting"), rt.state(C, "Busy")

	function Waiting:OnActivate(akActivatorRef)
		self:GotoState("Busy")
		if akActivatorRef == rt.static("Game", "GetPlayer") then self.FishingSystem:OnFishingTriggerActivated() end
		self:OnTick()
	end

	function Busy:OnTick()
		local fs = self.FishingSystem
		if fs.cast.name ~= "Idle" or fs.handling.name ~= "Idle" then return end
		self:GotoState("Waiting")
	end
end
