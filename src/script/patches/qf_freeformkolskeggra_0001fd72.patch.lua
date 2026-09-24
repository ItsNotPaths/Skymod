-- pex: fragment_2 53a17270
-- The miners went back to work, Kolskeggr's garrison went back in the war, and the quest stopped
-- once setOwner's reset was done. The stop now waits for CWScript's resettingGarrisons.
local rt = require('skymod.rt')

return function(C)
	C.__vars.stopOwed = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting")

	function C:Fragment_2()
		if self.stopOwed then return end
		local player = rt.static("Game", "GetPlayer")
		self:SetObjectiveCompleted(20, true)
		player:AddItem(self.FavorRewardGoldLarge)
		local pavo = self.Alias_Pavo:GetActorRef()
		pavo:SetRelationshipRank(player, 1)
		self.Alias_Gat:GetActorRef():SetRelationshipRank(player, 1)
		pavo:AddToFaction(self.FavorJobsMineOreFaction) -- Pavo now buys ore
		self.stopOwed = true
		self:GotoState("Waiting")
		self.CWQuest:AddGarrisonBackToWar(self.KolskeggrLocation, 0, false)
		self:OnTick()
	end

	function Waiting:OnTick()
		if self.CWQuest.resettingGarrisons then return end
		self.stopOwed = false
		self:GotoState("")
		self:Stop()
	end
end
