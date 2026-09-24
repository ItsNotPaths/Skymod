-- pex: onload d71ff4ff
-- OnLoad waited 5s, then (if doOnce and loaded) placed the explosion, cleared doOnce, waited 0.1s,
-- disabled, waited 0.5s, deleted. A stage plus one timer now does the same steps in OnTick.
-- OnHit already ticks (S6 split, a separate one-shot); call it first so hits still resolve.
local rt = require('skymod.rt')

return function(C)
	C.Boom = rt.sequence("Idle", "Checking", "Disabling", "Deleting", "Done")
	C.__vars.boom = C.Boom.Idle
	C.__vars.boomT = rt.timer(0.0)
	local S = C.Boom

	function C:OnLoad()
		if self.boom ~= S.Idle then return end -- a run happens once
		self.boom = S.Checking
		self.boomT = 5.0
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.boom == S.Idle or self.boom == S.Done or self.boomT > 0 then return end
		if self.boom == S.Checking then
			if self.doOnce and self:Is3DLoaded() then
				self.boom = S.Disabling
				self.boomT = 0.1
				self:PlaceAtMe(self.FireballExplosion)
				self.doOnce = false
			else
				self.boom = S.Done -- condition failed once loaded: nothing more happens, as in Papyrus
			end
		elseif self.boom == S.Disabling then
			self.boom = S.Deleting
			self.boomT = 0.5
			self:Disable()
		else
			self.boom = S.Done
			self:Delete()
		end
	end
end
