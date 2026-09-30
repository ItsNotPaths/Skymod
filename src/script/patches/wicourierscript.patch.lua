-- pex: removereffromcontainer cc72925d
-- removeRefFromContainer waited (1 s polls) while the courier talked to the player, then took the
-- item out of his bag and counted one item fewer. The engine's courier API does that removal:
-- at once, or when the dialogue ends (mydocs/s5/todo.md P13).
local rt = require('skymod.rt')

return function(C)
	local remove_ref = rt.native("Courier", "RemoveRef", true)

	function C:removeRefFromContainer(objectRefToRemove, GiveToPlayer)
		remove_ref(self.pCourier, self.pCourierContainer, objectRefToRemove, GiveToPlayer or false, self.pWICourierItemCount)
		rt.cast(self.pCourier, "Actor"):EvaluatePackage()
	end
end
