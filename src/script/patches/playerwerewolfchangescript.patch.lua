-- pex: shiftback cddfc09d 755052f7
-- ShiftBack polled bIsSynced every 0.1 s, then called ActuallyShiftBackIfNecessary, whose 5 s wait
-- the S6 split keeps in "actuallyshiftbackifnecessary.t". The run is now `back`; callers wait
-- while it is not Idle.
local rt = require('skymod.rt')

return function(C)
	C.Back = rt.sequence("Idle", "Synced", "Settling")
	local B = C.Back
	C.__vars.back = B.Idle
	C.__vars.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick

	function C:ShiftBack()
		self.__tryingToShiftBack = true
		if self.back ~= B.Idle then return end
		self.back = B.Synced
		self:OnTick()
	end

	function C:OnTick()
		split_tick(self)
		if self.back == B.Synced then
			if rt.static("Game", "GetPlayer"):GetAnimationVariableBool("bIsSynced") then return end
			self.back = B.Settling
			self.__shiftingBack = false
			self:ActuallyShiftBackIfNecessary()
		end
		if self.back == B.Settling and self.vars["actuallyshiftbackifnecessary.t"] == rt.None then
			self.back = B.Idle
		end
	end
end
