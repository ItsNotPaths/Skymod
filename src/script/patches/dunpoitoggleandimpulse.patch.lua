-- pex: waiting.oncontainerchanged 49b0303f
-- pex: toggleandimpulse e94d7e70
-- ToggleAndImpulse recursed down a chain of linked refs, toggling each at once; on the way back
-- out, a ref that had been disabled waited 0.01s (for Enable to take physical effect) then got an
-- impulse. The chain is now walked once into parallel arrays (toggling each at once, as before),
-- then unwound by OnTick from the deepest link outward. OnContainerChanged waits for the unwind
-- to finish before its GotoState("inactive"), which Papyrus reached only once the recursion
-- returned.
local rt = require('skymod.rt')

local SLOTS = 32 -- linked-ref chain depth; this POI's chains run a handful deep

return function(C)
	local IDLE = -1
	C.__vars.toggleObj = rt.array_of("ObjectReference")
	C.__vars.toggleWasDisabled = rt.array_of("Bool")
	C.__vars.toggleIdx = rt.int(IDLE) -- the chain link currently unwinding
	C.__vars.toggleT = rt.timer(0.0)
	C.__vars.gotoInactiveAfterToggle = rt.bool(false)
	C.__vars.priorState = rt.string("") -- restored once the unwind finishes, unless heading to "inactive"
	local Waiting = rt.state(C, "waiting")
	local Unwinding = rt.state(C, "unwinding") -- OnTick only while a chain is actually unwinding

	local function make_slots(self)
		if self.toggleObj then return end
		self.toggleObj = rt.array(SLOTS, "ObjectReference")
		self.toggleWasDisabled = rt.array(SLOTS, "Bool")
	end

	function C:ToggleAndImpulse(obj)
		if self.toggleIdx ~= IDLE then return end -- a second start during a run is dropped
		make_slots(self)
		local n = 0
		while obj and n < SLOTS do
			local wasDisabled = obj:IsDisabled()
			self.toggleObj[n] = obj
			self.toggleWasDisabled[n] = wasDisabled
			if wasDisabled then obj:Enable() else obj:Disable() end
			n = n + 1
			obj = obj:GetLinkedRef()
		end
		self.toggleIdx = n - 1
		self.toggleT = (n > 0 and self.toggleWasDisabled[n - 1]) and 0.01 or 0.0
		self.priorState = self:GetState()
		self:GotoState("unwinding")
		self:OnTick()
	end

	function Unwinding:OnTick()
		while self.toggleIdx >= 0 and self.toggleT <= 0 do
			local i = self.toggleIdx
			if self.toggleWasDisabled[i] then
				self.toggleObj[i]:ApplyHavokImpulse(0, 0, 1, 1)
			end
			self.toggleIdx = i - 1
			self.toggleT = (self.toggleIdx >= 0 and self.toggleWasDisabled[self.toggleIdx]) and 0.01 or 0.0
		end
		if self.toggleIdx < 0 then
			if self.gotoInactiveAfterToggle then
				self.gotoInactiveAfterToggle = false
				self:GotoState("inactive")
			else
				self:GotoState(self.priorState)
			end
		end
	end

	function Waiting:OnContainerChanged(akNewContainer, akOldContainer)
		self.gotoInactiveAfterToggle = true
		self:ToggleAndImpulse(self.ObjectToToggle)
	end
end
