-- pex: unlocked.onbeginstate 67abc57c
-- Unlocked.OnBeginState waited 3 s then, only if the other half-claw keyhole was already Unlocked,
-- a further 0.5 s before opening both doors. A stage plus a timer now walk the same two waits.
local rt = require('skymod.rt')

return function(C)
	C.HC = rt.sequence("Idle", "Wait1", "Wait2")
	C.__vars.hcStage = C.HC.Idle
	C.__vars.hcSecondKey = rt.bool(false)
	C.__vars.hcT = rt.timer(0.0)
	local Unlocked = rt.state(C, "Unlocked")

	function Unlocked:OnBeginState()
		local other = rt.cast(self:GetLinkedRef(self.LinkCustom03), "dlc2sv01halfclawkeyholescript")
		self.hcSecondKey = other and other:GetState() == "Unlocked"
		if self.hcSecondKey then self.MyQuest:SetStage(self.StagetoSetOnSecondKey) end
		self.hcStage = C.HC.Wait1
		self.hcT = 3.0 -- fresh wait: hcT idles between GotoState("Unlocked") calls
	end

	function Unlocked:OnTick()
		if self.hcStage == C.HC.Idle or self.hcT > 0 then return end
		if self.hcStage == C.HC.Wait1 then
			self:GetLinkedRef(self.LinkCustom04):EnableNoWait(1)
			if not self.hcSecondKey then
				self.hcStage = C.HC.Idle
				return
			end
			self.hcStage = C.HC.Wait2
			self.hcT = self.hcT + 0.5
			return
		end
		self:GetLinkedRef(self.LinkCustom01):Activate(self)
		self:GetLinkedRef(self.LinkCustom02):Activate(self)
		self.hcStage = C.HC.Idle
	end
end
