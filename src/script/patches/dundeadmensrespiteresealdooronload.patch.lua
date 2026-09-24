-- pex: onload 33552d52
-- OnLoad waited 0.25 s before setting up the sealed door. A timer now gates the same call.
local rt = require('skymod.rt')

return function(C)
	C.__vars.rsT = rt.timer(0.0)
	C.__vars.rsPending = rt.bool(false)

	function C:OnLoad()
		if self.rsPending then return end -- a second start while one runs is dropped
		self.rsPending = true
		self.rsT = 0.25 -- fresh wait: rsT idles between loads
	end

	function C:OnTick()
		if not self.rsPending or self.rsT > 0 then return end
		self.rsPending = false
		rt.cast(self.SealedDoorRef, "dundeadmensrespitesealeddoor"):SetupSealedDoor()
	end
end
