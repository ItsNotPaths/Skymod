-- pex: fragment_7 8e263140
-- Fragment_7 finished taking on the questgiver after SwapFollowers (2 s dismissal) returned. That
-- call now returns at once, so the rest waits in state "Swapping" until the dismissal is over.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Swapping = rt.state(C, "Swapping")

	local function parent(self) return rt.cast(rt.cast(self, "CR14QuestScript").ParentQuest, "CompanionsHousekeepingScript") end

	function C:Fragment_7()
		if self:GetState() == "Swapping" then return end
		self:SetObjectiveDisplayed(10, true)
		self.Alias_Questgiver:GetActorRef():SetPlayerTeammate(true, false)
		self:GotoState("Swapping")
		parent(self):SwapFollowers()
		self:OnTick()
	end

	function Swapping:OnTick()
		if parent(self).FollowerScript:GetState() == "Dismissing" then return end
		self:GotoState("")
		local giver = self.Alias_Questgiver:GetActorReference()
		giver:RemoveFromFaction(self.IsGuardFaction)
		giver:RemoveFromFaction(self.PotentialFollowerFaction)
		giver:EvaluatePackage()
	end
end
