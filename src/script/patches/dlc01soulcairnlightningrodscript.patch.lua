-- pex: waiting.onactivate 1866598b
-- Placing a gem asked which one to sacrifice, then picked the actual gem (the loop below) and
-- queued the strike chain, already split into W1..W5 on this class's own OnTick. The event now
-- asks first; OnTick reads the pick, runs the same pick-a-gem loop, then arms the W1 wait exactly
-- as the split expects (`waiting.onactivate.at` is already W1's default, so it is left alone).
local rt = require('skymod.rt')

return function(C)
	local Waiting = rt.state(C, "Waiting")
	C.__vars.asking = rt.bool(false)
	C.__vars.actronaut = rt.form("Actor")

	function Waiting:OnActivate(actronaut)
		if self.asking or self.vars["waiting.onactivate.t"] ~= rt.None then return end -- a call while it waits is dropped
		if actronaut:GetItemCount(self.DLC01SoulcairnLRodGemList) < 1 then
			return self.defaultLackTheItemMSG:Show()
		end
		self.actronaut = actronaut
		self.asking = true
		self.promptMSG:Show()
	end

	function Waiting:OnTick()
		if not self.asking then return end
		local choice = self.promptMSG:Answer()
		if choice < 0 then return self.promptMSG:Show() end
		self.asking = false
		if choice == 1 then return end -- cancelled
		local actronaut, list = self.actronaut, self.DLC01SoulcairnLRodGemList
		self:GotoState("done")
		local i = choice
		while i == 0 and actronaut:GetItemCount(list:GetAt(i)) > 0 do
			i = i + 1
		end
		local gem = list:GetAt(i)
		actronaut:RemoveItem(gem, 1, false, rt.None)
		local gemToSacrifice = self:PlaceAtMe(gem, 1, false, false)
		gemToSacrifice:BlockActivation(true)
		self:BlockActivation(true)
		gemToSacrifice:SetMotionType(self.Motion_Keyframed, true)
		self.vars["waiting.onactivate.gemtosacrifice"] = gemToSacrifice
		self.vars["waiting.onactivate.strikesource"] = rt.None
		self.vars["waiting.onactivate.t"] = 1.5
	end
end
