-- pex: fragment_2 9dc7650c
-- Fragment_2 waited 0.1 s for the player to exit the letter, then finished the objective. Now a
-- timer plus OnTick in a waiting state.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.t = rt.timer(nil)
	local Waiting = rt.state(C, "Waiting")

	function C:Fragment_2()
		if self:GetState() == "Waiting" then return end -- a second start is dropped
		self.t = 0.1
		self:GotoState("Waiting")
	end

	function Waiting:OnTick()
		if self.t > 0 then return end
		self.t = nil
		self:SetObjectiveCompleted(100)
		self.bookblocker:DisableNoWait()
		self:SetObjectiveDisplayed(75)
		rt.cast(self.alias_player, "ccbgssse001_itemcollectobjectivescript"):DisplayAllObjectives()
		self:GotoState("")
	end
end
