-- DropOilPools looped while bPlaceOil: in combat, drop an oil pool, then wait
-- fTimeBetweenPlacement. The loop is now OnTick in the running state. SpiderCrumble's closing
-- Wait(1) held nothing: every caller calls it last.
local rt = require('skymod.rt')

return function(C)
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
