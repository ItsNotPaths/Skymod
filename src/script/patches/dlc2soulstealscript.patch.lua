-- pex: playertakessoulback 37a6496e 20b3e364
-- PlayerTakesSoulBack waited 1 s before absorbing the soul. The class already has OnTick from the
-- S6 split (AbsorbSoulFromMiraak's own wait); ours calls it first, then checks this new timer.
local rt = require('skymod.rt')

return function(C)
	C.__vars.ptsT = rt.timer(0.0)
	C.__vars.ptsPending = rt.bool(false)
	C.__vars.ptsAbsorbing = rt.bool(false) -- the absorb runs; the soul counts when it ends

	function C:PlayerTakesSoulBack()
		if self.ptsPending or self.ptsAbsorbing then return end -- a second start while one runs is dropped
		self.ptsPending = true
		self.ptsT = 1.0 -- fresh wait: ptsT idles between scenes
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.ptsPending and self.ptsT <= 0 then
			self.ptsPending, self.ptsAbsorbing = false, true
			self:AbsorbSoulFromMiraak(self.Miraak:GetActorReference())
		elseif self.ptsAbsorbing and self.vars["absorbsoulfrommiraak.t"] == rt.None then
			self.ptsAbsorbing = false -- AbsorbSoulFromMiraak's 7 s are over, as Papyrus waited
			rt.static("Game", "GetPlayer"):modActorValue("dragonsouls", 1)
			self:ModDLC2SoulStealCount(-1)
		end
	end
end
