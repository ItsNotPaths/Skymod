-- pex: init 0349ac1d
-- Init made Vilkas the follower after SwapFollowers (2 s dismissal) returned. That call now returns
-- at once, so the rest waits in state "Swapping" until FollowerScript leaves "Dismissing".
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Swapping = rt.state(C, "Swapping")

	local function central(self) return rt.cast(self.CentralQuest, "CompanionsHousekeepingScript") end

	function C:Init()
		if self:GetState() == "Swapping" then return end
		local sack = self.FragmentSack:GetReference()
		sack:GetParentCell():Reset()
		self.FragmentSackQuestItem:ForceRefTo(sack)
		self.Vilkas:GetActorReference():SetPlayerTeammate(true, false)
		self:GotoState("Swapping")
		central(self):SwapFollowers()
		self:OnTick()
	end

	function Swapping:OnTick()
		local c00 = central(self)
		if c00.FollowerScript:GetState() == "Dismissing" then return end
		self:GotoState("")
		local vilkas = self.Vilkas:GetActorReference()
		c00:Shutup(vilkas)
		c00.CurrentFollower:ForceRefTo(self.Vilkas:GetReference())
		vilkas:RemoveFromFaction(self.IsGuardFaction)
		rt.parent(self, "C05QuestScript", "Init")
	end
end
