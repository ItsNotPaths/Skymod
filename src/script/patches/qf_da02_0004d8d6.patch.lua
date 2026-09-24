-- pex: fragment_11 821cfb50
-- Fragment_11 stopped DA02BoethiahScene2 and polled Scene.IsPlaying() every second until it
-- stopped, then resurrected the conduit. Now the poll is an OnTick guard.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(1.0)
	C.__vars.frag11_stopping = rt.bool(false)

	local function finish(self, kmyQuest)
		kmyQuest:resurrectCounduit(rt.None)
		self.alias_boethiahsconduit:GetActorReference():EvaluatePackage()
		if self:GetStageDone(15) then self:SetObjectiveCompleted(15) end
		self:SetObjectiveDisplayed(101)
	end

	function C:Fragment_11()
		if self.frag11_stopping then return end -- a second start while stopping is dropped
		local kmyQuest = rt.cast(self, "da02script")
		kmyQuest.stage = 17
		if kmyQuest.da02boethiahscene2:IsPlaying() then
			kmyQuest.da02boethiahscene2:Stop()
			self.frag11_stopping = true
			return
		end
		finish(self, kmyQuest)
	end

	function C:OnTick()
		if not self.frag11_stopping then return end
		local kmyQuest = rt.cast(self, "da02script")
		if kmyQuest.da02boethiahscene2:IsPlaying() then return end
		self.frag11_stopping = false
		finish(self, kmyQuest)
	end
end
