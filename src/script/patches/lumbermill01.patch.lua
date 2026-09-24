-- pex: normal.onactivate fd211bfa
-- pex: sabotage.onactivate ec323c78
-- Activation started the mill and waited for the log's animation before damaging the log (and,
-- sabotaged, the sash). Now OnTick polls the log's animation; `log_anim` is the one running.
local rt = require('skymod.rt')

return function(C)
	C.__vars.log_anim = rt.string("")
	C.__vars.TickRate = rt.float(0.1)
	local Normal, Sabotage = rt.state(C, "Normal"), rt.state(C, "Sabotage")

	function Normal:OnActivate(triggerRef)
		if self.log_anim ~= "" then return end
		self:PlayAnimation("PullUp")
		self.Saw:PlayAnimation("activate")
		self.Sash:PlayAnimation("activate")
		self.Log:PlayAnimation("activate")
		self.log_anim = "activate"
	end

	function Sabotage:OnActivate(triggerRef)
		if self.log_anim ~= "" then return end
		self:PlayAnimation("FullPush")
		self.Saw:PlayAnimation("jam")
		self.Sash:PlayAnimation("jam")
		self.Log:PlayAnimation("jam")
		self.log_anim = "jam"
	end

	function C:OnTick()
		if self.log_anim == "" or self.Log:IsAnimRunning(self.log_anim) then return end
		local jammed = self.log_anim == "jam"
		self.log_anim = ""
		if jammed then
			self.Log:DamageObject(50.0)
			self.Sash:DamageObject(100.0)
		else
			self.Log:DamageObject(100.0)
		end
	end
end
