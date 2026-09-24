-- pex: playertakessoulback 37a6496e
-- PlayerTakesSoulBack waited 1 s before absorbing the soul. The class already has OnTick from the
-- S6 split (AbsorbSoulFromMiraak's own wait); ours calls it first, then checks this new timer.
local rt = require('skymod.rt')

return function(C)
	C.__vars.ptsT = rt.timer(0.0)
	C.__vars.ptsPending = rt.bool(false)

	function C:PlayerTakesSoulBack()
		if self.ptsPending then return end -- a second start while one runs is dropped
		self.ptsPending = true
		self.ptsT = 1.0 -- fresh wait: ptsT idles between scenes
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.ptsPending and self.ptsT <= 0 then
			self.ptsPending = false
			self:AbsorbSoulFromMiraak(self.Miraak:GetActorReference())
			rt.static("Game", "GetPlayer"):modActorValue("dragonsouls", 1)
			self:ModDLC2SoulStealCount(-1)
		end
	end
end
