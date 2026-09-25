-- pex: openportal 62177c39
-- OpenPortal busy-waited on its own state, then a 1 s wait before the rest of the opening.
-- The busy loop is now a drop-while-busy guard; the 1 s wait is a timer read in OnTick, which
-- keeps calling the class's already-split OnTick (closeportal.t) first.
local rt = require('skymod.rt')

return function(C)
	C.__vars.openT = rt.timer(rt.None)
	C.__vars.quickOpen = rt.bool(false)
	C.__vars.TickRate = rt.float(0.1)

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OpenPortal(triggerRef, abOpen, abQuickOpen)
		if self:GetState() == "busy" then return end -- dropped, not queued: Papyrus's own call also gets stuck busy here
		self:GotoState("busy")
		if abOpen and (not self.isOpen or abQuickOpen) then
			self.myStaff:Enable()
			if triggerRef == player() then player():RemoveItem(self.MQ303DragonPriestStaff, 1) end
			self.QSTSovengardePortalOpenRef:Enable()
			self.quickOpen = abQuickOpen
			self.openT = 1.0
		elseif not abOpen and self.isOpen then
			self.myStaff:Disable()
			if triggerRef == player() then player():AddItem(self.MQ303DragonPriestStaff, 1) end
			self:RegisterForAnimationEvent(self.seal, "done") -- ClosePortal (converted) finishes the close
		elseif not abOpen and not self.isOpen and abQuickOpen then
			self:GotoState("waiting")
		end
		-- else: none of the three matched, Papyrus itself leaves state "busy" forever here too
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.openT == rt.None or self.openT > 0 then return end
		self.openT = rt.None
		self.QSTSovengardePortalOn2DLPMREF:Enable()
		self.QSTSovengardePortalFarLPMREF:Enable()
		self.QSTSovengardePortalOnMonoLPMREF:Enable()
		self:PlayAnimation("PlayAnim02")
		if self.quickOpen then self.seal:PlayAnimation("StartOpen") else self.seal:PlayAnimation("Open") end
		self.myLight:Enable()
		self.myDoor:Enable()
		self.isOpen = true
		self:GotoState("waiting")
	end
end
