-- pex: ondestructionstagechanged fdec654c
-- At destruction stage 3 a pool used up by the fire played oilAnim and waited for
-- oilDisappearEvent before putting out its light and disabling itself. The event now does it;
-- `vanishing` says the pool is playing out.
local rt = require('skymod.rt')

return function(C)
	C.__vars.vanishing = rt.bool(false)

	local function burned_out(self)
		if not self.lightStaysOn and self.myLinkedRef then self.myLinkedRef:Disable() end
		if self.deleteSelfAfterIgnition then
			self:Disable()
		else
			self:Reset()
			self:ClearDestruction()
			self:GotoState("Waiting")
		end
	end

	function C:OnDestructionStageChanged(aiOldStage, aiCurrentStage)
		self.myLinkedRef = self:GetLinkedRef()
		if aiCurrentStage == 2 then self:PlaceAtMe(self.OilExplosion) end
		if aiCurrentStage < 3 and not self.lightIsOn and self.myLinkedRef then
			self.lightIsOn = true
			self.myLinkedRef:Enable()
		end
		if aiCurrentStage ~= 3 then return end
		if not self.deleteSelfAfterIgnition then return burned_out(self) end
		if self.vanishing then return end
		self.vanishing = true
		self:RegisterForAnimationEvent(self, self.oilDisappearEvent)
		self:PlayAnimation(self.oilAnim)
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if not self.vanishing or akSource ~= self or asEventName ~= self.oilDisappearEvent then return end
		self.vanishing = false
		burned_out(self)
	end
end
