-- pex: downposition.onactivate c0d491db
-- pex: upposition.onactivate 7f97c29f
-- The lever moved, waited for its end event and 0.3 s more, then (going down, once) enabled the
-- encounter and set the new position. Now the event starts a 0.3 s timer and the class OnTick
-- (beside the split OnInit wait) ends the move; `to_state` is the position it is moving to.
local rt = require('skymod.rt')

return function(C)
	C.__vars.to_state = rt.string("")
	C.__vars.done_event = rt.string("")
	C.__vars.settle = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "busy")
	local split_tick = C.__fn.ontick -- OnInit's own split wait

	local function move(self, to, wall, floor)
		self:GotoState("busy")
		self.to_state = to
		local m = self.isOnWall and wall or floor
		self.done_event = m[1]
		self:RegisterForAnimationEvent(self, m[1])
		self:PlayAnimation(m[0])
	end

	rt.state(C, "upPosition").OnActivate = function(self, triggerRef)
		move(self, "downPosition", { "FullPull", "FullPulledDown" }, { "PullDown", "Pulled" })
	end
	rt.state(C, "downPosition").OnActivate = function(self, triggerRef)
		move(self, "upPosition", { "FullPush", "FullPushedUp" }, { "PullUp", "UnPulled" })
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or self.to_state == "" or asEventName ~= self.done_event then return end
		self.settle = 0.3
	end

	function C:OnTick()
		split_tick(self)
		if self.settle == rt.None or self.settle > 0 then return end
		self.settle = rt.None
		local to = self.to_state
		self.to_state = ""
		if to == "downPosition" and not self.puzzleEncounterEnabled then
			self.puzzleEncounter:Enable()
			self.puzzleEncounterEnabled = true
		end
		self:GotoState(to)
	end
end
