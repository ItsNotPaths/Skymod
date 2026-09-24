-- pex: onactivate ed7959eb
-- The lever pushed and waited for FullPushedUp, sounded its side, waited 0.4 s, then put out that
-- side's flame and, with both sides out, opened the door. Now the event and a timer walk it in a
-- Busy state.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Pushing", "Sounding")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "Busy")

	function C:OnActivate(trigRef)
		if not self.doOnce then return end
		self:GotoState("Busy")
		self.step = S.Pushing
		self:RegisterForAnimationEvent(self, "FullPushedUp")
		self:PlayAnimation("FullPush")
	end

	function Busy:OnActivate(trigRef) end -- a run happens once

	local function finish(self)
		self.step = S.Idle
		self.doOnce = false
		self:GotoState("")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if self.step ~= S.Pushing or akSource ~= self or asEventName ~= "FullPushedUp" then return end
		local side = self.leftLever and "left" or self.rightLever and "right"
		if not side then return finish(self) end
		self[side .. "Sound"]:Enable()
		self.step = S.Sounding
		self.t = 0.4
	end

	function Busy:OnTick()
		if self.step ~= S.Sounding or self.t > 0 then return end
		local mine, other = "Left", "Right"
		if not self.leftLever then mine, other = "Right", "Left" end
		self[string.lower(mine) .. "Flame"]:Disable()
		self["brightLight" .. mine]:Disable()
		if not self[string.lower(other) .. "Sound"]:IsDisabled() then
			self.brightLightBack:Disable()
			self.puzzDoor:Activate(self.doorMarker)
		end
		finish(self)
	end
end
