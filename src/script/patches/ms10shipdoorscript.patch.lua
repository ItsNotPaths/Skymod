-- pex: default.onactivate 2f5fea81
-- At quest stage 41 the ship door asked to set sail; button 0 called SetSail on the owning
-- quest. OnTick reads the pick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	function C:OnActivate(akActivator)
		if akActivator ~= rt.static("Game", "GetPlayer") then return end
		if self:GetOwningQuest():GetStage() ~= 41 then return end
		self.asking = true
		self.SureYouWantTo:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local response = self.SureYouWantTo:Answer()
		if response < 0 then return self.SureYouWantTo:Show() end
		self.asking = false
		if response ~= 0 then return end
		rt.cast(self:GetOwningQuest(), "MS10QuestScript"):SetSail()
	end
end
