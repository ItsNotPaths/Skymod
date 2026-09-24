-- pex: active.onactivate a2f6616c
-- The lever turned both doors, enabled a blocker and waited for lever 2's push or pull to end,
-- then dropped the blocker and flipped doorState. Now Busy polls lever 2's animation.
local rt = require('skymod.rt')

return function(C)
	C.__vars.lever_anim = rt.string("")
	C.__vars.TickRate = rt.float(0.1)
	local Active, Busy = rt.state(C, "Active"), rt.state(C, "Busy")

	function Active:OnActivate(triggerRef)
		self:GotoState("Busy")
		local anim = self.doorState and "FullPush" or "FullPull"
		self.door01:PlayAnimation(self.doorState and "RotateClosed" or "RotateOpen")
		self.door02:PlayAnimation(self.doorState and "RotateOpen" or "RotateClosed")
		self.Lever01:PlayAnimation(anim)
		self.InvisibleCollision:Enable()
		self.lever_anim = anim
		self.Lever02:PlayAnimation(anim)
		self:OnTick()
	end

	function Busy:OnTick()
		if self.lever_anim == "" or self.Lever02:IsAnimRunning(self.lever_anim) then return end
		self.lever_anim = ""
		self.InvisibleCollision:Disable()
		self.doorState = not self.doorState
		self:GotoState("Active")
	end
end
