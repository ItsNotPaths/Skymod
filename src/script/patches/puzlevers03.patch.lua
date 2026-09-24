-- pex: onactivate 5b690f1d
-- A test lever: each pull moved to the next of three positions, waiting for each move's end
-- event (two moves from 2 back to 0), then told the controller. Now `moving` is the move under
-- way and the events step it; a pull during a move is dropped.
local rt = require('skymod.rt')

return function(C)
	C.Move = rt.sequence("Idle", "To1", "To2", "To0a", "To0b")
	local M = C.Move
	C.__vars.moving = M.Idle
	local function msg(s) rt.static("Debug", "MessageBox", s) end

	local function play(self, move, anim, done)
		self.moving = move
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	local function settle(self, state)
		self.moving = M.Idle
		msg("State to " .. state)
		self.leverState = state
		local m = self.mainScript
		m:CheckSolution()
		msg("Puzzle Solution: A = " .. tostring(m.lever01Solution) .. " B = " .. tostring(m.lever02Solution) .. " C = "
			.. tostring(m.lever03Solution) .. " D = " .. tostring(m.lever04Solution) .. " E = " .. tostring(m.lever05Solution))
	end

	function C:OnActivate(triggerRef)
		if self.moving ~= M.Idle then return end
		if self.leverState == 0 then
			play(self, M.To1, "PushUp", "UnPushed")
		elseif self.leverState == 1 then
			play(self, M.To2, "PullDown", "Pulled")
		elseif self.leverState == 2 then
			play(self, M.To0a, "PullUp", "UnPulled")
		else
			self.mainScript:CheckSolution()
		end
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.moving == M.To1 and asEventName == "UnPushed" then
			settle(self, 1)
		elseif self.moving == M.To2 and asEventName == "Pulled" then
			settle(self, 2)
		elseif self.moving == M.To0a and asEventName == "UnPulled" then
			play(self, M.To0b, "PushDown", "Pushed")
		elseif self.moving == M.To0b and asEventName == "Pushed" then
			settle(self, 0)
		end
	end
end
