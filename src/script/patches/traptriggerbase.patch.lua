-- pex: onactivate edb98ee9
-- pex: active.onbeginstate 022b78d9
-- pex: inactive.ontriggerleave a40cca24
-- pex: inactive.onbeginstate 15f754ee
-- Each waited only to space its steps (0 s before the self-activate, 0.1 s either side of it). The
-- steps now run in one go, so no trigger ticks: levers, plates and tripwires sit idle for free.
local rt = require('skymod.rt')

return function(C)
	C.__fn.ontick = nil
	local Active, Inactive = rt.state(C, "active"), rt.state(C, "inactive")

	function C:onActivate(akActivator)
		if not self.vars["::blockactivate_var"] or akActivator == self then return end
		local trigger = rt.cast(akActivator, "traptriggerbase")
		self.TriggerType = trigger and trigger.TriggerType or self.vars["::storedtriggertype_var"]
		self:blockActivation(false)
		self:localActivateFunction()
		self:Activate(self)
		self:blockActivation(true)
	end

	-- a hold trigger (stored type 1) fires as type 3 on press and type 4 on release
	local function release(self)
		if self.vars["::finiteuse_var"] and self.vars["::countused_var"] < self.vars["count"] then
			self.vars["::countused_var"] = self.vars["::countused_var"] + 1
		end
		self.vars["::type_var"] = 4
		self:Activate(self)
	end
	local function held_and_empty(self)
		return self.vars["::storedtriggertype_var"] == 1 and self.objectsInTrigger == 0
	end

	function Active:onBeginState()
		if self.vars["::storedtriggertype_var"] == 1 then self.vars["::type_var"] = 3 end
		self:Activate(self)
		if self.objectsInTrigger == 0 then self:GotoState("Inactive") end
	end

	function Inactive:OnTriggerLeave(triggerRef)
		if not self:acceptableTrigger(triggerRef) then return end
		self.vars["::lasttriggerref_var"] = triggerRef
		self.objectsInTrigger = self:GetTriggerObjectCount()
		if held_and_empty(self) then release(self) end
	end

	function Inactive:onBeginState()
		if held_and_empty(self) then release(self) end
	end
end
