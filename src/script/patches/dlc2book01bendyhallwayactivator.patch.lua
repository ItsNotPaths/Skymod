-- pex: mybend 4fc2b4fc
-- myBend sent the hallway its bend and waited for it before re-arming. Now it stays done while
-- the hallway is Bending; `rearm` says it goes back to Waiting then, `hall` is the hallway.
local rt = require('skymod.rt')

return function(C)
	C.__vars.rearm = rt.bool(false)
	C.__vars.hall = rt.form("DLC2Book01BendyHallwayController")
	C.__vars.TickRate = rt.float(0.1)
	local Done = rt.state(C, "done")

	function C:myBend()
		self.currentActivations = self.currentActivations + 1
		if self.currentActivations < self.activationsNeeded then return end
		self:GotoState("done")
		self.hall = self:GetLinkedRef()
		local bend = self.BendType
		if self.RevertBendOnSecondActivate then
			bend = self.secondBend and 3 or self.BendType
			self.secondBend = not self.secondBend
		end
		self.hall:bend(bend)
		self.currentActivations = 0
		self.rearm = not self.doOnlyOnce
		self:OnTick()
	end

	function Done:OnTick()
		if not self.rearm or (self.hall and self.hall.Bending) then return end
		self.rearm = false
		self:GotoState("Waiting")
	end
end
