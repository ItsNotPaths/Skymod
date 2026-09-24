-- pex: fragment_21 f15ad21a
-- Fragment_21 waited 1s between stopping the ambush scenes and starting Aicantar2. The wait is
-- now a timer; the rest of the fragment runs once it clears.
local rt = require('skymod.rt')

return function(C)
	local split_tick = C.__fn.ontick
	C.__vars.f21T = rt.timer(-1.0) -- negative: fragment not running

	function C:Fragment_21()
		if self.f21T >= 0 then return end -- a run happens once
		self.scene_aicantar1:Stop()
		self.scene_labamb1:Stop()
		self.f21T = 1.0
	end

	function C:OnTick()
		split_tick(self)
		if self.f21T < 0 or self.f21T > 0 then return end
		self.f21T = -1.0
		self.scene_aicantar2:Start()
		rt.cast(self.bolteddoor, "doorbar"):SetBarPosition(true)
		self.quarters02inchaos = true
		self.alias_gallery_guard01:GetActorReference():AddToFaction(self.secureareaguardfaction)
		self.alias_gallery_guard02:GetActorReference():AddToFaction(self.secureareaguardfaction)
		self.alias_gallery_guard03:GetActorReference():AddToFaction(self.secureareaguardfaction)
		self.alias_aicantar:GetActorReference():AddToFaction(self.secureareaguardfaction)
	end
end
