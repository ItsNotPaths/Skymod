-- pex: onactivate d3590924
-- Activating an eligible corpse asked to eat it; a yes started 3 s of cannibalism (already split:
-- the class's own OnTick advances the quest stage when that wait is over). The event now asks;
-- ours reads the pick and arms that same wait.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	local function eligible(self, akActionRef)
		local quest = self:GetOwningQuest()
		return self:GetActorRef():IsDead()
			and quest:GetStage() == 60
			and not quest:GetStageDone(100)
			and akActionRef == rt.static("Game", "GetPlayer")
	end

	function C:OnActivate(akActionRef)
		if self.asking or self.vars["onactivate.t"] ~= rt.None then return end -- a call while it waits is dropped
		if not eligible(self, akActionRef) then return end
		self.asking = true
		self.CorpseMessage:Show()
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if not self.asking then return end
		local choice = self.CorpseMessage:Answer()
		if choice < 0 then return self.CorpseMessage:Show() end
		self.asking = false
		if choice ~= 1 then return end
		rt.static("Game", "GetPlayer"):StartCannibal(self:GetActorRef())
		self.vars["onactivate.t"] = 3.0
	end
end
