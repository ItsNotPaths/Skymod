-- pex: inner.onactivate 7e3fa6b8
-- pex: mid.onactivate 3ed29747
-- pex: outer.onactivate cc81ecde
-- (solved, locked and isAnimating are bools that Papyrus compared with 0 and 1)
-- A turn played outer, inner or mid and waited for "Done", then (from mid) changed state and,
-- when solved, lit the flame and drained the player. Now the event finishes the turn; `going_to`
-- is the state it ends in, `side` the marker side, `turner` who turned it.
local rt = require('skymod.rt')

return function(C)
	C.__vars.going_to = rt.string("")
	C.__vars.side = rt.string("")
	C.__vars.turner = rt.form("ObjectReference")
	local Mid, Inner, Outer = rt.state(C, "mid"), rt.state(C, "inner"), rt.state(C, "outer")

	local function marker(self, side) return side == "outer" and self.xmarkerOuter or self.xmarkerInner end

	local function tail(self)
		if not self.solved then rt.static("Sound", "StopInstance", self.flameSoundInstanceID) end
	end

	local function turn(self, triggerRef, anim, going_to, side)
		self.isAnimating = true
		self.going_to, self.side, self.turner = going_to, side, triggerRef
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation(anim)
	end

	function Mid:OnActivate(triggerRef)
		if self.mainScript:GetState() == "Solution" and not self.isAnimating then
			local inner, outer = triggerRef:GetDistance(self.xmarkerInner), triggerRef:GetDistance(self.xmarkerOuter)
			if inner < outer then return turn(self, triggerRef, "outer", "outer", "outer") end
			if outer < inner then return turn(self, triggerRef, "inner", "inner", "inner") end
		elseif not self.isAnimating then
			self.wontBudge:Show()
		end
		tail(self)
	end

	local function to_mid(self, triggerRef, side)
		if self.mainScript:GetState() == "Solution" and not self.locked and not self.isAnimating then
			self:GotoState("mid")
			return turn(self, triggerRef, "mid", "", side)
		elseif not self.isAnimating then
			self.wontBudge:Show()
		end
		tail(self)
	end

	function Inner:OnActivate(triggerRef) to_mid(self, triggerRef, "inner") end
	function Outer:OnActivate(triggerRef) to_mid(self, triggerRef, "outer") end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" or not self.isAnimating then return end
		self.isAnimating = false
		local trig, side, to = self.turner, self.side, self.going_to
		self.going_to = ""
		if to ~= "" then self:GotoState(to) end
		if self.solved then
			self:PlayAnimation("flameon")
			if to ~= "" then -- lit from the middle: the flame and the drain on the player
				self.FXSeranaTombDrainLife2D:Play(rt.static("Game", "GetPlayer"))
				self.flameSoundInstanceID = self.QSTSeranaTombBrazierFireLPM:Play(marker(self, side))
			end
			trig:RampRumble(0.1, 1, 64)
			self.TargVFX:Play(trig, 2.0, marker(self, side))
			self.CastShader:Play(self, 2.0)
		end
		tail(self)
	end
end
