-- pex: onenterbleedout 1c63b945
-- The alias guarded PlayerInBleedout with its own bInBleedout flag, set around the blocking call.
-- The controller now publishes bPlayerBleedingOut for the whole run; the guard reads that.
local rt = require('skymod.rt')

return function(C)
	function C:OnEnterBleedout()
		local controller = rt.cast(self:GetOwningQuest(), "DLC2BookDungeonControllerScript")
		if controller.bPlayerBleedingOut then return end
		controller:PlayerInBleedout()
	end
end
