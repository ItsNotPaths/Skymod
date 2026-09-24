-- pex: accepted c35bb2f1
-- Accepted placed the totem and accepted the quest after SwapFollowers (2 s dismissal) returned.
-- That call now returns at once, so the rest waits in state "Swapping" until the dismissal is over.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Swapping = rt.state(C, "Swapping")

	local function parent(self) return rt.cast(self.ParentQuest, "CompanionsHousekeepingScript") end

	function C:Accepted()
		if self:GetState() == "Swapping" then return end
		self.Questgiver:GetActorReference():SetPlayerTeammate(true)
		self:GotoState("Swapping")
		parent(self):SwapFollowers()
		self:OnTick()
	end

	function Swapping:OnTick()
		local c00 = parent(self)
		if c00.FollowerScript:GetState() == "Dismissing" then return end
		self:GotoState("")
		local giver = self.Questgiver:GetActorReference()
		giver:RemoveFromFaction(self.IsGuardFaction)
		giver:RemoveFromFaction(self.PotentialFollowerFaction)
		self.QuestgiverEssentialized:ForceRefTo(self.Questgiver:GetReference())
		local found = c00.TotemsFound
		local t = self.SpawnMarker:PlaceAtMe(found == 0 and self.TotemType1 or found == 1 and self.TotemType2 or self.TotemType3)
		self.Totem:ForceRefTo(t)
		local treasure = self.TreasureMarker:GetReference()
		treasure:AddItem(self.Totem:GetReference())
		treasure:GetParentCell():Reset()
		rt.parent(self, "CR12QuestScript", "Accepted")
		giver:EvaluatePackage()
	end
end
