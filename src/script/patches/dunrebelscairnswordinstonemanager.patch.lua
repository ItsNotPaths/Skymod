-- pex: activatebox 2810704e
-- pex: activatesword e0c65af8
-- pex: active.onactivate 61e59741
-- ActivateBox's one Wait(0.5) before the rumble becomes a bool plus a timer. ActivateSword's
-- GetOpenState poll (0.25s) becomes the same shape. Active.OnActivate went Busy, ran one of the
-- two, then straight back to Active; now it stays Busy until whichever one it ran clears its own
-- busy flag, so a second activation stays dropped (the Busy state's OnActivate is already a no-op)
-- until the door work is actually done.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.05)
	C.__vars.boxBusy = rt.bool(false)
	C.__vars.boxT = rt.timer(0.0)
	C.__vars.swordBusy = rt.bool(false)
	C.__vars.doorPollT = rt.timer(0.0)
	local Active = rt.state(C, "active")
	local Busy = rt.state(C, "busy")

	function C:ActivateBox()
		local player = rt.static("Game", "GetPlayer")
		local hasSword = player:GetItemCount(self.RebelsCairnBaseSword) > 0
			or player:GetItemCount(self.RebelsCairnUpgradedSword) > 0
		if not hasSword then
			self.NoSwordMessage:Show()
			return
		end
		local state = self.secretDoor:GetOpenState()
		if state == 2 or state == 4 then return end
		if player:GetItemCount(self.RebelsCairnBaseSword) > 0 then
			player:RemoveItem(self.RebelsCairnBaseSword, 1, true)
			self.RebelsCairnInvisibleActivator:Disable()
			self.RebelsCairnBaseSwordActivator:Enable()
		else
			player:RemoveItem(self.RebelsCairnUpgradedSword, 1, true)
			self.RebelsCairnInvisibleActivator:Disable()
			self.RebelsCairnUpgradedSwordActivator:Enable()
		end
		self.dunRebelsCairnQST:SetStage(30)
		self.secretDoor:Activate(self)
		self.boxBusy = true
		self.boxT = 0.5
	end

	function C:ActivateSword(triggerRef)
		local state = self.secretDoor:GetOpenState()
		if state == 2 or state == 4 then return end
		local player = rt.static("Game", "GetPlayer")
		if triggerRef == self.RebelsCairnBaseSwordActivator then
			player:AddItem(self.RebelsCairnBaseSword, 1, false)
		else
			player:AddItem(self.RebelsCairnUpgradedSword, 1, false)
		end
		self.RebelsCairnInvisibleActivator:Enable()
		self.RebelsCairnBaseSwordActivator:Disable()
		self.RebelsCairnUpgradedSwordActivator:Disable()
		self.doorCollision:Enable()
		self.secretDoor:Activate(self)
		if self.glowOn then
			self.glowOn = false
			self.glowVFX:DisableNoWait(true)
		end
		self.swordBusy = true
		self.doorPollT = 0.0
	end

	function Active:OnActivate(triggerRef)
		self:GotoState("busy")
		if triggerRef == self.RebelsCairnInvisibleActivator then
			self:ActivateBox()
		else
			self:ActivateSword(triggerRef)
		end
	end

	function Busy:OnTick()
		if self.boxBusy and self.boxT <= 0 then
			self.boxBusy = false
			self.RebelsCairnInvisibleActivator:RampRumble(0.5, 0.25, 1600.0) -- RampRumble's Papyrus defaults; not a native, so not auto-filled
			self.rumbleSFX:Play(self.doorCollision)
		end
		if self.swordBusy and self.doorPollT <= 0 then
			local st = self.secretDoor:GetOpenState()
			if st == 2 or st == 4 then
				self.doorPollT = self.doorPollT + 0.25
			else
				self.doorCollision:Disable()
				self.swordBusy = false
			end
		end
		if not self.boxBusy and not self.swordBusy then
			self:GotoState("active")
		end
	end
end
