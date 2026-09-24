-- pex: waitingtobeopened.onactivate c95d5f96
-- OnActivate freed each present prisoner in turn, waiting 0.25 s between the faction removal and
-- the package re-evaluation. A step index plus a timer now walk the same list.
local rt = require('skymod.rt')

-- Explicit [N] keys: this Lua fork is 0-based for positional { a, b } literals, and this list is
-- walked by a 1-based pdIdx field.
local PRISONERS = { [1] = "Prisoner01", [2] = "Prisoner02", [3] = "Prisoner03", [4] = "Prisoner04",
	[5] = "Prisoner05", [6] = "Prisoner06", [7] = "PrisonerLink" }

return function(C)
	C.__vars.pdIdx = rt.int(0) -- 0 idle, else 1-based index into PRISONERS
	C.__vars.pdT = rt.timer(0.0)
	C.__vars.pdRemoved = rt.bool(false)
	local Waiting = rt.state(C, "WaitingToBeOpened")

	local function advance(self)
		while PRISONERS[self.pdIdx] do
			local p = self[PRISONERS[self.pdIdx]]
			if not p then
				self.pdIdx = self.pdIdx + 1
			elseif not self.pdRemoved then
				rt.cast(p, "Actor"):RemoveFromFaction(self.dunPrisonerFaction)
				self.pdRemoved = true
				self.pdT = self.pdT + 0.25
				return
			else
				if self.pdT > 0 then return end
				rt.cast(p, "Actor"):EvaluatePackage()
				self.pdRemoved = false
				self.pdIdx = self.pdIdx + 1
			end
		end
		self.pdIdx = 0
		self:GotoState("AlreadyOpened")
	end

	function Waiting:OnActivate(triggerRef)
		if self.pdIdx > 0 then return end -- a second start is dropped
		self.pdIdx = 1
		self.pdRemoved = false
		self.pdT = 0.0 -- fresh run: pdT idles until the door is activated
		advance(self)
	end

	function Waiting:OnTick() advance(self) end
end
