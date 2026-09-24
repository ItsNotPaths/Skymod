-- pex: fragment_3 bada1a89
-- pex: fragment_2 a0fa97c5
-- Fragment_3 waited 0.1 s for the player to exit the letter, then set objectives. Fragment_2 calls
-- WICourier.RemoveRefFromContainer, which no longer blocks (wicourierscript.patch.lua), so
-- Fragment_2 needs no change: it already runs its remaining lines right after the call starts.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.exitLetterT = rt.timer(0.0)
	local Waiting = rt.state(C, "ExitingLetter")

	function C:Fragment_3()
		if self:GetState() == "ExitingLetter" then return end -- a run happens once
		self.exitLetterT = 0.1
		self:GotoState("ExitingLetter")
	end

	function Waiting:OnTick()
		if self.exitLetterT > 0 then return end
		self:GotoState("")
		self:SetObjectiveCompleted(100, true)
		self:SetObjectiveDisplayed(75, true, false)
		rt.cast(self.alias_player, "ccbgssse001_itemcollectobjectivescript"):DisplayAllObjectives()
	end
end
