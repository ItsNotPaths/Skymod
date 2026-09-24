-- pex: active.onactivate 3359a6b2
-- pex: mustfight.onactivate 2f724e13
-- pex: waiting.onactivate 572ab0e4
-- pex: active.onhit 7d2288f8
-- pex: mustfight.onhit f359f24f
-- pex: waiting.onhit e837e72c
-- pex: teleporttosafety 23929f23
-- teleportToSafety placed SummonFX, waited 1s, moved to SafePosition + placed SummonFX again,
-- waited 0.5s, then evaluated the package and adjusted health. Now a two-stage timer, read from the
-- class OnTick the S6 split already writes for doTeleport (called first). active.onactivate,
-- mustfight.onactivate and mustfight.onhit only tail-call doTeleport, already non-blocking via that
-- split; they need no change. active.onhit tail-calls teleportToSafety with nothing after, so it
-- needs no change either, now that teleportToSafety itself returns at once.
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick
	C.Step = rt.sequence("Idle", "Placed", "Moved")
	C.__vars.safetyStep = C.Step.Idle
	C.__vars.safetyT = rt.timer(0.0)
	C.__vars.activateAfterSafety = rt.bool(false)
	local S = C.Step
	local Waiting = rt.state(C, "waiting")

	function C:teleportToSafety()
		if self.safetyStep ~= S.Idle then return end -- a hit during the run is dropped
		self:PlaceAtMe(self.SummonFX)
		self.safetyStep = S.Placed
		self.safetyT = 1.0
	end

	function C:OnTick()
		split_tick(self)
		if self.safetyStep == S.Placed and self.safetyT <= 0 then
			self:MoveTo(self.SafePosition)
			self:PlaceAtMe(self.SummonFX)
			self.safetyStep = S.Moved
			self.safetyT = 0.5
		end
		if self.safetyStep == S.Moved and self.safetyT <= 0 then
			self.safetyStep = S.Idle
			self:EvaluatePackage()
			self:AdjustHealth()
			if self.activateAfterSafety then
				self.activateAfterSafety = false
				self.BossController:Activate(self)
				self:GotoState("Active")
			end
		end
	end

	function Waiting:OnActivate(triggerRef)
		self.activateAfterSafety = true
		self:teleportToSafety()
	end

	function Waiting:OnHit(akAggressor, akSource, akProjectile, abPowerAttack, abSneakAttack, abBashAttack, abHitBlocked)
		if self:GetAVPercentage("health") <= 0.1 then return end
		if self.endTeleportTimer > rt.static("Utility", "GetCurrentGameTime") then return end
		self.endTeleportTimer = rt.static("Utility", "GetCurrentGameTime") + 1.0
		self.activateAfterSafety = true
		self:teleportToSafety()
	end
end
