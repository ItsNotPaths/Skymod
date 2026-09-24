-- pex: open.onactivate 75784a85
-- The QA button went waiting, played Trigger01 and waited for "done", then asked which NPC to
-- spawn. The event now asks; the message box pauses the world as before.
local rt = require('skymod.rt')

return function(C)
	local Open, Waiting = rt.state(C, "open"), rt.state(C, "waiting")

	function Open:OnActivate(akActivator)
		self:GotoState("waiting")
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("Trigger01")
	end

	function Waiting:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" then return end
		local choice = self.NPCOptions:Show()
		self.SpawnLocation:PlaceAtMe(self.NPCList:GetAt(choice))
		self:GotoState("Open")
	end
end
