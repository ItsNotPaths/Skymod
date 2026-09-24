-- pex: doorordarts b1b64972
-- pex: pulledposition.onactivate a45a95bf
-- pex: pushedposition.onactivate ea2ca4fa
-- A pull checked the pillars (the door, or 1 s then the dart traps), then moved the lever and
-- waited for its end event. Now a timer holds the dart delay and the event sets the position;
-- `to_state` is the position the lever is moving to.
local rt = require('skymod.rt')

return function(C)
	C.__vars.to_state = rt.string("")
	C.__vars.darts = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "busy")
	local MOVE = { pushedPosition = { "FullPush", "FullPushedUp" }, pulledPosition = { "FullPull", "FullPulledDown" } }

	local function door(self, ref)
		ref:Activate(self.puzzleDoorActivator)
		local openState = ref:GetOpenState()
		self.doorOpened = openState == 1 or openState == 2
	end

	local function move(self)
		local m = MOVE[self.to_state]
		self:RegisterForAnimationEvent(self, m[1])
		self:PlayAnimation(m[0])
	end

	-- returns true when the dart delay started; the move then waits for it
	function C:doorOrDarts()
		if self.puzzleSolved and self.numPillarsSolved == 2 then
			door(self, self.refActOnSuccess01)
		elseif self.altSolution and self.numPillarsSolved == 2 then
			door(self, self.refActOnSuccess02)
		else
			self.darts = 1.0
			return true
		end
		return false
	end

	local function pull(self, to)
		self:GotoState("busy")
		self.to_state = to
		if not self:doorOrDarts() then move(self) end
	end

	rt.state(C, "pulledPosition").OnActivate = function(self, triggerRef) pull(self, "pushedPosition") end
	rt.state(C, "pushedPosition").OnActivate = function(self, triggerRef) pull(self, "pulledPosition") end

	function Busy:OnTick()
		if self.darts == rt.None or self.darts > 0 then return end
		self.darts = rt.None
		self.puzzleSolved = false
		for i = 1, 4 do self["refActOnFailure0" .. i]:Activate(self) end
		move(self)
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		local m = MOVE[self.to_state]
		if akSource ~= self or not m or asEventName ~= m[1] then return end
		local to = self.to_state
		self.to_state = ""
		self:GotoState(to)
	end
end
