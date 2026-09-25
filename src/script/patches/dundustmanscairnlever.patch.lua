-- pex: pulledposition.onactivate 30f2ccce
-- The first lever waited for the Vampire Lord's ShiftBack, then both levers played FullPush and
-- waited for FullPushedUp before going to done, with triggerLock held throughout. The lever now
-- waits in busy (which ignores activation, as triggerLock did): OnTick for the shift back's `back`
-- run, then OnAnimationEvent for the push.
local rt = require('skymod.rt')

return function(C)
	C.Pull = rt.sequence("Idle", "ShiftingBack", "Pushing")
	local P = C.Pull
	C.__vars.pull = P.Idle
	C.__vars.TickRate = rt.float(0.1)
	local Pulled, Busy = rt.state(C, "pulledPosition"), rt.state(C, "busy")

	local function activate_self(self)
		self:BlockActivation(false)
		self:Activate(self, true)
		self:BlockActivation()
	end

	function Pulled:OnActivate(triggerRef)
		if self.triggerLock then return end
		if self.C01CompanionTriggerBox:GetTriggerObjectCount() ~= 0 then return end
		self.triggerLock = true
		self.pull = P.ShiftingBack
		self:GotoState("busy")
		if not self.secondLever then
			self.myCollBox:SetMotionType(4)
			self.myCollBox:MoveTo(self.dunDustmansCairnTrapScenePrimMarker)
			self.myCollBox2:SetMotionType(4)
			self.myCollBox2:MoveTo(self.dunDustmansCairnTrapScenePrim2Marker)
			activate_self(self)
			rt.static("Game", "DisablePlayerControls", { abMovement = false, abFighting = true, abCamSwitch = false,
				abLooking = false, abSneaking = false, abMenu = false, abActivate = false, abJournalTabs = false, aiDisablePOVType = 0 })
			if self.DLC1PlayerVampireQuest:IsRunning() then
				rt.cast(self.DLC1PlayerVampireQuest, "DLC1PlayerVampireChangeScript"):ShiftBack()
			end
		else
			rt.static("Game", "EnablePlayerControls")
			self.myCollBox:MoveTo(self.dunDustmansCairnLeverCollMarker)
			self.myCollBox2:MoveTo(self.dunDustmansCairnLeverCollMarker)
			self.myCollBox:DisableNoWait(true)
			self.myCollBox2:DisableNoWait(true)
			activate_self(self)
		end
		self:OnTick()
	end

	function Busy:OnTick()
		if self.pull ~= P.ShiftingBack then return end
		-- only the first lever calls ShiftBack; the second never waits on the shared quest's back field
		if not self.secondLever and rt.cast(self.DLC1PlayerVampireQuest, "DLC1PlayerVampireChangeScript").back.name ~= "Idle" then return end
		self.pull = P.Pushing
		self:RegisterForAnimationEvent(self, "FullPushedUp")
		self:PlayAnimation("FullPush")
	end

	function Busy:OnAnimationEvent(akSource, asEventName)
		if self.pull ~= P.Pushing or akSource ~= self or asEventName ~= "FullPushedUp" then return end
		self.pull = P.Idle
		self:GotoState("done")
		self.triggerLock = false
	end
end
