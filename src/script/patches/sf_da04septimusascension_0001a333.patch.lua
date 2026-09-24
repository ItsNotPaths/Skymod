-- pex: fragment_4 18afb4de
-- The fragment opened the box and waited for its "Done" before telling the quest. Now OnTick in
-- the Opening state waits for the box's animation to end.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Opening = rt.state(C, "Opening")

	function C:Fragment_4()
		self.MagicBox:PlayAnimation("trigger01")
		self:GotoState("Opening")
		self:OnTick()
	end

	function Opening:OnTick()
		if self.MagicBox:IsAnimRunning("trigger01") then return end
		rt.cast(self:GetOwningQuest(), "DA04QuestScript").BoxOpened = true
		self:GotoState("")
	end
end
