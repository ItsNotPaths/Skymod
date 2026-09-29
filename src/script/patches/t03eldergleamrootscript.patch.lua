-- pex: default.onactivate 4043c7a1
-- Cutting the root with the right weapon asked to confirm; button 0 opened it once, disabling
-- the sap and nudging Maurice's dialogue. Without the weapon it just showed CantCutMessage. OnTick
-- reads the pick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	function C:OnActivate(akActionRef)
		if rt.static("Game", "GetPlayer"):GetItemCount(self.ItemNeededToCut) <= 0 then
			return self.CantCutMessage:Show()
		end
		self.asking = true
		self.CutChoiceMessage:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local response = self.CutChoiceMessage:Answer()
		if response < 0 then return self.CutChoiceMessage:Show() end
		self.asking = false
		if response ~= 0 then return end
		local t03script = rt.cast(self.T03, "T03QuestScript")
		if t03script.RootOpened then return end
		t03script.RootOpened = true
		self.Sap:GetReference():Enable(false)
		t03script.MauriceShouldAdmonish = true
		t03script.MauriceShouldIntro = false
		self:Disable(false)
	end
end
