-- pex: onload 7a098835
-- OnLoad placed the FX, waited 1.5s, then spawned scrap or enabled AI, and (if isMishapDead)
-- waited 1 more second before killing itself. One timer plus a stage covers both waits.
local rt = require('skymod.rt')

return function(C)
	C.Stage = rt.sequence("Idle", "Placed", "WaitDead", "Done")
	C.__vars.stage = C.Stage.Idle
	C.__vars.t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function finish(self)
		self.stage = C.Stage.Done
		rt.static("Game", "GetPlayer"):RemoveFromFaction(self.dlc1ld_aetherialstaffbusyfaction)
	end

	function C:OnLoad()
		if self.stage ~= C.Stage.Idle then return end -- a second start is dropped
		self:PlaceAtMe(self.summonvalortargetfxactivator)
		self.stage = C.Stage.Placed
		self.t = 1.5
	end

	function C:OnTick()
		if self.stage == C.Stage.Placed then
			if self.t > 0 then return end
			if self.ismishapscrap then
				local list = self.dlc1ld_aetherialstaffscraplist
				local junk = rt.static("Utility", "RandomInt", 4, 7)
				while junk > 0 do
					local idx = rt.static("Utility", "RandomInt", 0, list:GetSize() - 1)
					local scrap = self:PlaceAtMe(list:GetAt(idx))
					scrap:ApplyHavokImpulse(rt.static("Utility", "RandomFloat", -1.0, 1.0),
						rt.static("Utility", "RandomFloat", -1.0, 1.0), 1, rt.static("Utility", "RandomFloat", 5, 25))
					junk = junk - 1
				end
				self:Disable()
				self:Delete()
			else
				self:EnableAI(true)
				self:SetAlpha(1, true)
			end
			if self.ismishapdead then
				self.stage = C.Stage.WaitDead
				self.t = self.t + 1.0
				return
			end
			return finish(self)
		end
		if self.stage == C.Stage.WaitDead then
			if self.t > 0 then return end
			self:Kill()
			finish(self)
		end
	end
end
