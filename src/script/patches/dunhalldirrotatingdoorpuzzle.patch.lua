-- pex: active.onactivate 845beba0
-- pex: waitingforpuzzle.onactivate 7b45ed60
-- pex: onload f1784077
-- pex: onreset 2d8eac4d
-- The lever waited on its own push and pull animations, and 1.5 s after moving the door. OnLoad
-- waited 0.25 s before snapping the door open. Now `step` walks the moves, the lever's events
-- end each animation and a timer the pauses; `closing` is where the door is going.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Loading", "FailPush", "FailPull", "Moving", "Settling")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.closing = rt.bool(false)
	C.__vars.TickRate = rt.float(0.05)
	local Puzzle, Active, Busy = rt.state(C, "WaitingForPuzzle"), rt.state(C, "Active"), rt.state(C, "Busy")

	local function solved(self) return self.numPillarsSolved == self.PillarCount end

	local function fail(self)
		self.FailSFX:Play(self)
		for n = 1, 4 do self["refActOnFailure0" .. n]:Activate(self) end
	end

	local function play(self, step, anim, done)
		self.step = step
		self:RegisterForAnimationEvent(self, done)
		self:PlayAnimation(anim)
	end

	function C:OnLoad()
		self.step = S.Loading
		self.t = 0.25
	end

	function C:OnReset()
		self.door01:PlayAnimation("SnapOpen")
		self:PlayAnimation("FullPull")
	end

	function C:OnTick()
		if self.step == S.Loading and self.t <= 0 then
			self.step = S.Idle
			self.door01:PlayAnimation("SnapOpen")
			self:PlayAnimation("FullPull")
		elseif self.step == S.Settling and self.t <= 0 then
			self.step = S.Idle
			self.doorClosed = self.closing
			if solved(self) then return self:GotoState("Active") end
			fail(self)
			self:GotoState("WaitingForPuzzle")
		end
	end

	function Puzzle:OnActivate(triggerRef)
		self:GotoState("Busy")
		if solved(self) then
			self.doorClosed = true
			self:GotoState("Active")
			return self:Activate(rt.static("Game", "GetPlayer"))
		end
		fail(self)
		play(self, S.FailPush, "FullPush", "FullPushedUp")
	end

	function Active:OnActivate(triggerRef)
		self:GotoState("Busy")
		if self.doorClosed then
			if not solved(self) then
				fail(self)
				return self:GotoState("WaitingForPuzzle")
			end
			self.door01:PlayAnimation("RotateClosed")
			self.closing = false
			play(self, S.Moving, "FullPush", "FullPushedUp")
		else
			self.door01:PlayAnimation("RotateOpen")
			self.closing = true
			play(self, S.Moving, "FullPull", "FullPulledDown")
		end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.step == S.FailPush and asEventName == "FullPushedUp" then
			play(self, S.FailPull, "FullPull", "FullPulledDown")
		elseif self.step == S.FailPull and asEventName == "FullPulledDown" then
			self.step = S.Idle
			self:GotoState("WaitingForPuzzle")
		elseif self.step == S.Moving and (asEventName == "FullPushedUp" or asEventName == "FullPulledDown") then
			self.step = S.Settling
			self.t = 1.5
		end
	end
end
