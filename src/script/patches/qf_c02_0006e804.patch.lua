-- pex: fragment_8 ca1ddcaf
-- Fragment_8 reopened and cycled the radiant quests after CompleteStoryQuest returned. That call
-- now returns at once, so the reopen waits in state "Completing" until C00's `endingStory` is None.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Completing = rt.state(C, "Completing")

	local function central(self) return rt.cast(rt.cast(self, "C02QuestScript").CentralQuest, "CompanionsHousekeepingScript") end

	function C:Fragment_8()
		if self:GetState() == "Completing" then return end
		local c00 = central(self)
		self.C01:SetStage(200)
		rt.static("Game", "GetPlayer"):ModFactionRank(c00.CompanionsFaction, 1)
		c00:UnShutup(self.Alias_Questgiver:GetActorReference())
		self.Alias_Kodlak:GetActorReference():EvaluatePackage()
		self:GotoState("Completing")
		c00:CompleteStoryQuest(rt.cast(self, "C02QuestScript"))
		self:OnTick()
	end

	function Completing:OnTick()
		local c00 = central(self)
		if c00.endingStory then return end
		self:GotoState("")
		c00:ReOpenAllRadiantQuests()
		c00:CycleRadiantQuests()
	end
end
