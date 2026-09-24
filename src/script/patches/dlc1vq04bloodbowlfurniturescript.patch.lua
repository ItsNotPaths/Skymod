-- pex: done.onbeginstate 6f42572a e9afdb00
-- Done played Trigger04, waited for "Done" and 1 s more, then shook the room and set the stage.
-- Now the event starts that second and OnTick in Done ends it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.shake = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local Done = rt.state(C, "Done")

	function Done:OnBeginState()
		self:UnregisterForAnimationEvent(self.DLC1SeranaRef, "Trigger04")
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Trigger04")
	end

	function Done:OnAnimationEvent(akSource, asEventName)
		if akSource == self and asEventName == "Done" and self.shake == rt.None then self.shake = 1.0 end
	end

	function Done:OnTick()
		if self.shake == rt.None or self.shake > 0 then return end
		self.shake = rt.None
		rt.static("Game", "ShakeController", self.rumbleAmount1, self.rumbleAmount1, self.rumbleDuration)
		rt.static("Game", "ShakeCamera", rt.None, self.cameraShakeAmount1, self.rumbleDuration)
		self.DLC1VQ04:SetStage(self.Stage)
	end
end
