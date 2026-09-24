-- pex: onstart bd75fd2e
-- OnStart enabled the critter and waited for its 3D (0.1 s polls, 10 at most, then deleted it) before
-- starting its update loop. Now OnTick in Waiting3D polls; `wait_left` is the time left.
local rt = require('skymod.rt')

return function(C)
	C.__vars.wait_left = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting3D")
	local limited = true

	function C:OnStart()
		self.iPlantTypeCount = self.PlantTypes:GetSize()
		self:SetScale(rt.static("Utility", "RandomFloat", self.fMinScale, self.fMaxScale))
		if rt.static("Game", "GetPlayer"):GetDistance(self) > self.fMaxPlayerDistance then return self:DisableAndDelete() end
		self:WarpToNewPlant()
		self:Enable()
		self.wait_left = 1.0
		self:GotoState("Waiting3D")
		self:OnTick()
	end

	function Waiting:OnTick()
		if self:Is3DLoaded() then
			self:GotoState("")
			self:SetMotionType(self.Motion_Keyframed, false)
			return self:RegisterForSingleUpdate(0.0)
		end
		if limited and self.wait_left <= 0 then
			self:GotoState("")
			self:DisableAndDelete(false)
		end
	end
end
