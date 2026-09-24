-- pex: activatebox 733307f4
-- pex: activatesword 95eb5fca
-- pex: ready.onactivate b52f53e1
-- ActivateBox waited 0.5 s before its banish tail; Ready.OnActivate waited 2 s after either
-- ActivateBox or ActivateSword before returning to Ready, so it must now wait for ActivateBox's
-- own tail when it took that branch. ActivateSword itself has no direct wait: its four Summon()
-- calls are now non-blocking, which loses their ~1 s stagger but nothing after them reads
-- summoned/enabled state, so it needs no change.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.boxBusy = rt.bool(false)
	C.__vars.abPending = rt.bool(false)
	C.__vars.abT = rt.timer(0.0)
	C.__vars.rdyPending = rt.bool(false)
	C.__vars.rdyAwaitBox = rt.bool(false)
	C.__vars.rdyT = rt.timer(0.0)
	local Ready = rt.state(C, "Ready")

	function C:ActivateBox()
		self.boxBusy = true
		local player = rt.static("Game", "GetPlayer")
		if player:GetItemCount(self.PaleBladeList) == 0 then
			self.NoSwordMessage:Show()
			self.boxBusy = false
			return
		end
		if player:GetItemCount(self.PaleBlade01) > 0 then player:RemoveItem(self.PaleBlade01, 1, true); self.PaleBladeCount = 1
		elseif player:GetItemCount(self.PaleBlade02) > 0 then player:RemoveItem(self.PaleBlade02, 1, true); self.PaleBladeCount = 2
		elseif player:GetItemCount(self.PaleBlade03) > 0 then player:RemoveItem(self.PaleBlade03, 1, true); self.PaleBladeCount = 3
		elseif player:GetItemCount(self.PaleBlade04) > 0 then player:RemoveItem(self.PaleBlade04, 1, true); self.PaleBladeCount = 4
		elseif player:GetItemCount(self.PaleBlade05) > 0 then player:RemoveItem(self.PaleBlade05, 1, true); self.PaleBladeCount = 5
		end
		self.InvisibleActivator:Disable()
		self.SwordActivator:Enable()
		self.abPending = true
		self.abT = 0.5 -- fresh wait: ActivateBox is an external entry point
	end

	function C:OnTick()
		if self.abPending and self.abT <= 0 then
			self.abPending = false
			self.SwordVFXShader:Play(self.SwordActivator, -1.0)
			if not rt.cast(self.PaleLady, "Actor"):IsDead() then
				self.InvisibleActivator:RampRumble(0.25, 1, 1600)
				rt.static("Game", "ShakeCamera")
				self.rumbleSound:Play(self)
				self.dunFrostmereCryptQST:SetStage(self.FrostmereStageToSetOnBanish)
				self.dunFrostmereBanishToggleQST:SetStage(self.ToggleStageToSetOnBanish)
				rt.cast(self.PaleLady, "Actor"):SetAv("Variable06", 1)
				rt.cast(self.PaleLady, "Actor"):EvaluatePackage()
				rt.cast(self.PaleLady, "dunfrostmerecryptfakesummon"):Banish()
				rt.cast(self.Wisp01, "dunfrostmerecryptfakesummon"):Banish()
				rt.cast(self.Wisp02, "dunfrostmerecryptfakesummon"):Banish()
				rt.cast(self.Wisp03, "dunfrostmerecryptfakesummon"):Banish()
				self.PaleLadyFurniture:Disable()
			end
			self.boxBusy = false
			if self.rdyAwaitBox then
				self.rdyAwaitBox = false
				self.rdyPending = true
				self.rdyT = 2.0 -- fresh wait: rdyT idles between Ready activations
			end
		end
		if self.rdyPending and self.rdyT <= 0 then
			self.rdyPending = false
			self:GotoState("Ready")
		end
	end

	function Ready:OnActivate(triggerRef)
		self:GotoState("Busy")
		if triggerRef == self.InvisibleActivator then
			self:ActivateBox()
			if self.boxBusy then
				self.rdyAwaitBox = true
				return
			end
		else
			self:ActivateSword(triggerRef)
		end
		self.rdyPending = true
		self.rdyT = 2.0 -- fresh wait: rdyT idles between Ready activations
	end
end
