-- pex: ready.onactivate eb0438a5
-- OnActivate stayed Busy while the linked catapult's Reload ran. The catapult now returns at once and
-- stays in STATE_RELOADING until its "reloaded" event; this trigger stays Busy until then (OnTick in Busy).
local rt = require('skymod.rt')

return function(C)
	C.__vars.catapult = rt.form("ccBGSSSE001_CatapultCtrlScript")
	C.__vars.TickRate = rt.float(0.1)
	local Ready, Busy = rt.state(C, "Ready"), rt.state(C, "Busy")

	function Ready:OnActivate(akActionRef)
		self:GotoState("Busy")
		self.catapult = self:GetLinkedRef()
		if self.catapult then self.catapult:Reload(akActionRef) end
		self:OnTick()
	end

	function Busy:OnTick()
		if self.catapult and self.catapult.currentCatapultState == self.catapult.STATE_RELOADING then return end
		self.catapult = rt.None
		self:GotoState("Ready")
	end
end
