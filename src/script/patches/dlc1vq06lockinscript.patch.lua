-- pex: ontriggerenter 97bfdc3f
-- OnTriggerEnter locked Serana in once DismissFollower (2 s) returned. It now waits in state
-- "LockingIn" until dfScript leaves "Dismissing", so LockIn's follower count is not cleared after.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	local LockingIn = rt.state(C, "LockingIn")

	function C:OnTriggerEnter(akActivator)
		if self:GetState() == "LockingIn" then return end
		local player = rt.static("Game", "GetPlayer")
		if akActivator ~= player or self.DLC1VQ06:GetStage() ~= 10 then return end
		self.Serana:GetReference():MoveTo(player)
		local follower = self.dfScript.pFollowerAlias:GetActorReference()
		self:GotoState("LockingIn")
		if self.dfScript.pPlayerFollowerCount:GetValueInt() > 0 and follower and follower ~= self.Serana:GetActorReference() then
			self.dfScript:DismissFollower()
		end
		self:OnTick()
	end

	function LockingIn:OnTick()
		if self.dfScript:GetState() == "Dismissing" then return end
		self:GotoState("")
		self.MM:LockIn()
		self.MM:SetHomeMarker(self.VampireLine:GetValueInt() ~= 0 and 2 or 1)
		self:Delete()
	end
end
