-- pex: onactivate 2efc4e88
-- Placing a part asked which container it filled; the pick set that container's flag, removed the
-- part, and checked whether all three were placed right (arming a 1 s wait already split into
-- this class's own OnTick). The event now asks; OnTick reads the pick and runs the same check.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	function C:OnActivate(triggerRef)
		if self.asking or self.vars["onactivate.t"] ~= rt.None then return end -- a call while it waits is dropped
		self.mainscript = rt.cast(self.controllerScript, "valthumeControllerScript")
		self.asking = true
		self.urnMessage:Show()
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if not self.asking then return end
		local button = self.urnMessage:Answer()
		if button < 0 then return self.urnMessage:Show() end
		self.asking = false
		local m = self.mainscript
		if self.ContainerEyes then
			m.eyesmain = (button == 3) and 2 or 1
		elseif self.ContainerHeart then
			m.heartmain = (button == 2) and 2 or 1
		elseif self.ContainerBrain then
			m.brainmain = (button == 1) and 2 or 1
		end
		self:removepart(button)
		if not self:playerPlacedAll() then return end
		if m.eyesmain == 2 and m.brainmain == 2 and m.heartmain == 2 then
			m.brainContainer:Disable(false)
			m.eyesContainer:Disable(false)
			m.heartContainer:Disable(false)
			m.containerFire1:Enable(false)
			m.containerFire2:Enable(false)
			m.containerFire3:Enable(false)
			m.puzzledoor:Activate(m.puzzledooractivator, false)
			self.vars["onactivate.t"] = 1.0
		elseif m.eyesmain ~= 0 or m.brainmain ~= 0 or m.heartmain ~= 0 then
			self:returnitems()
		end
	end
end
