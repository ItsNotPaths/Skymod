-- pex: onactivate 46f7f6f3
-- Skinning Sinding's corpse read the pick from Show at once. The event now asks; OnTick reads the
-- answer and hands the skin over.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnActivate(akActionRef)
		if not self:GetActorReference():IsDead() then return end
		local ready = self.DA05:GetStage() == 60
			or (self.DA05:GetStageDone(61) and not self.DA05:GetStageDone(65))
		if not ready then return end
		self.asking = true
		self.SkinMessage:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.SkinMessage:Answer()
		if choice < 0 then return self.SkinMessage:Show() end
		self.asking = false
		if choice ~= 0 then return end
		player():AddItem(self.SindingSkin:GetReference(), 1, false)
		self:GetOwningQuest():SetStage(65)
		self:GetReference():BlockActivation(false)
		self:GetReference():SetMotionType(3, true)
		self.SindingGhost:GetReference():MoveTo(self:GetReference(), 0.0, 0.0, 0.0, true)
		self.SindingGhost:GetReference():Enable(true)
		self.SindingGhost:GetActorReference():SetNoFavorAllowed(true)
	end
end
