-- pex: oncellattach 9cc9253f
-- On attach the reset waited 0.25 s, then set the two extending halls to their default state one
-- after the other (each waited for its animation), then re-armed the hall triggers. Now `reset`
-- steps that in OnTick: the delay, then each hall while its default animation plays.
local rt = require('skymod.rt')

return function(C)
	C.Reset = rt.sequence("Idle", "Delay", "Hall1", "Hall2")
	local S = C.Reset
	C.__vars.reset = S.Idle
	C.__vars.reset_t = rt.timer(0.0)
	C.__vars.rearm = rt.bool(false) -- the halls were reset to their default: re-arm the triggers after
	C.__vars.TickRate = rt.float(0.1)
	local Resetting = rt.state(C, "Resetting")

	function C:OnCellAttach()
		if self.reset ~= S.Idle then return end
		self.reset = S.Delay
		self.reset_t = 0.25
		self:GotoState("Resetting")
	end

	local function hall(self, n) return rt.cast(self["DLC2Book01AHall00" .. (n + 1)], "DLC2ApoExtendingHallScript") end

	local function start(self)
		self.ExtendingHall001, self.ExtendingHall002 = hall(self, 1), hall(self, 2)
		self.rearm = false
		if self.DLC2Book01ResetHalls:GetValue() == 1 then
			self.BendyHall = self.DLC2Book01AHall001
			if self.DLC2Book01TakenBookInPartA:GetValue() == 1 then
				self.BendyHall:GoToStartingPosition()
				self.DLC2Book01AHall002:Disable()
				self.DLC2Book01AHall002Cap:Disable()
				self.DLC2MQ06HallStaticEnableParent:Enable()
				self.DLC2Book01ResetHalls:SetValue(0)
				return false
			end
			self.BendyHall:GoToStartingPosition()
			self.ExtendingHall001.IsOpen = true
			self.ExtendingHall002.IsOpen = true
			self.rearm = true
		end
		self.ExtendingHall001:SetDefaultState()
		return true
	end

	function Resetting:OnTick()
		if self.reset == S.Delay then
			if self.reset_t > 0 then return end
			if not start(self) then
				self.reset = S.Idle
				return self:GotoState("")
			end
			self.reset = S.Hall1
		end
		if self.reset == S.Hall1 then
			if self.ExtendingHall001.hall ~= "" then return end
			self.ExtendingHall002:SetDefaultState()
			self.reset = S.Hall2
		end
		if self.ExtendingHall002.hall ~= "" then return end
		self.reset = S.Idle
		self:GotoState("")
		if not self.rearm then return end
		rt.cast(self.DLC2Book01AHall001Trigger, "DLC2Book01BendyHallwayActivator"):GotoState("Waiting")
		for _, t in ipairs({ self.DLC2Book01AHall002Trigger, self.DLC2Book01AHall003Trigger }) do
			t:Enable()
			rt.cast(t, "defaultActivateSelf"):GotoState("Waiting")
		end
		self.DLC2Book01ResetHalls:SetValue(0)
	end
end
