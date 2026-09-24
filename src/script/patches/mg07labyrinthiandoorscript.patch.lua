-- pex: waiting.onactivate 169bcd35
-- With the keystone, the door took it, played Insert, waited for "Done" and delayAfterInsert, then
-- hid itself and opened the real door for the player. Now the event starts a timer and OnTick in
-- inactive finishes; `opener` is who inserted the stone.
local rt = require('skymod.rt')

return function(C)
	C.__vars.opener = rt.form("ObjectReference")
	C.__vars.open_t = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Inactive = rt.state(C, "waiting"), rt.state(C, "inactive")

	function Waiting:OnActivate(actronaut)
		local player = rt.static("Game", "GetPlayer")
		if actronaut ~= player or not self.MG07:GetStageDone(10) or player:GetItemCount(self.MG07Keystone) < 1 then
			return self.dunLabyrinthianDenialMSG:Show()
		end
		self:GotoState("inactive")
		player:RemoveItem(self.MG07Keystone, player:GetItemCount(self.MG07Keystone))
		self.opener = actronaut
		self:RegisterForAnimationEvent(self, "Done")
		self:PlayAnimation("Insert")
	end

	function Inactive:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Done" or not self.opener or self.open_t ~= rt.None then return end
		self.open_t = self.delayAfterInsert
	end

	function Inactive:OnTick()
		if self.open_t == rt.None or self.open_t > 0 then return end
		self.open_t = rt.None
		self:Disable()
		self.myDoor:Activate(self.opener)
		self.opener = rt.None
	end
end
