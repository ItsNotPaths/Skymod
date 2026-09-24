-- pex: fragment_36 8b0e7a8b
-- Mercer's death waited for TG08BQuestScript.VampLock, then 0.5 s after the shockwave it raised
-- the water. The run is `f36`, stepped by OnTick next to the split fragment's tick.
local rt = require('skymod.rt')

return function(C)
	C.F36 = rt.sequence("Idle", "Locking", "Shockwave")
	local F = C.F36
	C.__vars.f36, C.__vars.f36_t = F.Idle, rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local split_tick = C.__fn.ontick

	local function kmyQuest(self) return rt.cast(self, "TG08BQuestScript") end

	function C:Fragment_36()
		if self.f36 ~= F.Idle then return end
		self.f36 = F.Locking
		kmyQuest(self):VampLock()
		self:OnTick()
	end

	local function f36_tick(self)
		local q = kmyQuest(self)
		if self.f36 == F.Locking then
			if q.locking then return end
			self.f36 = F.Shockwave
			self.f36_t = 0.5
			self:SetObjectiveCompleted(40, true)
			self:SetObjectiveDisplayed(45, true)
			self.Alias_MercerAlias:GetReference():PlaceAtMe(q.TG08BShockwaveExplosion)
		elseif self.f36 == F.Shockwave and self.f36_t <= 0 then
			self.f36 = F.Idle
			q.pTG08BRisingWaterRef:Activate(q.pTG08BRisingWaterRef)
			q.pTG08BFloodScene01:Start()
			q.pTG08BBrynjolfIsCharmed = false
		end
	end

	function C:OnTick()
		split_tick(self)
		f36_tick(self)
	end
end
