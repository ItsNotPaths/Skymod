-- pex: onactivate 708343c6
-- Choosing a shrine power read the pick from Show at once, then always ran SetChosenPower. The
-- event now asks only when the player qualifies; OnTick reads the answer and runs it. When the
-- player doesn't qualify, SetChosenPower still runs at once, as before.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnActivate(akActor)
		if akActor == player() and player():HasSpell(self.DLC1VampireChange) == true then
			self.asking = true
			self.MessagePrompt:Show()
			return
		end
		self:SetChosenPower()
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.MessagePrompt:Answer()
		if choice < 0 then return self.MessagePrompt:Show() end
		self.asking = false
		self.ShrineSelectedPower = choice
		if self.ShrineSelectedPower == -1 then self.ShrineSelectedPower = 0 end
		self:SetChosenPower()
	end
end
