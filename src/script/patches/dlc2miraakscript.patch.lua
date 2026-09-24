-- pex: delayedappear 7ae854c3
-- pex: onupdate b0b013de
-- pex: delayeddisappear 6d4c555b
-- pex: startmiraakfadeout 003cbc54
-- Three chained one-shot waits: DelayedAppear (2 s), then DelayedDisappear (0.5 s) into
-- StartMiraakFadeOut (0.3 s) into AfterMiraakFadeOut, which the S6 split already made a timer
-- field (kept as-is; not pinned here). Each function now starts its own timer and returns; the
-- class already has OnTick from that split, so ours calls it first, then checks the new timers.
local rt = require('skymod.rt')

return function(C)
	C.__vars.daT = rt.timer(0.0)
	C.__vars.daPending = rt.bool(false)
	C.__vars.ddT = rt.timer(0.0)
	C.__vars.ddPending = rt.bool(false)
	C.__vars.sfT = rt.timer(0.0)
	C.__vars.sfPending = rt.bool(false)

	function C:DelayedAppear()
		if self.SoulStealInternalState ~= 0 then return end -- a call while it waits is dropped
		rt.static("Debug", "Trace", tostring(self) .. "DelayedAppear()")
		self:setAlpha(0)
		if self.LastMoveToAppearAtRef and self.AppearAtRef then
			self:MoveTo(self.AppearAtRef, 200)
		end
		self:PlaceAtMe(self.DLC2MiraakTeleportExp)
		self.SoulStealInternalState = -1 -- before the wait, as Papyrus does
		self.daPending = true
		self.daT = 2.0
	end

	function C:OnUpdate()
		if self.SoulStealInternalState == 0 then
			self:DelayedAppear()
			self:CrossFadeOnUpdate()
		elseif self.SoulStealInternalState == 1 then
			self:DelayedDisappear()
		end
	end

	function C:DelayedDisappear()
		if self.ddPending then return end
		self:HandleReturnTeleportExplodeExp()
		self.DLC2MiraakTeleportReturnFXS:Play(self, -1.0)
		self.ddPending = true
		self.ddT = 0.5
	end

	function C:StartMiraakFadeOut()
		if self.sfPending then return end
		rt.static("ImageSpaceModifier", "RemoveCrossFade", 3.0)
		self:setAlpha(0.1, true)
		self.SoulStealInternalState = -1
		self.sfPending = true
		self.sfT = 0.3
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.daPending and self.daT <= 0 then
			self.daPending = false
			rt.static("Debug", "Trace", tostring(self) .. "DelayedAppear() - setAlpha (1, true)")
			self:setAlpha(1, true)
			self.DLC2MiraakTeleportStartFXS:Play(self, -1.0)
		end
		if self.ddPending and self.ddT <= 0 then
			self.ddPending = false
			self:StartMiraakFadeOut()
		end
		if self.sfPending and self.sfT <= 0 then
			self.sfPending = false
			self:AfterMiraakFadeOut()
		end
	end
end
