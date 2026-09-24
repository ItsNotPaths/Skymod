-- pex: observerdotransform d5670ea8
-- ObserverDoTransform registered for the "SetRace" animation event, then waited a flat 10s as a
-- fallback, calling ObserverActuallyTransform either way (already converted, unchanged, and
-- itself guards re-entry with __transformtracked). The flat wait becomes a timer OnTick reads;
-- whichever comes first, the event or the timer, wins, and the second call is a no-op.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.5)
	C.__vars.transformFallback = rt.timer(rt.None)
	local converted_tick = C.__fn.ontick -- the FightStart kill sequence's own split tick

	function C:ObserverDoTransform()
		local obs = self.Observer:GetActorReference()
		self.__observerOriginalRace = obs:GetActorBase():GetRace()
		obs:GetActorBase():SetInvulnerable(true)
		self.WerewolfChangeFX:Cast(obs)
		self:RegisterForAnimationEvent(obs, "SetRace")
		self.transformFallback = 10.0
	end

	function C:OnTick()
		converted_tick(self)
		if self.transformFallback == rt.None or self.transformFallback > 0 then return end
		self.transformFallback = rt.None
		self:ObserverActuallyTransform()
	end
end
