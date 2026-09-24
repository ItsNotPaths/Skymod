-- pex: workresource a3f25bdc
-- WorkResource played the cut and waited for the reset with nothing after; only the play stays.
local rt = require('skymod.rt')

return function(C)
	function C:WorkResource() self:PlayAnimation("MillLogChuteCut") end
end
