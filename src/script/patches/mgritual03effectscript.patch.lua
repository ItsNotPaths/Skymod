-- pex: dremorasummon 880dd550
-- pex: onspellcast 3a8911ff
-- DremoraSummon placed the marker, waited 0.33 s, then placed and ghosted the dremora. OnSpellCast
-- calls it and, since Papyrus blocks until it returns, only then advances DremoraFlag: that write
-- is now a pending value settled once the summon's timer clears (busy calls are dropped, not run
-- twice, so a dropped call also drops its flag write).
local rt = require('skymod.rt')

return function(C)
	C.__vars.summonT = rt.timer(rt.None)
	C.__vars.pendingFlag = rt.int(0)

	function C:DremoraSummon()
		if self.summonT ~= rt.None then return end -- a second call while one runs is dropped
		self.MGRitualSummonMarker:PlaceAtMe(self.SummonTargetFXActivator, 1)
		self.summonT = 0.33
	end

	function C:OnTick()
		if self.summonT == rt.None or self.summonT > 0 then return end
		self.summonT = rt.None
		local dremora = self.MGRitualSummonMarker:PlaceAtMe(self.MGRDremoraSummon, 1)
		self.DremoraAlias:ForceRefTo(dremora)
		local quest = rt.cast(self.MGRitual03, "mgritual03questscript")
		if quest.DremoraFlag >= 6 then
			self.DremoraAlias:GetActorReference():SetGhost()
		end
		if self.pendingFlag ~= 0 then
			quest.DremoraFlag = self.pendingFlag
			self.pendingFlag = 0
		end
	end

	local NEXT_FLAG = { [0] = 1, [3] = 4, [6] = 7, [8] = 10 }

	function C:OnSpellCast(AkSpell)
		local QuestScript = rt.cast(self.MGRitual03, "mgritual03questscript")
		if QuestScript.DremoraSummoned ~= 0 or QuestScript.InTrigger ~= 1 then return end
		if AkSpell ~= self.MGRSummonDremora then return end
		local nextFlag = NEXT_FLAG[QuestScript.DremoraFlag]
		if not nextFlag then return end
		self.pendingFlag = nextFlag
		self:DremoraSummon()
	end
end
