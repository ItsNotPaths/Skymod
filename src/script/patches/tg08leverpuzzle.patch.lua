-- pex: complete.onbeginstate 62eb6517
-- pex: pulledposition.onactivate ea19a6b0
-- pex: pushedposition.onbeginstate 9fd24ae8
-- A push waited for FullPushedUp; the pushed lever then polled its partner every 0.2 s for
-- PulledTimerDuration (a real-time deadline) and pulled back, waiting for FullPulledDown. The
-- parent lever's Complete state opened the spears and hid the gate 4 s later. Now the events end
-- the moves and OnTick in pushedPosition and Complete does the polling and the delay.
local rt = require('skymod.rt')

return function(C)
	C.__vars.pulled_t = rt.timer(0.0)
	C.__vars.gate_t = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.2)
	local Pulled, Pushed, Busy, Complete = rt.state(C, "pulledPosition"), rt.state(C, "pushedPosition"), rt.state(C, "busy"), rt.state(C, "Complete")

	function Pulled:OnActivate(triggerRef)
		self:GotoState("busy")
		self.isInPullPosition = false
		self:RegisterForAnimationEvent(self, "FullPushedUp")
		self:PlayAnimation("FullPush")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if asEventName == "FullPushedUp" then
			self:GotoState("pushedPosition")
		elseif asEventName == "FullPulledDown" then
			self:GotoState("pulledPosition")
			self:spinDown()
		end
	end

	function Pushed:OnBeginState()
		self:spinUp()
		self.leverActivated = true
		self.pulled_t = self.PulledTimerDuration
		self:OnTick()
	end

	function Pushed:OnTick()
		if not self.puzzleSolved and self.pulled_t > 0 then
			local pair = rt.cast(self.pairedLever, "TG08LeverPuzzle")
			if self.parentLever and pair.leverActivated then
				pair.puzzleSolved = true
				self.puzzleSolved = true
			end
			if not self.puzzleSolved then return end
		end
		if self.puzzleSolved then return self:GotoState("Complete") end
		self.leverActivated = false
		self:GotoState("busy")
		self.isInPullPosition = true
		self:RegisterForAnimationEvent(self, "FullPulledDown")
		self:PlayAnimation("FullPull")
	end

	function Complete:OnBeginState()
		if not self.parentLever then return end
		self.poleLinker:Activate(self)
		self.gate_t = 4.0
	end

	function Complete:OnTick()
		if self.gate_t == rt.None or self.gate_t > 0 then return end
		self.gate_t = rt.None
		self.TG08BPuzzleGateEnableParent:Disable()
	end
end
