-- pex: bend e0e96558
-- pex: returntolastposition 5f79883f
-- pex: returntostartingposition 56865f56
-- bend waited while another bend ran, then played the hallway's bend and waited for its done
-- event. Now the event ends the bend; `going_to` is the position it ends at, and a bend asked for
-- meanwhile is kept in `want` (the latest wins) and starts when this one ends.
local rt = require('skymod.rt')

local ANIM = { { "Reset", "done" }, { "Right", "doneRight" }, { "Left", "doneLeft" } } -- by position 0..2

return function(C)
	C.__vars.going_to = rt.int(-1)
	C.__vars.back_from = rt.int(-1) -- a return to the last position: where it came from, the next previousPosition
	C.__vars.want = rt.int(-1)

	local function end_run(self)
		self.Bending = false
		if self.want == -1 then return end
		local b = self.want
		self.want = -1
		self:bend(b)
	end

	local function move(self, pos, back_from)
		local a = ANIM[pos]
		if not a then
			if back_from ~= -1 then self.previousPosition = back_from end
			return end_run(self)
		end
		self.going_to, self.back_from = pos, back_from
		self:RegisterForAnimationEvent(self, a[1])
		self:PlayAnimation(a[0])
	end

	function C:bend(myBend)
		if self.Bending then
			self.want = myBend
			return
		end
		if myBend ~= 4 then self.previousPosition = self.currentPosition end
		self.Bending = true
		if myBend >= 0 and myBend <= 2 then
			move(self, myBend, -1)
		elseif myBend == 3 then
			self:ReturnToStartingPosition()
		elseif myBend == 4 then
			self:ReturnToLastPosition()
		else
			end_run(self)
		end
	end

	function C:ReturnToStartingPosition() move(self, self.startingPosition, -1) end
	function C:ReturnToLastPosition() move(self, self.previousPosition, self.currentPosition) end

	function C:OnAnimationEvent(akSource, asEventName)
		local pos = self.going_to
		if akSource ~= self or pos == -1 or asEventName ~= ANIM[pos][1] then return end
		self.currentPosition = pos
		if self.back_from ~= -1 then self.previousPosition = self.back_from end
		self.going_to, self.back_from = -1, -1
		end_run(self)
	end
end
