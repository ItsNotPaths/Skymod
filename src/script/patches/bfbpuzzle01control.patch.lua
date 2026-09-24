-- pex: doorordarts bffd4ee7
-- pex: pulledposition.onactivate ab372e86
-- pex: pushedposition.onactivate 6addc1de
-- A pull checked the pillars (the door, or 1 s then the dart traps); for the player it then moved
-- the lever and waited for its end event. Now a timer holds the dart delay and the event sets the
-- position; `to_state` is the position the lever is moving to.
local rt = require('skymod.rt')

return function(C)
	C.__vars.to_state = rt.string("")
	C.__vars.animate = rt.bool(false) -- the player pulled: the lever moves
	C.__vars.darts = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local Busy = rt.state(C, "busy")
	local MOVE = { pushedPosition = { "FullPush", "FullPushedUp" }, pulledPosition = { "FullPull", "FullPulledDown" } }

	local function settle(self)
		if not self.animate then
			local to = self.to_state
			self.to_state = ""
			return self:GotoState(to)
		end
		local m = MOVE[self.to_state]
		self:RegisterForAnimationEvent(self, m[1])
		self:PlayAnimation(m[0])
	end

	-- returns true when the dart delay started; the rest waits for it
	function C:doorOrDarts()
		if self.numPillarsSolved ~= self.PillarCount then
			self.darts = 1.0
			return true
		end
		self.puzzleSolved = true
		self.refActOnSuccess01:Activate(self.puzzleDoorActivator)
		local openState = self.refActOnSuccess01:GetOpenState()
		self.doorOpened = openState == 1 or openState == 2
		return false
	end

	local function pull(self, triggerRef, to)
		self:GotoState("busy")
		self.to_state = to
		self.animate = rt.cast(triggerRef, "Actor") == rt.static("Game", "GetPlayer")
		if not self:doorOrDarts() then settle(self) end
	end

	rt.state(C, "pulledPosition").OnActivate = function(self, triggerRef) pull(self, triggerRef, "pushedPosition") end
	rt.state(C, "pushedPosition").OnActivate = function(self, triggerRef) pull(self, triggerRef, "pulledPosition") end

	function Busy:OnTick()
		if self.darts == rt.None or self.darts > 0 then return end
		self.darts = rt.None
		self.puzzleSolved = false
		for i = 1, 4 do self["refActOnFailure0" .. i]:Activate(self) end
		settle(self)
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		local m = MOVE[self.to_state]
		if akSource ~= self or not m or asEventName ~= m[1] then return end
		local to = self.to_state
		self.to_state = ""
		self:GotoState(to)
	end
end
