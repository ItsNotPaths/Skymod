-- pex: active.onbeginstate b96c426b
-- A hold plate (stored type 1) waited 0.1 s either side of its self-activate, only to space the
-- steps; they now run in one go, so no plate ticks (see traptriggerbase.patch.lua).
local rt = require('skymod.rt')

return function(C)
	C.__fn.ontick = nil
	local Active = rt.state(C, "active")

	function Active:onBeginState()
		self:GotoState("DoNothing")
		if self.vars["::storedtriggertype_var"] == 1 then self.vars["::type_var"] = 3 end
		self:Activate(self)
		rt.call(self.vars["::triggersound_var"], "play", self)
		self:playAnimation("Down")
		if self.objectsInTrigger == 0 then
			self:GotoState("Inactive")
			self:playAnimation("Up")
		end
	end
end
