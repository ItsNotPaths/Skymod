-- pex: onactivate c1a1f93b
-- A random roll picked one of three branches: low (anim1, wait 0.3, spawn debris, wait 1.0,
-- anim2), mid (anim2 only), high (anim1, wait 0.5, anim3); >=75 does nothing. The roll and the
-- branch are facts (`dustBranch`); the two-wait low branch needs the extra `dustStage`.
local rt = require('skymod.rt')

local Stage = rt.sequence("Idle", "Step1", "Step2")

return function(C)
	C.__vars.dustStage = Stage.Idle
	C.__vars.dustBranch = rt.int(0)
	C.__vars.dustT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05)

	function C:OnActivate(triggerRef)
		if self.dustStage ~= Stage.Idle then return end -- a run happens once
		local r = rt.static("Utility", "RandomInt", 0, 100)
		if r < 25 then
			self:PlayAnimation("PlayAnim01")
			self.ambdustdropdebris:Play(self)
			self.dustBranch, self.dustStage, self.dustT = 1, Stage.Step1, 0.3
		elseif r < 50 then
			self:PlayAnimation("PlayAnim02")
			self.ambdustdropdebris:Play(self)
		elseif r < 75 then
			self:PlayAnimation("PlayAnim01")
			self.ambdustdropdebris:Play(self)
			self.dustBranch, self.dustStage, self.dustT = 2, Stage.Step1, 0.5
		end
	end

	function C:OnTick()
		if self.dustStage == Stage.Idle or self.dustT > 0 then return end
		if self.dustStage == Stage.Step1 then
			if self.dustBranch == 1 then
				self:PlaceAtMe(self.fallingdustexplosion01)
				self.dustStage, self.dustT = Stage.Step2, 1.0
			else -- the r>=50,<75 branch: only one more step
				self:PlayAnimation("PlayAnim03")
				self.ambdustdropdebris:Play(self)
				self.dustStage = Stage.Idle
			end
		elseif self.dustStage == Stage.Step2 then
			self:PlayAnimation("PlayAnim02")
			self.ambdustdropdebris:Play(self)
			self.dustStage = Stage.Idle
		end
	end
end
