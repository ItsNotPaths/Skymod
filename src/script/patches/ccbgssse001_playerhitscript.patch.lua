-- pex: waiting.onhit 37046fce
-- OnHit called FishingSystem.OnPlayerHit, which the S6 splitter already turned start-and-return
-- (DoCleanupTasks -> CleanUp -> CleanUpFishingRodActivator carries its own timer guard). No wait
-- reaches this function, so the Hit/Waiting mutex needs no change; kept as-is for the pin.
local rt = require('skymod.rt')

return function(C)
	local Waiting = rt.state(C, "Waiting")

	function Waiting:OnHit(akAggressor, akSource, akProjectile, abPowerAttack, abSneakAttack, abBashAttack, abHitBlocked)
		self:GotoState("Hit")
		self.fishingsystem:OnPlayerHit()
		self:GotoState("Waiting")
	end
end
