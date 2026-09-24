-- pex: destroy c67279d8
-- pex: normal.onactivate 8a66b0c9
-- pex: saw 981b882b
-- Destroy and Saw waited for the log's animation before the damage; the caller then left busy.
-- Now OnTick in busy polls the log's animation; `sawing_to` is the state the run ends in.
local rt = require('skymod.rt')

return function(C)
	C.__vars.sawing_to = rt.string("")
	C.__vars.TickRate = rt.float(0.1)
	local Normal, Busy = rt.state(C, "normal"), rt.state(C, "busy")

	local function anim(self) return self.sawing_to == "destroyed" and "jam" or "activate" end

	function C:Destroy()
		self:PlayAnimation("jam")
		self.Sash:PlayAnimation("jam")
		self.Log:PlayAnimation("jam")
		self.sawing_to = "destroyed"
	end

	function C:Saw()
		self:PlayAnimation("activate")
		self.Sash:PlayAnimation("activate")
		self.Log:PlayAnimation("activate")
		self.sawing_to = "normal"
	end

	function Normal:OnActivate(triggerRef)
		if triggerRef == rt.static("Game", "GetPlayer") then
			if self.SabatogeMessage:Show() ~= 1 then return end
			self:GotoState("busy")
			self:Destroy()
		else
			self:GotoState("busy")
			self:Saw()
		end
	end

	function Busy:OnTick()
		if self.sawing_to == "" or self.Log:IsAnimRunning(anim(self)) then return end
		local to = self.sawing_to
		self.sawing_to = ""
		if to == "destroyed" then
			self.Log:DamageObject(50.0)
			self.Sash:DamageObject(100.0)
		else
			self.Log:DamageObject(100.0)
			self:Repair() -- for now, just reset so the sabotage can still work
		end
		self:GotoState(to)
	end
end
