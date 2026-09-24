-- pex: fragment_0 b44fd317
-- pex: fragment_3 0936904c
-- Both fragments went on once DismissFollower (2 s parting line) returned: Fragment_0 moved the
-- wedding party into place, Fragment_3 started the FIN quest. Each rest now waits in OnTick, beside
-- the split Fragment_17 tick, until DialogueFollower leaves "Dismissing".
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.positionsOwed = rt.bool(false) -- the wedding party is not in place yet
	C.__vars.finOwed = rt.bool(false)       -- the FIN quest is not started yet
	local split_tick = C.__fn.ontick

	local function dismiss_love_interest(self, iMessage)
		if self.Alias_LoveInterest:GetActorRef():IsInFaction(self.CurrentFollowerFaction) then
			self.DialogueFollower:DismissFollower(iMessage)
		end
	end

	function C:Fragment_0()
		self.RelationshipMarriage:SetObjectiveDisplayed(20, true, true)
		self.positionsOwed = true
		dismiss_love_interest(self, 1)
		self:OnTick()
	end

	function C:Fragment_3()
		local lover = self.Alias_LoveInterest:GetActorReference()
		local player = rt.static("Game", "GetPlayer")
		rt.static("Game", "AddAchievement", 33)
		self.RelationshipMarriage:SetStage(100)
		lover:RemoveFromFaction(self.RelationshipCourtingFaction)
		lover:RemoveFromFaction(self.PotentialHireling)
		lover:SetRelationshipRank(player, 4)
		lover:AddToFaction(self.PlayerFaction)
		lover:AddToFaction(self.PlayerMarriedFaction)
		player:AddToFaction(self.PlayerMarriedFaction)
		player:AddItem(self.MarriageRingBondsofMatrimony, 1)
		lover:AddItem(self.MarriageRingBondsofMatrimony, 1)
		rt.cast(self, "RelationshipMarriageWeddingScript"):UnregisterForUpdate()
		self.finOwed = true
		dismiss_love_interest(self, 0)
		self:OnTick()
	end

	local places = { { "TemplePriest", "PriestMarker" }, { "LoveInterest", "LoveInterestMarker" },
		{ "LoverWitness01", "LoveInterestWitnessMarker01" }, { "LoverWitness02", "LoveInterestWitnessMarker02" },
		{ "LoverWitness03", "LoveInterestWitnessMarker03" }, { "PlayerWitness01", "PlayerWitnessMarker01" },
		{ "PlayerWitness02", "PlayerWitnessMarker02" }, { "PlayerWitness03", "PlayerWitnessMarker03" } }

	local function take_places(self)
		for _, p in ipairs(places) do
			local alias = self["Alias_" .. p[0]]
			if not alias:GetActorRef():IsInLocation(self.RiftenTempleofMaraLocation) then
				alias:GetActorReference():MoveTo(self[p[1]])
			end
		end
		self.Alias_TemplePriest:GetActorRef():EvaluatePackage()
		self.Alias_Briehl:GetActorRef():EvaluatePackage()
		self.Alias_Dinya:GetActorRef():EvaluatePackage()
		if self:GetStage() < 100 then self.WeddingScene:Start() end
	end

	local function start_fin(self)
		local lover = self.Alias_LoveInterest:GetActorRef()
		self.RelationshipMarriageFIN:SendStoryEvent{ akRef1 = lover }
		lover:EvaluatePackage()
		self:SetStage(500)
	end

	function C:OnTick()
		split_tick(self)
		if not (self.positionsOwed or self.finOwed) then return end
		if self.DialogueFollower:GetState() == "Dismissing" then return end
		if self.positionsOwed then
			self.positionsOwed = false
			take_places(self)
		end
		if self.finOwed then
			self.finOwed = false
			start_fin(self)
		end
	end
end
