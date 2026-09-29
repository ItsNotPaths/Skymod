-- pex: default.onactivate 901c5213
-- A bound, non-combat prisoner asked what to do; the pick freed them, with or without sharing
-- items. OnTick reads the pick; ActorRef is the prisoner that was asked about.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)
	C.__vars.ActorRef = rt.form("Actor")

	function C:OnActivate(akActionRef)
		local actor = self:GetActorReference()
		if actor:IsDead() or actor:IsinCombat() then return end
		if not self.bound then return end
		self.ActorRef = actor
		self.asking = true
		self.WEPrisonerMessageBox:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local result = self.WEPrisonerMessageBox:Answer()
		if result < 0 then return self.WEPrisonerMessageBox:Show() end
		self.asking = false
		if result == self.IDoNothing then return end
		if result == self.ISetFree then return self:FreePrisoner(self.ActorRef, true, false) end
		if result == self.ISetFreeShareItems then self:FreePrisoner(self.ActorRef, true, true) end
	end
end
