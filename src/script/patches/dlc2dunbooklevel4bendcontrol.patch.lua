-- pex: bend 656e7e52
-- pex: continuebending.onbeginstate dcc5619d
-- bend(0) played Left and waited for "done", then bent left and right forever, each move waiting
-- for doneLeft/doneRight. The other bends only waited for their animation's end, with nothing
-- after. Now the events drive it; `starting` is the first Left before the loop.
local rt = require('skymod.rt')

return function(C)
	C.__vars.starting = rt.bool(false)
	local Bending = rt.state(C, "ContinueBending")
	local ANIM = { [1] = "Right", [2] = "Left", [3] = "Reset" }

	function C:bend(myBend)
		if myBend ~= 0 then return self:PlayAnimation(ANIM[myBend] or "") end
		if self.starting or self.Bending then return end -- a run happens once
		self.starting = true
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("Left")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or not self.starting or asEventName ~= "done" then return end
		self.starting = false
		self.Bending = true
		self:GotoState("ContinueBending")
	end

	function Bending:OnBeginState()
		if not self.Bending then return end
		self:RegisterForAnimationEvent(self, "doneLeft")
		self:RegisterForAnimationEvent(self, "doneRight")
		self:PlayAnimation("Left")
	end

	function Bending:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or not self.Bending then return end
		if asEventName == "doneLeft" then
			self:PlayAnimation("Right")
		elseif asEventName == "doneRight" then
			self:PlayAnimation("Left")
		end
	end
end
