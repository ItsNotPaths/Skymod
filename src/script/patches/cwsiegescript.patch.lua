-- pex: setupinteriorsiege 6a5f69b3
-- SetupInteriorSiege polled CWFortSiegeCapital.IsStopped() every 1s, then called
-- SendStoryEventAndWait (immediate, script-api.md section 4) and SendStoryEvent. Now a bool that
-- OnTick polls; once the capital siege has stopped, both sends run in that same tick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(1.0)
	C.__vars.siegeWaiting = rt.bool(false)
	C.__vars.siegeLoc = rt.form("Location")
	C.__vars.siegeFieldCO = rt.form("ObjectReference")
	C.__vars.siegeCenter = rt.form("ObjectReference")

	function C:SetupInteriorSiege(SiegeLocation, FieldCORef, CityCenterMarker)
		if self.siegeWaiting then return end -- a second start while waiting is dropped
		self.siegeLoc, self.siegeFieldCO, self.siegeCenter = SiegeLocation, FieldCORef, CityCenterMarker
		self.siegeWaiting = true
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if not self.siegeWaiting then return end
		if not self.CWs.CWFortSiegeCapital:IsStopped() then return end
		self.siegeWaiting = false
		self.CWs.CWFortSiegeSpecialStart:SendStoryEventAndWait(self.siegeLoc, self.siegeFieldCO, self.siegeCenter, 3)
		self.CWs.CWFinaleStart:SendStoryEvent(self.siegeLoc)
	end
end
