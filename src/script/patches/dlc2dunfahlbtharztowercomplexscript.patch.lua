-- pex: managebridges de52dcf1
-- pex: waiting.onactivate 9f58e78c
-- ManageBridges toggled a floor bool, played the mover's animation, waited `waitTimer` (floor 1
-- only; floor 2 has no wait), then released the pillar and set the tower markers. OnActivate goes
-- busy and calls it; the "waiting" handler stays hidden while busy, so a second activate is
-- already dropped by the state. `mb` carries the one wait; `Floor1`/`Floor2` are read back after
-- it since nothing else changes them meanwhile.
local rt = require('skymod.rt')

local MB = rt.sequence("Idle", "Waiting")

return function(C)
	C.__vars.mb = MB.Idle
	C.__vars.mbT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function markers_and_stop(self)
		local N, S, E, W = self.dlc2dunfahlbtharzcomplextowermarkern, self.dlc2dunfahlbtharzcomplextowermarkers,
			self.dlc2dunfahlbtharzcomplextowermarkere, self.dlc2dunfahlbtharzcomplextowermarkerw
		if self.Floor1 then
			if self.Floor2 then
				N:Disable(false) S:Enable(false) E:Enable(false) W:Disable(false)
			else
				N:Enable(false) S:Disable(false) E:Disable(false) W:Enable(false)
			end
		else
			if self.Floor2 then
				N:Enable(false) S:Disable(false) E:Enable(false) W:Disable(false)
			else
				N:Disable(false) S:Enable(false) E:Disable(false) W:Enable(false)
			end
		end
	end
	local function stop_and_wait(self)
		markers_and_stop(self)
		rt.static("Sound", "StopInstance", self.soundinstanceid)
		self.mb = MB.Idle
		self:GotoState("waiting")
	end

	function C:ManageBridges(floorNumber)
		if self.mb ~= MB.Idle then return end -- a run happens once
		self:GotoState("busy")
		self:doEffects()
		if floorNumber == 1 then
			self.Floor1 = not self.Floor1
			if self:GetLinkedRef(self.linkcustom04) then self:EnableLinkChain(self.linkcustom04) end
			if self.Floor1 then
				if self:GetLinkedRef(self.linkcustom01) then self:EnableLinkChain(self.linkcustom01) end
				if self:GetLinkedRef() then self:GetLinkedRef():PlayAnimation("Forward") end
			else
				if self:GetLinkedRef(self.linkcustom02) then self:EnableLinkChain(self.linkcustom02) end
				if self:GetLinkedRef() then self:GetLinkedRef():PlayAnimation("Backward") end
			end
			self.mb, self.mbT = MB.Waiting, self.waittimer
			return
		end
		if self.Floor2 then
			self.Floor2 = false
			if self:GetLinkedRef(self.traplink) then self:GetLinkedRef(self.traplink):PlayAnimation("Backward") end
		else
			self.Floor2 = true
			if self:GetLinkedRef(self.traplink) then self:GetLinkedRef(self.traplink):PlayAnimation("Forward") end
		end
		stop_and_wait(self)
	end

	local Waiting = rt.state(C, "waiting")
	function Waiting:OnActivate(akActivator)
		local tracker = rt.cast(akActivator, "dlc2defaulttrackingintscript")
		if tracker ~= rt.None then
			self:ManageBridges(tracker.trackingnumber)
		end
	end

	local Busy = rt.state(C, "busy")
	function Busy:OnTick()
		if self.mb ~= MB.Waiting or self.mbT > 0 then return end
		if self.objrotatingstonepillarrelease then
			self.objrotatingstonepillarrelease:Play(self:GetLinkedRef(self.linkcustom03))
		end
		if self.Floor1 then
			if self:GetLinkedRef(self.linkcustom02) then self:DisableLinkChain(self.linkcustom02, false) end
		else
			if self:GetLinkedRef(self.linkcustom01) then self:DisableLinkChain(self.linkcustom01, false) end
		end
		if self:GetLinkedRef(self.linkcustom04) then self:DisableLinkChain(self.linkcustom04, false) end
		stop_and_wait(self)
	end
end
