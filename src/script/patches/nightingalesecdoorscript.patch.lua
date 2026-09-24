-- pex: pulledposition.onactivate 122c1138
-- The door went busy and waited for "Opened" with nothing after, so it stays busy. Only the
-- animation is left to start.
local rt = require('skymod.rt')

return function(C)
	local Pulled = rt.state(C, "pulledPosition")

	function Pulled:OnActivate(triggerRef)
		self:GotoState("busy")
		self:PlayAnimation("Open")
	end
end
