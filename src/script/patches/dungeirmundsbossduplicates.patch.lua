-- pex: dismissduplicate 3762c189
-- DismissDuplicate faded out over one Wait(1); `dismissing` is the fact EndSigdisBattle's
-- callers (dunreachwaterrocksigdisbossbattle.patch.lua) wait on.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.dismissing = rt.bool(false)
	C.__vars.fade = rt.timer(0.0)
	local split_tick = C.__fn.ontick -- OnLoad's own wait, from the S6 split

	function C:DismissDuplicate()
		if self.dismissing then return end
		self.dismissing = true
		self.fade = 1.0
		self:SetAV("Variable06", 1.0)
		self:EvaluatePackage()
		self.IllusionFX:Play(self)
	end

	function C:OnTick()
		split_tick(self)
		if not self.dismissing or self.fade > 0 then return end
		self.dismissing = false
		self:SetAlpha(0.2, true)
		self:Disable(false)
		self:Delete()
	end
end
