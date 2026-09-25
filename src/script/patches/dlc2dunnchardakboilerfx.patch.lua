-- pex: startboiler e5c517fc
-- pex: stopboiler 7eadb5c3
-- StartBoiler played Start and waited for ToLoop, then lit the six linked lights 0.25 s apart;
-- StopBoiler played Stop, waited for ToStopped and put them out the same way. Now `boiler` is that
-- run and `light_at` the next light. When a run ends, CheckBoilerState runs again, so a cube moved
-- during a run is not lost (a desired state, settled when busy ends).
local rt = require('skymod.rt')

return function(C)
	C.Boiler = rt.sequence("Idle", "Starting", "Lighting", "Stopping", "Dimming")
	local B = C.Boiler
	C.__vars.boiler = B.Idle
	C.__vars.boiler_t = rt.timer(0.0)
	C.__vars.light_at = rt.int(0)
	C.__vars.TickRate = rt.float(0.05)
	local Running = rt.state(C, "Running") -- OnTick only while a start/stop run is under way

	local function light(self, n) return self:GetLinkedRef(self["LinkCustom0" .. n]) end

	function C:StartBoiler()
		if self.boiler ~= B.Idle then return end
		self.boiler = B.Starting
		self:GotoState("Running")
		self:RegisterForAnimationEvent(self, "ToLoop")
		self:PlayAnimation("Start")
	end

	function C:StopBoiler()
		if self.boiler ~= B.Idle then return end
		self.boiler = B.Stopping
		self:GotoState("Running")
		self:RegisterForAnimationEvent(self, "ToStopped")
		self:PlayAnimation("Stop")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.boiler == B.Starting and asEventName == "ToLoop" then
			self.boilerIsRunning = true
			self.myInstance = self.QSTNchardakBoilerLPM:Play(self)
			self.boiler = B.Lighting
		elseif self.boiler == B.Stopping and asEventName == "ToStopped" then
			self.boilerIsRunning = false
			if self.myInstance >= 0 then rt.static("Sound", "StopInstance", self.myInstance) end
			self.boiler = B.Dimming
		else
			return
		end
		self.light_at = 1
		self.boiler_t = 0.0
		self:OnTick()
	end

	function Running:OnTick()
		if (self.boiler ~= B.Lighting and self.boiler ~= B.Dimming) or self.boiler_t > 0 then return end
		local l = light(self, self.light_at)
		if self.boiler == B.Lighting then l:EnableNoWait(true) else l:DisableNoWait(true) end
		if self.light_at < 6 then
			self.light_at = self.light_at + 1
			self.boiler_t = self.boiler_t + 0.25
			return
		end
		self.boiler = B.Idle
		self:CheckBoilerState()
		if self.boiler == B.Idle then self:GotoState("") end
	end
end
