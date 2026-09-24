-- pex: dropoilpools 2a3d7193 1d20d265
-- pex: ondying 62b994c5
-- pex: onhit 7e28d3b8 642c1d0b
-- pex: onload bf58d86c
-- pex: spidercrumble bc0b94a6 130c130c
-- DropOilPools looped while bPlaceOil: in combat, drop an oil pool, then wait
-- fTimeBetweenPlacement. The loop is now OnTick in the running state. SpiderCrumble's closing
-- Wait(1) held nothing: every caller calls it last.
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick -- this class's S6 split waits; an OnTick here must run them
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.placeT = rt.timer(0.0)
	local Running = rt.state(C, "Running")

	function C:DropOilPools()
		if self:GetState() == "Running" then return end -- a run happens once
		self.placeT = 0.0
		self:GotoState("Running")
		self:OnTick()
	end

	function Running:OnTick()
		if split_tick then split_tick(self) end
		if self.placeT > 0 then return end
		if not self.bPlaceOil then return self:GotoState("") end
		if self:IsDead() then
			self.bPlaceOil = false
		elseif self:IsInCombat() then
			self:PlaceAtMe(self.OilPool):SetAngle(0, 0, 0)
		end
		self.placeT = self.placeT + self.fTimeBetweenPlacement
	end

	function C:SpiderCrumble()
		self:PlaceAtMe(self.DLC2ExpSpiderOilCrumbleExplosion)
		self:DisableNoWait()
	end
end
