-- pex: open.onactivate db232461
-- The QA button went waiting, played Trigger01 and waited for "done"; for the player it then
-- closed and teaches every word of power in WordList. The event now does that; `presser` is who pressed.
local rt = require('skymod.rt')

return function(C)
	C.__vars.presser = rt.form("ObjectReference")
	local Open, Waiting = rt.state(C, "open"), rt.state(C, "waiting")

	function Open:OnActivate(akActivator)
		self:GotoState("waiting")
		self.presser = akActivator
		self:RegisterForAnimationEvent(self, "done")
		self:PlayAnimation("Trigger01")
	end

	function Waiting:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "done" or not self.presser then return end
		local player = rt.static("Game", "GetPlayer")
		local presser = self.presser
		self.presser = rt.None
		if presser ~= player then return end -- stays waiting, as before
		self:PlayAnimation("Close")
		while self.currentIndex < self.formSize do
			local word = rt.cast(self.WordList:GetAt(self.currentIndex), "WordOfPower")
			rt.static("Game", "TeachWord", word)
			rt.static("Game", "UnlockWord", word)
			self.currentIndex = self.currentIndex + 1
		end
		self:GotoState("Close")
	end
end
