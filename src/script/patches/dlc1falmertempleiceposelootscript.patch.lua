-- pex: doublecheckactors 31a46472
-- pex: trytodoublecheckactors 5d08aacf
-- pex: onactivate 0e0703f0
-- pex: spawnactor 8e0548c3
-- pex: trytospawnactors 7227c6a5
-- Two independent walks over the 10 CreatureToSpawnNN/LinkCustomNN slots, each a chain of short
-- waits per slot: SpawnActor (first cell attach, via ReleaseToHavok) breaks each statue out one
-- after another; DoubleCheckActors (later attaches) re-settles whichever are still alive. Both are
-- synthetic states (this script has none of its own) used only to gate the tick.
local rt = require('skymod.rt')

local SLOTS = 10
local function suffix(i) return string.format("%02d", i) end
local function creatureAt(self, i) return rt.cast(self["CreatureToSpawn" .. suffix(i)], "actor") end
local function linkAt(self, i) return self:GetLinkedRef(self["LinkCustom" .. suffix(i)]) end

return function(C)
	-- SpawnActor / TryToSpawnActors / ReleaseToHavok / OnActivate (unit 26)
	local Spawn = rt.sequence("Idle", "Appearing", "Settling")
	C.__vars.spawn = Spawn.Idle
	C.__vars.spawnSlot = rt.int(0)
	C.__vars.spawnWait = rt.timer(0.0)
	C.__vars.activator = rt.form("ObjectReference") -- OnActivate's triggerRef, used once spawning ends
	C.__vars.TickRate = rt.float(0.05)
	local Spawning = rt.state(C, "Spawning")

	local function afterSpawns(self)
		self:GotoState("")
		self.spawn = Spawn.Idle
		self:BlockActivation(false) -- ReleaseToHavok's tail
		if self.activator then      -- OnActivate's tail
			self:Enable()
			self:BlockActivation(false)
			self.activator:AddItem(self)
			self.activator = rt.None
		end
	end

	local function spawnFrom(self, from)
		for i = from, SLOTS do
			if linkAt(self, i) then
				self.spawnSlot = i
				local c = creatureAt(self, i)
				c:EnableNoWait()
				c:SetAlpha(0)
				self.spawn = Spawn.Appearing
				self.spawnWait = 0.25
				return
			end
		end
		afterSpawns(self)
	end

	function Spawning:OnTick()
		if self.spawnWait > 0 then return end
		local i = self.spawnSlot
		if self.spawn == Spawn.Appearing then
			local akLink, c = linkAt(self, i), creatureAt(self, i)
			c:EnableAI(true)
			c:MoveTo(akLink)
			akLink:DamageObject(1000)
			if self.DLC1BFIceFormFXS then self.DLC1BFIceFormFXS:Play(c) end
			c:SetActorValue("Aggression", 2)
			c:StartCombat(rt.static("Game", "GetPlayer"))
			c:SetGhost(false)
			c:SetAlpha(1)
			self.spawn = Spawn.Settling
			self.spawnWait = self.spawnWait + rt.static("Utility", "RandomFloat", 0.0, 1.0)
		else
			spawnFrom(self, i + 1)
		end
	end

	function C:TryToSpawnActors()
		self:GotoState("Spawning")
		spawnFrom(self, 1)
	end

	function C:ReleaseToHavok()
		if self:GetLinkedRef() then self:GetLinkedRef():Disable() end
		self.beensimmed = true
		if self:Is3DLoaded() then
			self:SetMotionType(self.Motion_Dynamic, true)
			self:ApplyHavokImpulse(0.0, 0.0, 1.0, 5.0)
		end
		self:TryToSpawnActors() -- the rest runs in afterSpawns
	end

	function C:OnActivate(triggerRef)
		if self.beensimmed then return end -- also drops a second activation while spawning
		self:Disable()
		if self:GetLinkedRef() then
			self.activator = triggerRef
			self:ReleaseToHavok()
			return
		end
		self:Enable()
		self:BlockActivation(false)
		triggerRef:AddItem(self)
	end

	-- DoubleCheckActors / TryToDoubleCheckActors (unit 25)
	local Check = rt.sequence("Idle", "WaitEnable", "WaitAlpha")
	C.__vars.checkStage = Check.Idle
	C.__vars.checkSlot = rt.int(0)
	C.__vars.checkT = rt.timer(0.0)
	local Checking = rt.state(C, "Checking")

	local function checkFrom(self, from)
		for i = from, SLOTS do
			local c = creatureAt(self, i)
			if c ~= rt.None and not c:IsDead() then
				self.checkSlot = i
				c:SetActorValue("Aggression", 0)
				c:EnableAI(true)
				self.checkStage = Check.WaitEnable
				self.checkT = 0.15
				return
			end
		end
		self.checkStage = Check.Idle
		self:GotoState("")
	end

	function Checking:OnTick()
		if self.checkT > 0 then return end
		local i = self.checkSlot
		local c = creatureAt(self, i)
		if self.checkStage == Check.WaitEnable then
			c:SetAlpha(0)
			c:MoveTo(linkAt(self, i))
			self.checkStage = Check.WaitAlpha
			self.checkT = 0.15
			return
		end
		if self.checkStage == Check.WaitAlpha then
			c:EnableAI(false)
			if self.DLC1BFIceFormFXS then self.DLC1BFIceFormFXS:Stop(c) end
			c:SetActorValue("Aggression", 0)
			checkFrom(self, i + 1)
		end
	end

	function C:TryToDoubleCheckActors()
		if self.checkStage ~= Check.Idle then return end -- a second start is dropped
		self:GotoState("Checking")
		checkFrom(self, 1)
	end
end
