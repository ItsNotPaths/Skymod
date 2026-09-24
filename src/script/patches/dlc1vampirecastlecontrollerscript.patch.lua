-- pex: starttutorialroomcleanup 7835867c 4d45192d
-- StartTutorialRoomCleanup waited 3 s, turned the tracking trigger off, waited until it reported
-- off, then disabled it and processed the list. The class already ticks (S6 split, for
-- enabledoortocourtyard's timer); we call that first, then carry our own wait as a stage field.
local rt = require('skymod.rt')

local Cleanup = rt.sequence("Idle", "Settle", "Drain")

return function(C)
	C.__vars.cleanup = Cleanup.Idle
	C.__vars.cleanupT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function tracker(self)
		return rt.cast(self.dlc1vq08bossroomcleanupref, "dlc1vq08bossroomcleanupscript")
	end

	function C:StartTutorialRoomCleanup()
		if self.cleanup ~= Cleanup.Idle then return end -- a run happens once
		self.cleanup, self.cleanupT = Cleanup.Settle, 3.0
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.cleanup == Cleanup.Idle then return end
		if self.cleanup == Cleanup.Settle then
			if self.cleanupT > 0 then return end
			self.cleanup = Cleanup.Drain
			tracker(self):SetActive(false)
		end
		if tracker(self).bisactive then return end
		self.cleanup = Cleanup.Idle
		self.dlc1vq08bossroomcleanupref:Disable()
		self:FinishTutorialRoomCleanup()
	end
end
