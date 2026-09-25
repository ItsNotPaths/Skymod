-- pex: onstart 4e73b42e
-- OnStart enabled the critter and waited for its 3D (0.1 s polls, no timeout) before
-- starting its update loop. Now OnTick in Waiting3D polls.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting = rt.state(C, "Waiting3D")

	function C:OnStart()
		self:SetScale(rt.static("Utility", "RandomFloat", self.fMinScale, self.fMaxScale))
		if rt.static("Game", "GetPlayer"):GetDistance(self) > self.fMaxPlayerDistance then return self:DisableAndDelete() end
		self:WarpToNewPlant()
		self:Enable()
		self:GotoState("Waiting3D")
		self:OnTick()
	end

	function Waiting:OnTick()
		if self:Is3DLoaded() then
			self:GotoState("")
			self:SetMotionType(self.Motion_Keyframed, false)
			return self:RegisterForSingleUpdate(0.0)
		end
	end
end
