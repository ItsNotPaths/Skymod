-- pex: fragment_13 ccc4d848
-- Fragment_13 made Aela the follower after SwapFollowers (2 s dismissal) returned. That call now
-- returns at once, so the rest waits in state "Swapping" until FollowerScript leaves "Dismissing".
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Swapping = rt.state(C, "Swapping")

	local function central(self) return rt.cast(rt.cast(self, "C03QuestScript").CentralQuest, "CompanionsHousekeepingScript") end

	function C:Fragment_13()
		if self:GetState() == "Swapping" then return end
		local c03 = rt.cast(self, "C03QuestScript")
		self:PostRampageHandling(c03)
		if not self:IsObjectiveCompleted(20) then self:SetObjectiveCompleted(20) end
		if c03.CheckedInWithAela then self:SetObjectiveCompleted(25) else self:SetObjectiveFailed(25) end
		self:SetObjectiveDisplayed(30)
		self.AelaPostTransformScene:Stop()
		self.Alias_Aela:GetActorReference():SetPlayerTeammate(true, false)
		self:GotoState("Swapping")
		central(self):SwapFollowers()
		self:OnTick()
	end

	function Swapping:OnTick()
		local c00 = central(self)
		if c00.FollowerScript:GetState() == "Dismissing" then return end
		self:GotoState("")
		local aela = self.Alias_Aela:GetActorReference()
		c00:Shutup(aela)
		c00.CurrentFollower:ForceRefTo(self.Alias_Aela:GetRef())
		aela:RemoveFromFaction(self.IsGuardFaction)
		aela:EvaluatePackage()
	end
end
