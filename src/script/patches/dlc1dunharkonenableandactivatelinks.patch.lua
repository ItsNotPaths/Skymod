-- pex: onactivate f88cecd6
-- OnActivate walked its own link (GetLinkedRef()) then LinkCustom01..10, waiting a random 0-0.5s
-- and firing Enable+Activate for each link that exists and is not dead, skipping the rest at once.
-- The link index is a fact about which link is next (script-api.md "a loop index over data"), not
-- a resume step. Re-activating while a run is under way is dropped.
local rt = require('skymod.rt')

return function(C)
	local IDX_MAX = 10

	local function link_target(self, i)
		if i == 0 then return self:GetLinkedRef() end
		return self:GetLinkedRef(self["linkcustom" .. string.format("%02d", i)])
	end

	C.__vars.TickRate = rt.float(0.1)
	C.__vars.actObj = rt.form("ObjectReference")
	C.__vars.actIdx = rt.int(0)
	C.__vars.actWaiting = rt.bool(false)
	C.__vars.actT = rt.timer(0.0)
	local Running = rt.state(C, "Running")

	function C:OnActivate(obj)
		if self:GetState() == "Running" then return end -- a second activation is dropped
		self.actObj = obj
		self.actIdx = 0
		self.actWaiting = false
		self:GotoState("Running")
		self:OnTick() -- Papyrus checked the first link at once
	end

	function Running:OnTick()
		if self.actWaiting then
			if self.actT > 0 then return end
			self.actWaiting = false
			local target = link_target(self, self.actIdx)
			if target ~= rt.None then
				target:Enable()
				target:Activate(self.actObj)
			end
			self.actIdx = self.actIdx + 1
		end
		while self.actIdx <= IDX_MAX do
			local target = link_target(self, self.actIdx)
			if target ~= rt.None and not rt.cast(target, "Actor"):IsDead() then
				self.actT = rt.static("Utility", "RandomFloat", 0.0, 0.5)
				self.actWaiting = true
				return
			end
			self.actIdx = self.actIdx + 1
		end
		self:GotoState("")
	end
end
