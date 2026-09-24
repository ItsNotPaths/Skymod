-- pex: waiting.onactivate def26bc4
-- The canned dust waited for its end event with nothing after, and the state never changed, so a
-- second activation played again in parallel. Only the play stays.
local rt = require('skymod.rt')

return function(C)
	local Waiting = rt.state(C, "waiting")

	function Waiting:OnActivate(triggerRef)
		self.objSelf = self.form
		if self.rockfallSound then self.rockfallSound:Play(self.objSelf) end
		if self.cannedHallwayDust then
			self:PlayAnimation(self.anim01)
		else
			self:placeAllThings()
		end
	end
end
