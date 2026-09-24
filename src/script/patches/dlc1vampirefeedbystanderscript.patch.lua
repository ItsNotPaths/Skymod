-- pex: checkbystanders 73018442
-- pex: checkbystanderssendalarmandstopquest 8ca90d17
-- CheckBystanders scanned the alias array, double-checking IsDetectedBy 0.25 s apart per
-- bystander (the first check primes detection between non-hostiles and is discarded). It is
-- callable on its own, so it starts (or reads) the scan and returns the last known answer.
-- CheckBystandersSendAlarmAndStopQuest starts the scan and waits for the fact instead of the call
-- returning.
local rt = require('skymod.rt')

local Scan = rt.sequence("Idle", "Checking", "Done")
local Alarm = rt.sequence("Idle", "AwaitingScan")

return function(C)
	C.__vars.scan = Scan.Idle
	C.__vars.scanT = rt.timer(0.0)
	C.__vars.scanIdx = rt.int(0)
	C.__vars.scanWaiting = rt.bool(false)
	C.__vars.scanCares = rt.bool(false)
	C.__vars.scanActor = rt.form("Actor")
	C.__vars.alarm = Alarm.Idle
	C.__vars.durationRT = rt.float(0.0)
	C.__vars.victimRef = rt.form("Actor")
	C.__vars.TickRate = rt.float(0.1)

	function C:CheckBystanders()
		if self.scan == Scan.Idle then
			self.scan, self.scanIdx, self.scanWaiting, self.scanCares = Scan.Checking, 0, false, false
		end
		return self.scanCares
	end

	local function tick_scan(self)
		if self.scanT > 0 then return end
		local player = rt.static("Game", "GetPlayer")
		if self.scanWaiting then
			if player:IsDetectedBy(self.scanActor) then
				self.scan, self.scanCares = Scan.Done, true
				return
			end
			self.scanIdx, self.scanWaiting = self.scanIdx + 1, false
			return
		end
		if self.scanIdx >= rt.alen(self.bystanderaliasarray) then
			self.scan, self.scanCares = Scan.Done, false
			return
		end
		local actor = rt.aget(self.bystanderaliasarray, self.scanIdx):GetActorReference()
		if not actor then
			self.scan, self.scanCares = Scan.Done, false
			return
		end
		self.scanActor = actor
		player:IsDetectedBy(actor) -- the discarded priming check
		self.scanT, self.scanWaiting = 0.25, true
	end

	function C:CheckBystandersSendAlarmAndStopQuest()
		if self.alarm ~= Alarm.Idle then return end -- a run happens once
		local now = rt.static("Utility", "GetCurrentGameTime")
		local duration = now - self.dlc1vampirefeedstarttime:GetValue()
		self.durationRT = (duration / (24 * 60 * 60)) * self.timescale:GetValue()
		self.victimRef = self.victim:GetActorReference()
		self:CheckBystanders()
		self.alarm = Alarm.AwaitingScan
	end

	function C:OnTick()
		if self.scan == Scan.Checking then tick_scan(self) end
		if self.alarm == Alarm.AwaitingScan and self.scan == Scan.Done then
			if self.scanCares and self.durationRT <= 30 then
				self.victimRef:GetCrimeFaction():SendAssaultAlarm()
			end
			self:Stop()
			self.alarm, self.scan = Alarm.Idle, Scan.Idle
		end
	end
end
