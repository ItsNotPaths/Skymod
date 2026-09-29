-- pex: default.onactivate 591b5537
-- The coin slot asked which coin and stored the pick on the lever's Deposit property. OnTick
-- reads the pick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	function C:OnActivate(trigRef)
		if trigRef ~= rt.static("Game", "GetPlayer") then return end
		self.asking = true
		self.DepositMsg:Show()
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.DepositMsg:Answer()
		if choice < 0 then return self.DepositMsg:Show() end
		self.asking = false
		self.MainScript.Deposit = choice
	end
end
