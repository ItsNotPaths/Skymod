-- pex: fragment_0 f1d33c14
-- Fragment_0 ended this quest (stage 200) once CallOdahviingToDragonsreach returned, 10 s after the
-- call when MQ301 took over. It now waits (`endOwed`) until MQ301 leaves "OdahviingArriving",
-- beside the split Fragment_10 tick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.endOwed = rt.bool(false) -- MQ301 took over; this quest ends once Odahviing has arrived
	local split_tick = C.__fn.ontick

	local function mq301(self) return rt.cast(self.MQ301, "MQ301Script") end

	function C:Fragment_0()
		if self.endOwed then return end
		if mq301(self):CallOdahviingToDragonsreach() then
			self.endOwed = true
			return self:OnTick()
		end
		-- the player has not called Odahviing to Dragonsreach yet: a flyby
		rt.cast(self, "MQCallDragonScript"):CallDragon(self.Alias_Dragon:GetActorRef(), self.Alias_SummonMarker:GetRef(),
			self.Alias_SummonMarker2:GetRef())
	end

	function C:OnTick()
		split_tick(self)
		if not self.endOwed or mq301(self):GetState() == "OdahviingArriving" then return end
		self.endOwed = false
		self:SetStage(200)
	end
end
