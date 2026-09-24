-- pex: playergoesblind f049d081 8d2d3619
-- pex: playerreadsscroll 9c724233 9ea5ff8e
-- pex: playreadanimation 55261fda d8838207
-- PlayReadAnimation raised the scroll idle, then (when reading) a gap and a rest per part.
-- PlayerReadsScroll chained three parts, a 15 s vision, a white-out and a clear. PlayerGoesBlind
-- raised once, shook the camera, and held blind. Three stage fields (one per function) plus one
-- stopwatch for the animation part and one for the outer steps.
local rt = require('skymod.rt')

local function trace(msg) rt.static("Debug", "Trace", "ReadingTrigger " .. msg) end
local function player() return rt.static("Game", "GetPlayer") end

local Anim = rt.sequence("Idle", "Raising", "Gap", "Rest")
local Read = rt.sequence("Idle", "Part1", "Pause1", "Part2", "Pause2", "Part3", "Pause3", "Vision", "White", "Clearing")
local Blind = rt.sequence("Idle", "Raising", "Shaking", "Blind")

local part_after = { Part1 = "Pause1", Part2 = "Pause2", Part3 = "Pause3" }
local part_next = { Pause1 = "Part2", Pause2 = "Part3" }

-- the gap between the read sound and the scroll art; readScrollStepper 1 waits 2 s, 2 and 3 wait 1 s
local function gap_of(stepper) return stepper == 1 and 2.0 or 1.0 end

return function(C)
	C.__vars.anim = Anim.Idle
	C.__vars.read = Read.Idle
	C.__vars.blind = Blind.Idle
	C.__vars.animClock = rt.stopwatch(0.0)
	C.__vars.stepClock = rt.stopwatch(0.0)
	C.__vars.TickRate = rt.float(0.05)

	local function busy(self)
		return self.anim ~= Anim.Idle or self.read ~= Read.Idle or self.blind ~= Blind.Idle
	end

	-- after the idle has raised the scroll (or at once when seated)
	local function raised(self)
		local pa, stepper = player(), self.readscrollstepper
		if stepper == 0 then
			self.fxreadelderscrolleffect:Play(pa, 8.1, rt.None)
			self:playSound(1)
			self.anim = Anim.Idle
			return
		end
		if stepper == 1 then
			self.soundinstance3 = self.qstdlc01elderscrollread2d:Play(pa)
			self.soundinstance4 = self.qstdlc01elderscrollread2dlpm:Play(pa)
			self.soundinstance5 = self.qstdlc01elderscrollfinalread2dlpm:Play(pa)
			self.fxreadelderscrolleffect:Play(pa, 8.1, rt.None)
			self.dlc1readelderscrollblankeffect:Play(pa, -1.0, rt.None)
		else
			self.qstdlc01elderscrollreadb2d:Play(pa)
		end
		self.anim = Anim.Gap
		self.animClock = 0.0
	end

	function C:PlayReadAnimation()
		local pa = player()
		trace("part, stepper " .. self.readscrollstepper)
		if pa:GetSitState() ~= 0 then return raised(self) end
		pa:EquipItem(self.elderscrollhandattacharmor, false, true)
		pa:PlayIdle(self.idlereadelderscroll)
		self.anim = Anim.Raising
		self.animClock = 0.0
	end

	local function tick_anim(self)
		local pa, t = player(), self.animClock
		if self.anim == Anim.Raising then
			if t < 1.05 then return end
			raised(self)
		elseif self.anim == Anim.Gap then
			local gap = gap_of(self.readscrollstepper)
			if t < gap then return end
			local effect = ({ [1] = "dlc1readelderscrollpartbeffect", [2] = "dlc1readelderscrollpartceffect",
				[3] = "dlc1readelderscrollpartaeffect" })[self.readscrollstepper]
			self[effect]:Play(pa, -1.0, rt.None)
			self.anim = Anim.Rest
			self.animClock = t - gap
		elseif self.anim == Anim.Rest then
			local rest = self.readsteptimer - gap_of(self.readscrollstepper)
			if t < rest then return end
			pa:RemoveItem(self.elderscrollhandattacharmor, 1, true, rt.None)
			self.readscrollstepper = (self.readscrollstepper + 1) % 4
			self.anim = Anim.Idle
		end
	end

	local function enter(self, field, seq, name)
		self[field] = seq[name]
		self.stepClock = 0.0
		trace(field .. " " .. name)
	end

	local function waited(self, secs)
		if self.stepClock < secs then return false end
		self.stepClock = self.stepClock - secs
		return true
	end

	function C:PlayerReadsScroll(WhichScroll, OpenScroll)
		if WhichScroll ~= 1 or busy(self) then return end
		self:PrepForReading(true)
		self.readscrollstepper = 1
		enter(self, "read", Read, "Part1")
		self:PlayReadAnimation()
	end

	local function tick_read(self)
		local name, pa = self.read.name, player()
		if part_after[name] then
			if self.anim ~= Anim.Idle then return end
			enter(self, "read", Read, part_after[name])
		elseif part_next[name] then
			if not waited(self, self.readsteptimer) then return end
			enter(self, "read", Read, part_next[name])
			self:PlayReadAnimation()
		elseif name == "Pause3" then
			if not waited(self, self.readsteptimer) then return end
			enter(self, "read", Read, "Vision")
			self.qstdlc01elderscrollread2dheavy:Play(pa)
			self.dlc1readelderscrolleffect:Play(pa, -1.0, rt.None)
		elseif name == "Vision" then
			if not waited(self, 15.0) then return end
			enter(self, "read", Read, "White")
			rt.static("Game", "ShakeController", 0.5, 0.5, 1.5)
			self.fadetowhiteholdimod:ApplyCrossFade(1.0)
		elseif name == "White" then
			if not waited(self, 1.0) then return end
			enter(self, "read", Read, "Clearing")
			for _, fx in ipairs({ "dlc1readelderscrollpartaeffect", "dlc1readelderscrollpartbeffect",
				"dlc1readelderscrollpartceffect", "dlc1readelderscrolleffect", "dlc1readelderscrollblankeffect",
				"fxreadelderscrolleffect" }) do
				self[fx]:Stop(pa)
			end
			rt.static("Sound", "StopInstance", self.soundinstance4)
			rt.static("Sound", "StopInstance", self.soundinstance5)
		elseif name == "Clearing" then
			if not waited(self, 3.0) then return end
			self.read = Read.Idle
			trace("read done")
			rt.static("ImageSpaceModifier", "RemoveCrossFade", 5.0)
			self:ReturnFromReading(false, true)
			self.dlc1vq06:SetStage(70)
		end
	end

	function C:PlayerGoesBlind()
		if busy(self) then return end
		self:PrepForReading(false)
		enter(self, "blind", Blind, "Raising")
		self:PlayReadAnimation()
	end

	local function tick_blind(self)
		local name = self.blind.name
		if name == "Raising" then
			if self.anim ~= Anim.Idle then return end
			enter(self, "blind", Blind, "Shaking")
		elseif name == "Shaking" then
			if not waited(self, 0.5) then return end
			enter(self, "blind", Blind, "Blind")
			rt.static("Game", "ShakeCamera", rt.None, 0.5, 1.5)
			self.fxreadelderscrolleffect:Play(player(), 8.1, rt.None)
			self.fxreadscrollsblindimod:Apply(1.0)
		elseif name == "Blind" then
			if not waited(self, 4.9) then return end
			self.blind = Blind.Idle
			trace("blind done")
			self:ReturnFromReading(true, true)
			self:playSound(2)
		end
	end

	function C:OnTick()
		if not busy(self) then return end
		if self.anim ~= Anim.Idle then tick_anim(self) end
		tick_read(self)
		tick_blind(self)
	end
end
