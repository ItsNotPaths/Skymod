-- pex: onactivate b5462dbd
-- Offering the apple read the pick from Show at once. The event now asks; OnTick reads the answer
-- and takes the apple.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnActivate(akActionRef)
		if akActionRef ~= player() then return end
		if self:GetOwningQuest():GetStage() >= 15 then return end
		self.asking = true
		self.CWMission08FeedCowMsg:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.CWMission08FeedCowMsg:Answer()
		if choice < 0 then return self.CWMission08FeedCowMsg:Show() end
		self.asking = false
		if choice ~= 1 then return end
		player():RemoveItem(self.Apple01, 1, false, rt.None)
		self:GetOwningQuest():SetStage(15)
		self:RegisterForUpdate(3)
	end
end
