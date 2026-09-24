-- pex: onactivate 2b6c49f2
-- OnActivate opened the slot (2s anim), let Esbern in, then waited (2s, then poll 1s) for the
-- dialogue with him to end before closing the slot. A stage plus one timer now walks the same
-- steps in OnTick.
local rt = require('skymod.rt')

return function(C)
	C.Door = rt.sequence("Idle", "Opening", "Settling", "Dialogue", "Closing")
	C.__vars.door = C.Door.Idle
	C.__vars.doorT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.5)
	local S = C.Door

	function C:OnActivate(triggerRef)
		if self.door ~= S.Idle then return end -- a second start is dropped
		if triggerRef ~= rt.static("Game", "GetPlayer") then return end
		if self.MQ202:GetStageDone(150) then return end -- Papyrus compared to 0: not done yet

		self.door = S.Opening
		self.doorT = 2.0
		rt.cast(self.Esbern, "Actor"):StopCombat()
		rt.static("Game", "DisablePlayerControls",
			{ abMovement = false, abFighting = false, abCamSwitch = false, abLooking = false, abSneaking = true, abMenu = false, abActivate = false, abJournalTabs = false })
		self:PlayGamebryoAnimation("openSlot", true)
		self.Esbern:Activate(rt.static("Game", "GetPlayer"))
		rt.static("Game", "EnablePlayerControls",
			{ abMovement = false, abFighting = false, abCamSwitch = false, abLooking = false, abSneaking = true, abMenu = false, abActivate = false, abJournalTabs = false })
	end

	function C:OnTick()
		if self.door == S.Idle or self.doorT > 0 then return end
		if self.door == S.Opening then
			self.door = S.Dialogue -- the 2s settle and the 1s dialogue poll are the same test
		end
		if self.door == S.Dialogue then
			if rt.cast(self.Esbern, "Actor"):IsInDialogueWithPlayer() then
				self.doorT = 1.0
				return
			end
			self.door = S.Closing
		end
		if self.door == S.Closing then
			self.door = S.Idle
			self:PlayGamebryoAnimation("closeSlot", true)
		end
	end
end
