-- pex: rise 924575be
-- Rise ran five one-shot steps end to end: shake camera, wait 0.25, enable water churn, wait 0.25,
-- play rumble2 and translate self and the linked object, wait 2, play rumble3, wait 2. Now a stage
-- of rt.sequence plus one timer walks the steps in OnTick; riseStage reaching Done is the fact
-- fragment_0 reads to know Rise finished.
local rt = require('skymod.rt')

return function(C)
	C.RiseStage = rt.sequence("Ready", "Churn", "Move", "Settle", "Hold", "Done")
	C.__vars.riseStage = C.RiseStage.Ready
	C.__vars.riseT = rt.timer(0.0)
	local S = C.RiseStage

	function C:Rise()
		if self.riseStage ~= S.Ready then return end -- a second start while rising is dropped
		self.loopingsoundid = self.rumble:Play(self)
		rt.static("Game", "ShakeCamera")
		rt.static("Game", "ShakeController", 0.5, 0.5, 2.0)
		self.riseStage = S.Churn
		self.riseT = 0.25
	end

	local old_ontick = C.__fn.ontick
	function C:OnTick()
		old_ontick(self)
		if self.riseStage == S.Ready or self.riseStage == S.Done then return end
		if self.riseT > 0 then return end
		if self.riseStage == S.Churn then
			self.mywaterchurn:Enable(true)
			self.riseStage = S.Move
			self.riseT = self.riseT + 0.25
		elseif self.riseStage == S.Move then
			self.rumble2:Play(self)
			local objectOnColumn = self:GetLinkedRef()
			local objectTargetZPos = (objectOnColumn:GetPositionZ() - self:GetPositionZ()) + self.targetzpos
			objectOnColumn:BlockActivation(true)
			self:TranslateTo(self:GetPositionX(), self:GetPositionY(), self.targetzpos,
				self:GetAngleX(), self:GetAngleY(), self:GetAngleZ(), 50.0)
			objectOnColumn:TranslateTo(objectOnColumn:GetPositionX(), objectOnColumn:GetPositionY(), objectTargetZPos,
				objectOnColumn:GetAngleX(), objectOnColumn:GetAngleY(), objectOnColumn:GetAngleZ(), 50.0)
			self.riseStage = S.Settle
			self.riseT = self.riseT + 2.0
		elseif self.riseStage == S.Settle then
			self.rumble3:Play(self)
			self.riseStage = S.Hold
			self.riseT = self.riseT + 2.0 -- Papyrus's trailing Wait(2) before the function returned
		elseif self.riseStage == S.Hold then
			self.riseStage = S.Done
		end
	end
end
