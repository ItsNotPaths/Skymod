-- pex: closegate f9d60885
-- CloseGate waited 1.5s, then closed the gate. The wait is now a timer; OnTick finishes it and
-- clears `closing`, the fact dunustenpuztrigscript.patch.lua waits on before it settles.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.closing = rt.bool(false)
	C.__vars.closeT = rt.timer(0.0)

	function C:CloseGate()
		if self.closing then return end -- a second start is dropped
		self.closing = true
		self.closeT = 1.5
	end

	function C:OnTick()
		if not self.closing or self.closeT > 0 then return end
		self.closing = false
		local myLink = self:GetLinkedRef()
		myLink:Enable()
		self:PlayAnimation("close")
		if self.resetsshoutonclose then
			rt.static("Game", "GetPlayer"):SetVoiceRecoveryTime(0.0)
		end
		self.isopen = false
	end
end
