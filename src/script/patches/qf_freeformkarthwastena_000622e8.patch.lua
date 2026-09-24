-- pex: fragment_1 8c298980
-- pex: fragment_12 18746981
-- Both endings put Karthwasten's garrison back in the war and stopped the quest once setOwner's
-- reset was done. The stop now waits for CWScript's resettingGarrisons.
local rt = require('skymod.rt')

return function(C)
	C.__vars.stopOwed = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting")

	local function side_with(self, rank)
		if self.stopOwed then return end
		local player = rt.static("Game", "GetPlayer")
		self.Alias_Ainethach:GetActorRef():SetRelationshipRank(player, rank)
		self.Alias_Lash:GetActorRef():SetRelationshipRank(player, rank)
		self.Alias_Ragnar:GetActorRef():SetRelationshipRank(player, rank)
		self:CompleteAllObjectives()
		self.stopOwed = true
		self:GotoState("Waiting")
		self.CWQuest:AddGarrisonBackToWar(self.KarthwastenLocation, 0, false)
		self:OnTick()
	end

	function C:Fragment_1() side_with(self, 1) end  -- returned to Ainethach
	function C:Fragment_12() side_with(self, -1) end -- returned to Atar

	function Waiting:OnTick()
		if self.CWQuest.resettingGarrisons then return end
		self.stopOwed = false
		self:GotoState("")
		self:Stop()
	end
end
