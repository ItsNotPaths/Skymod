-- pex: onactivate 7bc5693b
-- Choosing an egg-in-forge option read the pick from Show at once. The event now asks; OnTick
-- reads the answer and sets the matching stage.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnActivate(akActionRef)
		if akActionRef ~= player() then return end
		if self:GetOwningQuest():GetStage() < 160 then return end
		self.asking = true
		self.EggChoiceMessage:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.EggChoiceMessage:Answer()
		if choice < 0 then return self.EggChoiceMessage:Show() end
		self.asking = false
		self.Choice = choice
		if choice == 1 then
			self:GetOwningQuest():SetStage(170)
		elseif choice == 2 then
			self:GetOwningQuest():SetStage(175)
		end
	end
end
