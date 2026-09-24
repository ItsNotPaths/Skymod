-- pex: waitingforhit.onhit 1a0e9746
-- A hit chime opened (waited for "done"), turned the steam on, called ChimeHit (which waited for
-- any fail response), and turned the steam off 1 s later. Now `ring` is the step: the event ends
-- the opening, OnTick waits while the master is Failing, then times the steam. The master's
-- StopGlow moves the chime between its states during a run, so the run lives at class level.
local rt = require('skymod.rt')

local Ring = rt.sequence("Idle", "Opening", "InMaster", "Steaming")

return function(C)
	C.__vars.ring = Ring.Idle
	C.__vars.steamWait = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local WaitingForHit = rt.state(C, "WaitingForHit")

	local function steam(self) return self.ChimeMaster:GetLinkedRef(self.LinkCustom07) end
	local function master(self) return rt.cast(self.ChimeMaster, "dlc01dundbchimemasterscript") end

	function WaitingForHit:OnHit(akAggressor, akSource, akProjectile, abPowerAttack, abSneakAttack, abBashAttack, abHitBlocked)
		if self.AlreadyHit then return end
		self:GotoState("WaitingForReset")
		self.AlreadyHit = true
		self.ring = Ring.Opening
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("open")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if self.ring ~= Ring.Opening or akSource ~= self or asEventName ~= "done" then return end
		self.ring = Ring.InMaster
		steam(self):Enable()
		local failing = master(self):GetState() == "Failing"
		master(self):ChimeHit(self.ChimeNumber, self.form)
		-- a fail already under way is not this call's: the call returned at once (or was dropped)
		if failing then self.ring, self.steamWait = Ring.Steaming, 1.0 else self:OnTick() end
	end

	function C:OnTick()
		if self.ring == Ring.InMaster then
			if master(self):GetState() == "Failing" then return end
			self.ring, self.steamWait = Ring.Steaming, 1.0
		elseif self.ring == Ring.Steaming and self.steamWait <= 0 then
			self.ring = Ring.Idle
			steam(self):Disable()
		end
	end
end
