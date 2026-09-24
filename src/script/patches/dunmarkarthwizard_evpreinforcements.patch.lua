-- pex: evpreinforcement 45373ad7
-- EVPReinforcement looped forever while runEVPLoop, evaluating the package every 2s. Now OnTick at
-- a 2s TickRate does the same; OnUnload and OnCombatStateChanged (converted, unchanged) already
-- clear runEVPLoop to stop it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(2.0)

	function C:EVPReinforcement()
		self.runEVPLoop = true
	end

	function C:OnTick()
		if not self.runEVPLoop then return end
		self:EvaluatePackage()
	end
end
