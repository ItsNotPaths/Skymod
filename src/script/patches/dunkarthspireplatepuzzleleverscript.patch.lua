-- pex: onactivate 043ae559
-- The lever solved the plate puzzle, pushed and waited for FullPushedUp before lighting the
-- flames. The event now lights them; `pushing` marks the one push.
local rt = require('skymod.rt')

return function(C)
	C.__vars.pushing = rt.bool(false)

	function C:OnActivate(trigRef)
		if trigRef ~= rt.static("Game", "GetPlayer") or self.doOnce then return end
		self.doOnce = true
		self.mainScript.plateSolved = true
		self.pushing = true
		self:RegisterForAnimationEvent(self, "FullPushedUp")
		self:PlayAnimation("FullPush")
	end

	function C:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "FullPushedUp" or not self.pushing then return end
		self.pushing = false
		for _, f in ipairs({ self.flameA, self.flameB, self.flameC, self.flameD, self.flameE }) do
			f:SetAnimationVariableFloat("fToggleBlend", 1)
		end
	end
end
