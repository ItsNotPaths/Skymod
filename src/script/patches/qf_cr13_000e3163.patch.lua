-- pex: fragment_15 ce5e1980
-- pex: fragment_7 46344569
-- Both fragments went on with the questgiver after SwapFollowers (2 s dismissal) returned. That
-- call now returns at once, so the rest waits in state "Swapping" until the dismissal is over.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.acceptOwed = rt.bool(false)   -- the questgiver's quest is still to be accepted
	C.__vars.factionsOwed = rt.bool(false) -- the questgiver still has the guard and follower factions
	local Swapping = rt.state(C, "Swapping")

	local function cr13(self) return rt.cast(self, "CR13QuestScript") end
	local function parent(self) return rt.cast(cr13(self).ParentQuest, "CompanionsHousekeepingScript") end

	local function accept(self)
		parent(self):AcceptRadiantQuest(self.Alias_Questgiver:GetActorReference(), true)
		cr13(self).IsAccepted = true
	end

	function C:Fragment_7()
		if self:GetState() == "Swapping" then return end
		self:SetObjectiveDisplayed(10, true)
		self.Alias_Questgiver:GetActorReference():SetPlayerTeammate(true, false)
		self.acceptOwed = true
		self.factionsOwed = true
		self:GotoState("Swapping")
		parent(self):SwapFollowers()
		self:OnTick()
	end

	function C:Fragment_15()
		-- the objective update runs even if Fragment_7's dismissal is still in flight
		if self:IsObjectiveDisplayed(10) then self:SetObjectiveCompleted(10) end
		self:SetObjectiveDisplayed(15)
		if self:GetState() == "Swapping" then return end
		if self:GetStageDone(10) then
			if not cr13(self).IsAccepted then accept(self) end
			return
		end
		self.Alias_Questgiver:GetActorReference():SetPlayerTeammate(true, false)
		self.acceptOwed = not cr13(self).IsAccepted
		self:GotoState("Swapping")
		parent(self):SwapFollowers()
		self:OnTick()
	end

	function Swapping:OnTick()
		if parent(self).FollowerScript:GetState() == "Dismissing" then return end
		self:GotoState("")
		local giver = self.Alias_Questgiver:GetActorReference()
		if self.factionsOwed then
			self.factionsOwed = false
			giver:RemoveFromFaction(self.IsGuardFaction)
			giver:RemoveFromFaction(self.PotentialFollowerFaction)
		end
		giver:EvaluatePackage()
		if self.acceptOwed then
			self.acceptOwed = false
			accept(self)
		end
	end
end
