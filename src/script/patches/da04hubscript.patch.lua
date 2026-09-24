-- pex: openhub d910e4aa
-- pex: ready.onactivate 4b1df5af
-- pex: rotatehub 14358ab2
-- RotateHub played Trigger0N and waited for Trans0N; the lever then offered or withdrew the open
-- button. OpenHub waited for the lexicon to be inscribed, for its own "Complete" and for the
-- lens's "Lower", then showed the Elder Scroll. Now events and OnTick in busy walk those steps.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Turning", "Inscribing", "Completing", "Lowering")
	local S = C.Step
	C.__vars.step = S.Idle
	C.__vars.TickRate = rt.float(0.1)
	local Ready, Busy = rt.state(C, "ready"), rt.state(C, "busy")

	local function stand(self) return rt.cast(self.LexiconStand, "DA04LexiconStand") end

	function Ready:OnActivate(TriggerRef)
		if TriggerRef == self.RotateLever then
			self:RotateHub()
		elseif TriggerRef == self.OpenLever and self:ReadyToOpen() then
			self:OpenHub()
		end
	end

	function C:RotateHub()
		self:GotoState("busy")
		self.step = S.Turning
		self:RegisterForAnimationEvent(self, "Trans0" .. self.currentPos)
		self:PlayAnimation("Trigger0" .. self.currentPos)
	end

	function C:OpenHub()
		self:GotoState("busy")
		self.step = S.Inscribing
		stand(self):Inscribe()
		self:OnTick()
	end

	function Busy:OnTick()
		if self.step == S.Inscribing and stand(self):GetState() ~= "busy" then
			self.step = S.Completing
			self:RegisterForAnimationEvent(self, "Done")
			self:PlayAnimation("Complete")
		elseif self.step == S.Lowering and not self.Lens:IsAnimRunning("Lower") then
			self.step = S.Idle
			self.ElderScroll:Enable()
			rt.cast(self.DA04, "DA04QuestScript").AstrolabeOpened = true
			self:GotoState("opened")
		end
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self then return end
		if self.step == S.Turning and asEventName == "Trans0" .. self.currentPos then
			local nextPos = self.currentPos + 1
			self.currentPos = nextPos > self.maxPos and self.minPos or nextPos
			self.step = S.Idle
			self:GotoState("ready")
			local button = rt.cast(self.OpenLever, "DA04ButtonScript")
			if self:ReadyToOpen() then button:Open() else button:Close() end
		elseif self.step == S.Completing and asEventName == "Done" then
			self.step = S.Lowering
			self.Lens:PlayAnimation("Lower")
		end
	end
end
