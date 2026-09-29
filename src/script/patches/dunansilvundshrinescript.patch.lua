-- pex: notactivated.onactivate 121d391c
-- Placing the white soul gem on the shrine asked to confirm the swap; button 1 removed the gem
-- from the player, gave the shrine's back, and opened the activated state. OnTick in
-- NotActivated reads the pick. (activated.onactivate only shows ShrineMessage2 and never reads
-- its result, so it stays as transpiled.)
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	local NotActivated = rt.state(C, "NotActivated")

	function NotActivated:OnActivate(TriggerRef)
		if TriggerRef ~= rt.static("Game", "GetPlayer") then return end
		self.asking = true
		self.ShrineMessage1:Show()
	end

	function NotActivated:OnTick()
		if not self.asking then return end
		local iButton = self.ShrineMessage1:Answer()
		if iButton < 0 then return self.ShrineMessage1:Show() end
		self.asking = false
		if iButton ~= 1 then return end
		rt.static("Game", "GetPlayer"):RemoveItem(self.WhiteSoulGem:GetRef(), 1, false)
		self:AddItem(self.WhiteSoulGem:GetRef(), 1, false)
		self:GotoState("activated")
	end
end
