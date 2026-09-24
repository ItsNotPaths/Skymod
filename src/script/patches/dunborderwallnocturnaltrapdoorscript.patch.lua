-- pex: ontriggerenter 7a6d1c41
-- OnTriggerEnter walked startUp through 99/1/2/3/4 across three waits. Now a timer gates the same
-- walk in OnTick. Papyrus called Disable() unconditionally at the end of the run even when Open
-- was false (leaving player controls disabled forever in that case); that quirk is kept as-is.
local rt = require('skymod.rt')

return function(C)
	C.__vars.twActive = rt.bool(false)
	C.__vars.twT = rt.timer(0.0)

	function C:OnTriggerEnter(akActionRef)
		if akActionRef ~= rt.static("Game", "GetPlayer") then return end
		if self.twActive then return end -- a second start is dropped
		self.twActive = true
		self.startUp = 99
		self.twT = self.waitTimeBeforeStart -- fresh wait: twT idles until the next trigger
	end

	function C:OnTick()
		if not self.twActive or self.twT > 0 then return end
		if self.startUp == 99 then
			self.startUp = 1
			rt.static("Game", "ForceFirstPerson")
			rt.static("Game", "DisablePlayerControls", true, true, true, true, true, true, true, false, 0)
			rt.static("Game", "GetPlayer"):PlayIdle(self.pIdlePresentSkeletonKey)
			self.startUp = 2
			self.twT = self.twT + self.waitTimeForFloor
			return
		end
		if self.startUp == 2 then
			if self.Open then
				self.anders:Disable(true)
				self.TrapDoor:PlayAnimation("open")
				self.TrapDoorCap:Enable(1)
				self.startUp = 3
				self.twT = self.twT + self.waitTimeForFall
				return
			end
			self:Disable(false) -- Open false: Papyrus falls straight to disable(), controls stay off
			self.twActive = false
			return
		end
		rt.static("Game", "EnablePlayerControls", true, true, true, true, true, true, true, true, 0)
		self.startUp = 4
		self:Disable(false)
		self.twActive = false
	end
end
