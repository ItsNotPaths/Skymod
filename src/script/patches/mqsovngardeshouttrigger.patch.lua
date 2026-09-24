-- pex: onactivate 819c15af
-- OnActivate could run two waiting blocks in order: enable the fog after a RandomFloat(0,3) delay
-- (from Alduin's shout), then, if stage 100 is done, disable it after RandomFloat(0,1) and 2s
-- more. A stage plus one timer now walks the same order in OnTick. The parent class (MQShoutTrigger)
-- already ticks for fireTriggerEvent's own split; chain to it, since a subclass OnTick replaces it.
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", tostring(self) .. msg) end

return function(C)
	C.Act = rt.sequence("Idle", "Enabling", "Disabling1", "Disabling2")
	C.__vars.act = C.Act.Idle
	C.__vars.actT = rt.timer(0.0)
	local S = C.Act

	local function begin_disable(self)
		self.allowEnableFlag = false
		trace(self, " disabling from stage 100")
		self.act = S.Disabling1
		self.actT = rt.static("Utility", "RandomFloat", 0.0, 1.0)
	end

	function C:OnActivate(akActionRef)
		self.tempupdateCount = self.tempupdateCount + 1
		if self.act ~= S.Idle then return end -- a run happens once
		local pMQ305Script = rt.cast(self.MQ305, "mq305script")
		local doEnable = false
		if self.MQ305:GetStageDone(30) and not self.MQ305:GetStageDone(100) then
			doEnable = not self:IsFogOn() and pMQ305Script.MistClearCount == 0
		end
		local doDisable = self.MQ305:GetStageDone(100)
		if doEnable then
			trace(self, " enabling from Alduin's shout")
			self.act = S.Enabling
			self.actT = rt.static("Utility", "RandomFloat", 0.0, 3.0)
		elseif doDisable then
			begin_disable(self)
		end
	end

	function C:OnTick()
		rt.parent(self, "MQSovngardeShoutTrigger", "OnTick")
		if self.act == S.Idle or self.actT > 0 then return end
		if self.act == S.Enabling then
			self:setFogState(true)
			trace(self, " enabling from Alduin's shout DONE")
			-- Papyrus checks stage 100 again once the enable is done
			if self.MQ305:GetStageDone(100) then begin_disable(self) else self.act = S.Idle end
		elseif self.act == S.Disabling1 then
			self:setFogState(false)
			self.act = S.Disabling2
			self.actT = 2.0
		else
			self:Disable()
			trace(self, " disabling from stage 100 DONE")
			self.act = S.Idle
		end
	end
end
