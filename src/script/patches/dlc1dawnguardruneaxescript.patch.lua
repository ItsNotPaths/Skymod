-- pex: onload f4ccc456
-- pex: onequip f58f3629
-- pex: onupdategametime 216fe80b
-- The shipped axe (DLC1HunterCave01) has no properties filled, so every hour it called on None and
-- never reset the undead count its enchantment reads. It also compared GameDay, the day of the
-- month, so a month's end skipped the reset. Now one check counts days from 5 AM and finds the
-- count global itself when VMAD left it empty.
local rt = require('skymod.rt')

return function(C)
	C.__vars.resetday = rt.int(-1) -- the day of the last check; -1 before the first

	local function reset_if_new_day(self)
		local today = math.floor(rt.static("Utility", "GetCurrentGameTime") - 5 / 24)
		if self.resetday >= 0 and today > self.resetday then
			self.undeadkilled = self.undeadkilled or rt.static("Game", "GetFormFromFile", 0x016691, "Dawnguard.esm")
			if self.undeadkilled then self.undeadkilled:SetValue(0) end
		end
		self.resetday = today
	end

	function C:OnLoad()
		reset_if_new_day(self)
		self:RegisterForUpdateGameTime(1)
	end

	C.OnEquip = reset_if_new_day
	C.OnUpdateGameTime = reset_if_new_day
end
