-- pex: ondying 84d90d31
-- pex: spidercrumble ad52ea52
-- pex: spiderexplode 097a411a
-- pex: onanimationevent 1a4a0b37
-- OnDying exploded or crumbled the spider, whose last line waited 1 s, and then took it out of the
-- spider array. The 1 s is now `clear_t`, which the class OnTick counts down after the S6 split's
-- tick. OnAnimationEvent needs no change: ClearRefFrom no longer waits.
local rt = require('skymod.rt')

return function(C)
	C.__vars.clear_t = rt.timer(rt.None) -- time until the dead spider leaves the array
	C.__vars.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick

	local function explosion(self)
		local level = rt.static("Game", "GetPlayer"):GetLevel()
		for i = 1, 5 do
			if level < i * 10 then return self["SpiderExplosion" .. i] end
		end
		return self.SpiderExplosion6
	end

	local function vanish(self)
		self:SetAlpha(0)
		self:DisableNoWait()
	end

	function C:SpiderExplode()
		self:PlaceAtMe(explosion(self), 1)
		if self.SpiderExplosionHazard then self:PlaceAtMe(self.SpiderExplosionHazard, 1) end
		vanish(self)
	end

	function C:SpiderCrumble()
		self:PlaceAtMe(self.SpiderCrumbleExplosion, 1)
		vanish(self)
	end

	function C:OnDying(akKiller)
		if self.clear_t ~= rt.None then return end
		self.clear_t = 1.0
		if self.bShouldExplode and not self.bWasHit then
			self:SpiderExplode()
		else
			self:SpiderCrumble()
		end
	end

	function C:OnTick()
		split_tick(self)
		if self.clear_t == rt.None or self.clear_t > 0 then return end
		self.clear_t = rt.None
		rt.cast(self, "DLC2EncExpSpiderGenericControlSCRIPT"):ClearActor()
	end
end
