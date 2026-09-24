-- pex: onupdate 3d7018a6 cd99f13f
-- Restoring a seal held `busy` while its pedestal reset (1.5 s + its return delay), so a seal
-- change asked for meanwhile waited (1 s re-registers). Now the pedestal's Busy state is part of
-- that busy test; the rest of OnUpdate is as converted.
local rt = require('skymod.rt')

return function(C)
	local converted = C.__fn.onupdate

	function C:OnUpdate()
		local pedestal = self.LinkedPedestal and rt.cast(self.LinkedPedestal, "DLC2dunNchardakPedestalScript")
		local resetting = pedestal and pedestal:GetState() == "Busy"
		if resetting and (self.isReleasingSeal or self.isRestoringSeal) and not self.isWaitingFor3DToLoad then
			return self:RegisterForSingleUpdate(1)
		end
		converted(self)
	end
end
