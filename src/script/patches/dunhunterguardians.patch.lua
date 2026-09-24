-- pex: crabevent 82fea9b8
-- pex: ontriggerenter afdfe004
-- crabEvent enabled the three motes, waited 2s, translated them up, waited 5s, then placed the
-- burst FX and disabled them. Now a stage read from OnTick. OnTriggerEnter's own linked-ref enable
-- and self disable/delete are independent of crabEvent (different refs) and still run at once, as
-- Papyrus's single thread did once it reached them; crabEvent keeps ticking on the (now deleted)
-- self instance to finish the motes.
local rt = require('skymod.rt')

return function(C)
	C.Step = rt.sequence("Idle", "Enabled", "Translated")
	C.__vars.crabStep = C.Step.Idle
	C.__vars.crabT = rt.timer(0.0)
	local S = C.Step
	local OFFSET, SPEED = 256.0, 50.0

	local function raise(ref)
		local x, y, z = ref:GetPositionX(), ref:GetPositionY(), ref:GetPositionZ()
		ref:TranslateTo(x, y, z + OFFSET, 180, 180, 180, SPEED)
	end

	function C:crabEvent()
		if self.crabStep ~= S.Idle then return end -- a second fire during the run is dropped
		self.crabMote01:Enable()
		self.crabMote02:Enable()
		self.summonLight:Enable()
		self.crabStep = S.Enabled
		self.crabT = 2.0
	end

	function C:OnTick()
		if self.crabStep == S.Enabled and self.crabT <= 0 then
			raise(self.crabMote01)
			raise(self.crabMote02)
			raise(self.summonLight)
			self.crabStep = S.Translated
			self.crabT = 5.0
		end
		if self.crabStep == S.Translated and self.crabT <= 0 then
			self.crabStep = S.Idle
			self.crabMote01:PlaceAtMe(self.moteBurst)
			self.crabMote02:PlaceAtMe(self.moteBurst)
			self.crabMote01:Disable()
			self.crabMote02:Disable()
			self.summonLight:Disable()
		end
	end

	function C:OnTriggerEnter(actronaut)
		if not self.dunHunterQST:GetStageDone(self.preReqStage) then return end
		if self.isCrab and not self.bFired then
			self.bFired = true
			self:crabEvent()
		end
		self:GetLinkedRef():Enable()
		self:Disable()
		self:Delete()
	end
end
