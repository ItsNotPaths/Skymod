-- pex: onload 7d9f5662
-- pex: ready.onactivate 5dfed3d7
-- pex: rotateforward a3bfbf6f
-- pex: rotatereverse 614a9094
-- A lever pull opened or closed the lexicon stand (which waited for its button), then turned the
-- armillary one step and waited for Trans0N. Now `target_pos` is where the armillary should
-- point; OnTick in busy waits for the stand to settle, then turns, and the event ends each turn.
local rt = require('skymod.rt')

return function(C)
	C.__vars.target_pos = rt.int(-1)
	C.__vars.turning_to = rt.int(-1) -- the position the running turn ends at; -1 at rest
	C.__vars.TickRate = rt.float(0.1)
	local Ready, Busy = rt.state(C, "ready"), rt.state(C, "busy")

	function C:OnLoad()
		if self.vars["__initted"] then return end
		self.vars["__initted"] = true
		self:RegisterForAnimationEvent(self, "Trans00")
		self:PlayAnimation("Engage")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Trans00" or self.currentPos ~= -1 then return end
		self.currentPos = 1
		self:GotoState("ready")
	end

	local function turn_to(self, pos)
		self.target_pos = math.max(self.minPos, math.min(self.maxPos, pos))
		self:GotoState("busy")
		self:OnTick()
	end

	function Ready:OnActivate(TriggerRef)
		local nextPos = self.currentPos
		if TriggerRef == self.ForwardLever then
			nextPos = nextPos + 1
		elseif TriggerRef == self.ReverseLever then
			nextPos = nextPos - 1
		end
		if nextPos == 5 then
			rt.cast(self.LexiconStand, "DA04LexiconStand"):OpenUp()
		else
			rt.cast(self.LexiconStand, "DA04LexiconStand"):CloseDown()
		end
		if TriggerRef == self.ForwardLever or TriggerRef == self.ReverseLever then turn_to(self, nextPos) end
	end

	function C:RotateForward() turn_to(self, self.currentPos + 1) end
	function C:RotateReverse() turn_to(self, self.currentPos - 1) end

	function Busy:OnTick()
		if self.turning_to ~= -1 then return end
		if rt.cast(self.LexiconStand, "DA04LexiconStand"):GetState() == "busy" then return end
		if self.currentPos == self.target_pos then return self:GotoState("ready") end
		local fwd = self.target_pos > self.currentPos
		self.turning_to = self.currentPos + (fwd and 1 or -1)
		self:RegisterForAnimationEvent(self, (fwd and "Trans0" or "TransRev0") .. self.turning_to)
		self:PlayAnimation((fwd and "Pos0" or "Rev0") .. self.turning_to)
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		local n = self.turning_to
		if akSource ~= self or n == -1 then return end
		if asEventName ~= "Trans0" .. n and asEventName ~= "TransRev0" .. n then return end
		self.currentPos = n
		self.turning_to = -1
		self:OnTick()
	end
end
