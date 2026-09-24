-- pex: fragment_2 0d61ad4f
-- pex: fragment_1 861aaa5a
-- Both fragments called into DA09Script and went on right after: fragment_2 sets the fall's
-- objectives and turns SkyPlaneCollision back on, fragment_1 starts the sky scene. Now they wait
-- for the callee's stage to return to Idle before finishing (fragment_8 is untouched: its tail
-- is free, so the patched movePlayerToEarth already does the right thing for it).
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.05)
	C.__vars.earthOwed = rt.bool(false)
	C.__vars.skyOwed = rt.bool(false)

	function C:Fragment_2()
		if self.earthOwed then return end
		rt.cast(self, "da09script"):MovePlayerToEarth()
		self.earthOwed = true
	end

	function C:Fragment_1()
		if self.skyOwed then return end
		self.Alias_Gem:UnregisterForUpdateGameTime()
		rt.static("Game", "GetPlayer"):RemoveItem(self.Alias_Gem:GetReference())
		rt.cast(self, "da09script"):MovePlayerToSky()
		self.skyOwed = true
	end

	function C:OnTick()
		local kmyQuest = rt.cast(self, "da09script")
		if self.earthOwed and kmyQuest.fall == kmyQuest.class.Fall.Idle then
			self.earthOwed = false
			self:SetObjectiveCompleted(15)
			self:SetObjectiveDisplayed(20)
			kmyQuest.DA09SkyPlaneCollision:enable()
		end
		if self.skyOwed and kmyQuest.sky == kmyQuest.class.Sky.Idle then
			self.skyOwed = false
			kmyQuest.DungeonBlockerToggle:disable()
			kmyQuest.DA09SkyScene:Start()
		end
	end
end
