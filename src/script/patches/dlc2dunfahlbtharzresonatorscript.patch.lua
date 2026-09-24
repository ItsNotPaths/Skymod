-- pex: activatesteamchain 129a8db9
-- pex: active.onactivate 723679b8
-- pex: inactive.onactivate 841ebea6
-- pex: reset.onbeginstate 8e686b73
-- A resonator opened or closed and waited for Trans01/Trans02, vented steam for 1 s, then waited
-- while the controller added its charge (lights, door, failure reset) before settling Active or
-- Inactive. A reset closed it and waited for Trans02. Now `run` is the resonator's own move and
-- `resetting` the reset's; the controller publishes `steam`, Idle when its work is done.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "Opening", "Closing", "Venting", "Adding")
	local R = C.Run
	C.__vars.run = R.Idle
	C.__vars.run_t = rt.timer(0.0)
	C.__vars.charge = rt.int(0)
	C.__vars.going_to = rt.string("")
	C.__vars.resetting = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Inactive, Active, Reset = rt.state(C, "Inactive"), rt.state(C, "Active"), rt.state(C, "Reset")

	local function start(self, run, anim, to)
		self.SteamController:SetIsBusy(true)
		self:GotoState("Busy")
		self.run, self.going_to = run, to
		self:RegisterForAnimationEvent(self, run == R.Opening and "Trans01" or "Trans02")
		self:PlayAnimation(anim)
	end

	function Inactive:OnActivate(akActivator)
		if self.SteamController:GetIsBusy() or self.run ~= R.Idle then return end
		self.wasReset = false
		start(self, R.Opening, "Open", "Active")
	end

	function Active:OnActivate(akActivator)
		if self.SteamController:GetIsBusy() or self.run ~= R.Idle then return end
		start(self, R.Closing, "Close", "Inactive")
	end

	function Reset:OnBeginState()
		self:GotoState("Busy")
		self.wasReset = true
		self.resetting = true
		self:RegisterForAnimationEvent(self, "Trans02")
		self:PlayAnimation("Close")
	end

	function C:ActivateSteamChain(SteamChargeChange)
		self:EnableLinkChain()
		self.charge = SteamChargeChange
		self.run = R.Venting
		self.run_t = 1.0
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "Trans02" and self.resetting then
			self.resetting = false
			self:GotoState("Inactive")
		end
		if self.run == R.Opening and asEventName == "Trans01" then
			self:ActivateSteamChain(self.SteamCharge)
		elseif self.run == R.Closing and asEventName == "Trans02" then
			self:ActivateSteamChain(0 - self.SteamCharge)
		end
	end

	function C:OnTick()
		if self.run == R.Venting and self.run_t <= 0 then
			if not self.SteamController then return self:finish() end
			self.run = R.Adding
			self.SteamController:AddSteam(self.charge, self)
		end
		if self.run == R.Adding and self.SteamController.steam.name == "Idle" then self:finish() end
	end

	function C:finish()
		self.run = R.Idle
		if self.going_to == "Inactive" or not self.wasReset then self:GotoState(self.going_to) end
	end
end
