-- pex: fragment_29 51548fb5
-- Stage 29 put the cube in the exterior pedestal, waited for it to settle, then disabled the door
-- trigger. Now OnTick waits while that pedestal is Busy.
local rt = require('skymod.rt')

return function(C)
	C.__vars.f29_pedestal = rt.form("DLC2dunNchardakPedestalScript")
	C.__vars.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick or function() end

	function C:Fragment_29()
		if self.f29_pedestal then return end
		self.f29_pedestal = self.DLC2dunNchardakExteriorPedestal
		self.f29_pedestal:InsertCubeNeloth()
	end

	function C:OnTick()
		split_tick(self)
		if not self.f29_pedestal or self.f29_pedestal:GetState() == "Busy" then return end
		self.f29_pedestal = rt.None
		self.ReadingRoomDoorTrigger:Disable()
	end
end
