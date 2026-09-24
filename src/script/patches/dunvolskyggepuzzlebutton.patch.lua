-- pex: waiting.onactivate f3a071f5
-- A press checked the sequence, pulled the button and waited for "Reset". A right press then, if
-- it was the last, locked every button and opened the doors 1 s later; a wrong one reset the
-- lights and fired the next failure. Now "Reset" continues it; `correct` says which press it was.
local rt = require('skymod.rt')

return function(C)
	C.__vars.correct = rt.bool(false)
	C.__vars.doors = rt.timer(rt.None)
	C.__vars.TickRate = rt.float(0.1)
	local Waiting, Busy, Done = rt.state(C, "waiting"), rt.state(C, "busy"), rt.state(C, "done")

	local function unlight(self, button)
		if button.myEnableMarker:IsEnabled() then
			self.myLinkedRef.myFailSound:Play(button.mySoundMarker)
			button.myEnableMarker:DisableNoWait(1)
		end
	end

	function Waiting:OnActivate(triggerRef)
		self:GotoState("busy")
		local control = self.myLinkedRef
		self.correct = self.buttonNumber - control.numPuzzleButtonsSolved == 1
		if self.correct then
			control.numPuzzleButtonsSolved = control.numPuzzleButtonsSolved + 1
			control.mySuccessSound:Play(self.mySoundMarker)
			self.myEnableMarker:EnableNoWait(1)
		else
			control.puzzleSolved = false
			control.numPuzzleButtonsSolved = 0
			for i = 1, 3 do unlight(self, self["myButton0" .. i]) end
		end
		self:RegisterForAnimationEvent(self, "Reset")
		self:PlayAnimation("Pull")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if akSource ~= self or asEventName ~= "Reset" then return end
		local control = self.myLinkedRef
		if self.correct then
			if control.numPuzzleButtonsSolved == control.numOfPuzzleButtons then
				self:GotoState("done")
				for i = 1, 3 do self["myButton0" .. i]:GotoState("done") end
				control.puzzleSolved = true
				control.myLightMarker:EnableNoWait(1)
				control.mySuccessSound:Play(control.mySoundMarker01)
				self.doors = 1.0
			end
		else
			if self.myEnableMarker:IsEnabled() then
				control.myFailSound:Play(self.mySoundMarker)
				self.myEnableMarker:DisableNoWait(1)
			else
				control.myFailSoundNoLight:Play(self.mySoundMarker)
			end
			local n = control.refActOnFailureCounter
			if n <= 3 then
				control["refActOnFailure0" .. (n + 1)]:Activate(control)
				control.refActOnFailureCounter = n + 1
			end
		end
		if not control.puzzleSolved then self:GotoState("waiting") end
	end

	function Done:OnTick()
		if self.doors == rt.None or self.doors > 0 then return end
		self.doors = rt.None
		local control = self.myLinkedRef
		control.myDoor01:SetOpen(true)
		control.myDoor02:SetOpen(true)
		control.myMusicMarker:Enable()
	end
end
