-- pex: killswitch 2d1dd873
-- pex: upposition.onactivate d8d136fb
-- A pull pushed the lever (wait for FullPushedUp), then lit this lever's flame if the order was
-- right; a wrong one waited 1 s and pulled the lever back (wait for FullPulledUp). The snake
-- lever waited 0.5 s before opening the door. Now the busy state steps it, `step` says where.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Pushing", "KillWait", "Pulling", "SnakeWait")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Up, Busy = rt.state(C, "upPosition"), rt.state(C, "busy")

	local function done(self)
		self.step = S.Idle
		self:GotoState("upPosition")
	end

	function C:killSwitch()
		self.step = S.KillWait
		self.t = 1.0
	end

	function Up:OnActivate(triggerRef)
		if triggerRef ~= rt.static("Game", "GetPlayer") or self.correct then return end
		self:GotoState("busy")
		self.step = S.Pushing
		self:RegisterForAnimationEvent(self, "FullPushedUp")
		self:PlayAnimation("FullPush")
	end

	local function judge(self)
		done(self)
		if self.leverEagleA then
			if self.flameEagleA:IsDisabled() and self.flameFox:IsDisabled() and self.flameWhale:IsDisabled() and self.flameSnake:IsDisabled() then
				self.flameEagleA:Enable()
				self.correct = true
			else
				self:killSwitch()
			end
		elseif self.leverFox then
			if self.flameSnake:IsDisabled() and self.flameFox:IsDisabled() then
				self.flameFox:Enable()
				self.correct = true
			else
				self:killSwitch()
			end
		elseif self.leverWhale then
			if not self.flameEagleA:IsDisabled() then
				self.flameWhale:Enable()
				self.correct = true
			else
				self:killSwitch()
			end
		elseif self.leverSnake then
			if not self.flameFox:IsDisabled() then
				self.flameSnake:Enable()
				self.step = S.SnakeWait
				self.t = 0.5
			else
				self:killSwitch()
			end
		end
		if self.step ~= S.Idle then self:GotoState("busy") end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.step == S.Pushing and asEventName == "FullPushedUp" then
			judge(self)
		elseif self.step == S.Pulling and asEventName == "FullPulledUp" then
			done(self)
		end
	end

	function Busy:OnTick()
		if self.t > 0 then return end
		if self.step == S.KillWait then
			self.step = S.Pulling
			self:RegisterForAnimationEvent(self, "FullPulledUp")
			self:PlayAnimation("FullPull")
		elseif self.step == S.SnakeWait then
			done(self)
			self.lQuest:SetStage(30)
			self.puzzDoor:Activate(self.openMarker)
		end
	end
end
