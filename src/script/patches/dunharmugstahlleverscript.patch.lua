-- pex: checkallopen e02934cf
-- pex: onactivate 0b53ec48
-- pex: oncellload ecbde285
-- pex: opendoor01 c26fbe3c
-- pex: opendoorpatterna aedf3342
-- pex: opendoorpatternb a3e893ae
-- pex: opendoorpatternc d6218005
-- pex: opendoorpatternd 4d3a852e
-- A lever toggled its pattern of doors one after another (door 1 after 0.1 s), with the levers
-- blocked, then checked for all open. OnCellLoad closed the four doors one after another. Now
-- `run` and `door_at` (the pattern's door being moved) are stepped by OnTick in Running, which
-- waits while that door is animating. checkAllOpen needs no change: it only opens doors that are
-- all open already, which returns at once.
local rt = require('skymod.rt')

return function(C)
	C.Run = rt.sequence("Idle", "Delay", "Toggling", "Closing")
	local R = C.Run
	C.__vars.run = R.Idle
	C.__vars.pattern = rt.string("")
	C.__vars.door_at = rt.int(0)
	C.__vars.delay = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)
	local Running = rt.state(C, "Running")
	local patterns = { lever01 = { 1, 2 }, lever02 = { 1, 2, 3 }, lever03 = { 2, 3, 4 }, lever04 = { 3, 4 } }
	local all_doors = { 1, 2, 3, 4 }

	local function door(self, n) return rt.cast(self["door0" .. n], "default2StateActivator") end
	local function levers(self, block) for n = 1, 4 do self["lever0" .. n]:BlockActivation(block) end end
	local function doors_of(self) return self.run == R.Closing and all_doors or patterns[self.pattern] end

	local function move(self)
		local n = doors_of(self)[self.door_at]
		local d = door(self, n)
		if self.run == R.Closing then d:SetOpen(false) else d:SetOpen(not d.isOpen) end
	end

	-- door_at's door is done: start the next, or end the run
	local function next_door(self)
		self.door_at = self.door_at + 1
		if self.door_at < #doors_of(self) then return move(self) end
		local was = self.run
		self.run = R.Idle
		self:GotoState("")
		if was ~= R.Closing then
			levers(self, false)
			self:checkAllOpen()
		end
	end

	function C:openDoor01()
		self.run = R.Delay
		self.delay = 0.1
	end

	function C:OnActivate(TriggerRef)
		if self.isComplete then return end
		for name, _ in pairs(patterns) do
			if TriggerRef == self[name] then
				if self.run ~= R.Idle then return end
				self.pattern = name
				self.door_at = 0
				levers(self, true)
				self:GotoState("Running")
				if patterns[name][0] == 1 then return self:openDoor01() end
				self.run = R.Toggling
				return move(self)
			end
		end
		if TriggerRef == self.startTrigger then self:puzStart() end
	end

	function C:OnCellLoad()
		for n = 1, 4 do self["door0" .. n .. "Script"] = self["door0" .. n] end
		if self.run ~= R.Idle then return end
		self.run = R.Closing
		self.door_at = 0
		self:GotoState("Running")
		move(self)
	end

	function Running:OnTick()
		if self.run == R.Delay then
			if self.delay > 0 then return end
			self.run = R.Toggling
			return move(self)
		end
		if self.run == R.Idle then return self:GotoState("") end
		local n = doors_of(self)[self.door_at]
		if door(self, n).isAnimating then return end
		next_door(self)
	end
end
