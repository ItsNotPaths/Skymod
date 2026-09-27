-- pex: ondying 6f20fb8a
-- OnDying started the disintegrate, waited 1.65 s for it to play, then set its end stage. The wait
-- is now a state entered only then, so an alias ticks only while its actor is disintegrating.
local rt = require('skymod.rt')

return function(C)
	C.__fn.ontick = nil
	local Disintegrating = rt.state(C, "Disintegrating")

	function C:OnDying(akKiller)
		if not self.vars["::disintegrateonload_var"] then return end
		local actor = self:GetActorReference()
		actor:SetAlpha(0.0, false)
		actor:SetCriticalStage(actor.CritStage_DisintegrateEnd)
		actor:AttachAshPile(self.vars["::defaultashpile1_var"])
		self.vars["ondying.t"] = 1.65
		self:GotoState("Disintegrating")
	end

	function Disintegrating:OnDying(akKiller) end

	function Disintegrating:OnTick()
		if self.vars["ondying.t"] > 0 then return end
		self.vars["ondying.t"] = rt.None
		local actor = self:GetActorReference()
		actor:SetCriticalStage(actor.CritStage_DisintegrateEnd)
		self:GotoState("")
	end
end
