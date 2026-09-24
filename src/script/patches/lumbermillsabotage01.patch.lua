-- pex: sabotage.onactivate 6bcedef4
-- Sabotage jammed the mill and waited for the log's jam animation before damaging log and sash.
-- Now OnTick polls the log's animation; `jamming` is set while it runs.
local rt = require('skymod.rt')

return function(C)
	C.__vars.jamming = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)
	local Sabotage = rt.state(C, "Sabotage")

	function Sabotage:OnActivate(triggerRef)
		if self.jamming then return end
		self:PlayAnimation("jam")
		self.Sash:PlayAnimation("jam")
		self.Log:PlayAnimation("jam")
		self.jamming = true
	end

	function C:OnTick()
		if not self.jamming or self.Log:IsAnimRunning("jam") then return end
		self.jamming = false
		self.Log:DamageObject(50.0)
		self.Sash:DamageObject(100.0)
	end
end
