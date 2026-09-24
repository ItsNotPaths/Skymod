-- pex: runupdate ac43a308
-- pex: updateloop 63142a33
-- Folgunthur's RunUpdate/UpdateLoop are the same 1s-cadence shape as the RefAlias parent's, plus
-- FindLivingAliases after a successful pass. The class already ticks (the S6 split's OnHit timer);
-- this patch's OnTick calls that first, then the parent's burst helpers (self:RunUpdate() inside
-- them resolves back to this class's own override, so the burst and the ally update stay in step).
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick -- OnHit's own wait, from the S6 split

	function C:UpdateLoop()
		self.runT = 0.0
	end

	function C:RunUpdate()
		rt.parent(self, "dunFolgunthurBossBattle", "RunUpdate")
		if self.isactive then self:FindLivingAliases() end
	end

	function C:OnTick()
		split_tick(self)
		self:_pcsRunTick()
		self:_pcsBurstTick()
		self:_pcsKillTick()
	end
end
