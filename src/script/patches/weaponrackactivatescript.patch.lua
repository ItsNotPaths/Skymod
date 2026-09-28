-- pex: oncellattach 1081efee
-- pex: handleweaponplacement 704b9ee6
-- HandleWeaponPlacement waited in 0.1 s steps, up to 10, for the dropped weapon's 3D to load. A
-- dropped ref is placed at once here, so its waits are all due now: the loop runs inside the call,
-- and the rack has no OnTick (817 racks ticked every tick for it).
local rt = require('skymod.rt')

return function(C)
	local place, wait = C.__fn.handleweaponplacement, C.__fn.ontick
	C.__fn.ontick = nil

	function C:HandleWeaponPlacement(ForStartingWeapon)
		place(self, ForStartingWeapon)
		while self.vars["handleweaponplacement.t"] ~= rt.None do
			self.vars["handleweaponplacement.t"] = 0
			wait(self)
		end
	end
end
