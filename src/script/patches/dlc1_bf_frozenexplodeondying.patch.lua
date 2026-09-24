-- pex: ondying c365390f
-- OnDying waited an optional DelayBeforeExplode, placed the explosion, waited 0.001, then disabled
-- and waited 10 (nothing followed the last wait). Now a stage plus one timer that the class's
-- existing OnTick (from the transpiled OnLoad wait) drives.
local rt = require('skymod.rt')

return function(C)
	local S = rt.sequence("Idle", "Delaying", "Placed", "Disabled")
	C.DyingStage = S
	C.__vars.dyingStage = S.Idle
	C.__vars.dyingT = rt.timer(0.0)

	function C:OnDying(akKiller)
		if self.dyingStage ~= S.Idle then return end -- a run happens once
		self.dyingStage = S.Delaying
		self.dyingT = self.delaybeforeexplode > 0 and self.delaybeforeexplode or 0.0
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.dyingStage == S.Idle or self.dyingT > 0 then return end
		if self.dyingStage == S.Delaying then
			self:PlaceAtMe(self.dlc1frozenfalmerexplosion)
			self.dyingStage = S.Placed
			self.dyingT = 0.001
		elseif self.dyingStage == S.Placed then
			self:Disable()
			self.dyingStage = S.Disabled
			self.dyingT = 10
		end
	end
end
