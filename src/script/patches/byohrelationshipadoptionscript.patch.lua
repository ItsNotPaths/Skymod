-- pex: dirtymovefamily 0e796505
-- pex: movefamily ae763481
-- pex: playerlocationchanged 0555d8bd
-- MoveFamily and DirtyMoveFamily each polled the Scheduler quest with Utility.Wait(0.5), then
-- retried SetStage(0) up to 10 times the same way. Both waits are now stages walked by OnTick in
-- one shared "Moving" state; each keeps its own stage field, so the two runs never block one
-- another. PlayerLocationChanged's welcome-home half used to run right after MoveFamily returned;
-- it now waits for the move to finish and keeps the two locations in fields.
local rt = require('skymod.rt')

local Move = rt.sequence("Idle", "Stopping", "Starting", "Retrying")
local Dirty = rt.sequence("Idle", "AwaitStop", "Starting", "Retrying")

local function T(s) rt.static("Debug", "Trace", "adoption: " .. s) end
local function player() return rt.static("Game", "GetPlayer") end

return function(C)
	C.__vars.move = Move.Idle
	C.__vars.moveClock = rt.timer(0.0)
	C.__vars.moveFailCount = rt.int(0)
	C.__vars.dirtyMove = Dirty.Idle
	C.__vars.dirtyClock = rt.timer(0.0)
	C.__vars.dirtyFailCount = rt.int(0)
	C.__vars.welcomePending = rt.bool(false)
	C.__vars.welcomeNewLoc = rt.form("Location")
	C.__vars.welcomeOldLoc = rt.form("Location")
	C.__vars.TickRate = rt.float(0.1)

	local function away(actor) return actor:GetCurrentLocation() ~= player():GetCurrentLocation() end

	-- the two "move everyone" passes MoveFamily makes differ only in which EvaluatePackage calls run
	local function moveEveryone(self, first)
		local home = self.newHomeRef
		local spouse = self.Spouse:GetActorRef()
		if spouse ~= rt.None and not spouse:IsDead() then
			if not (spouse:IsInFaction(self.CurrentFollowerFaction) or not away(spouse)) then spouse:MoveTo(home) end
			if first then
				spouse:EvaluatePackage()
				self.AllowSpouseToMove = true
				rt.cast(self.RelationshipMarriageFIN, "relationshipmarriagespousehousescript"):MoveSpouseAdoption(spouse, self.newHome)
				self.AllowSpouseToMove = false
			end
		end
		local c1, c2 = self.Child1:GetActorRef(), self.Child2:GetActorRef()
		if away(c1) then
			c1:MoveTo(home)
			if first then c1:EvaluatePackage() end
		end
		if c2 ~= rt.None and away(c2) then
			c2:MoveTo(home)
			if first then c2:EvaluatePackage() end
		end
		local pet, critter = self.FamilyPet:GetActorRef(), self.FamilyCritter:GetActorRef()
		if pet ~= rt.None and not pet:IsInFaction(self.CurrentFollowerFaction) and not pet:Is3DLoaded() then
			pet:MoveTo(home)
			pet:EvaluatePackage()
		end
		if critter ~= rt.None then
			critter:MoveTo(home)
			critter:EvaluatePackage()
		end
	end

	local function settle(self, child)
		self.OrderToConfirm = 1.0
		self:IssueOrderWithDuration(child, 1)
	end

	-- both runs' tail: newly-adopted children get a Forcegreet and sandbox at home
	local function forcegreet(self, c1, c2)
		local new1, new2 = self.child1NewlyAdopted, self.child2NewlyAdopted
		if not (new1 or new2) then return end
		self:ReadyForcegreetEvent()
		self.child1NewlyAdopted, self.child2NewlyAdopted = false, false
		if new1 then settle(self, c1) end
		if new2 then settle(self, c2) end
	end

	local function welcomeHome(self, newLoc, oldLoc)
		local house, ext = self.CurrentHomeHouse:GetLocation(), self.CurrentHomeExterior:GetLocation()
		if (newLoc == house or newLoc == ext) and oldLoc ~= house and oldLoc ~= ext then
			if rt.static("Utility", "GetCurrentGameTime") - self.playerLastSeen > self.WelcomeHomeDelay then
				if self.GiftStoredValueChild1 > 0 then
					self.Child1:GetActorRef():AddItem(self.Gold001, self.GiftStoredValueChild1)
					self.GiftStoredValueChild1 = 0
				end
				if self.GiftStoredValueChild2 > 0 then
					self.Child2:GetActorRef():AddItem(self.Gold001, self.GiftStoredValueChild2)
					self.GiftStoredValueChild2 = 0
				end
				self:ReadyForcegreetEvent()
			end
			self.playerLastSeen = rt.static("Utility", "GetCurrentGameTime")
		end
	end

	-- leave the shared ticking state once neither run is under way; release PlayerLocationChanged's
	-- deferred welcome-home check
	local function exitIfDone(self)
		if self.move ~= Move.Idle or self.dirtyMove ~= Dirty.Idle then return end
		self:GotoState("")
		if self.welcomePending then
			self.welcomePending = false
			welcomeHome(self, self.welcomeNewLoc, self.welcomeOldLoc)
		end
	end

	local function succeed(self)
		self.CurrentHomeHouse:ForceLocationTo(self.SchedulerCurrentHomeHouse:GetLocation())
		self.CurrentHomeExterior:ForceLocationTo(self.SchedulerCurrentHomeExterior:GetLocation())
		local c1, c2 = self.Child1:GetActorRef(), self.Child2:GetActorRef()
		c1:SetActorValue("Variable06", 0)
		if c2 ~= rt.None then c2:SetActorValue("Variable06", 0) end
		self.MovingTogglePackageOn = false
		for _, a in ipairs({ self.Spouse, self.Child1, self.Child2, self.FamilyPet, self.FamilyCritter }) do
			local r = a:GetActorRef()
			if r ~= rt.None then r:EvaluatePackage() end
		end
		if not self.initialMoveDone then
			self.initialMoveDone = true
			rt.cast(self.BYOHRelationshipAdoptionScheduler, "byohrelationshipadoptionsc"):OnUpdateGameTime()
		end
		self.moveQueued = false
		self.currentHome = self.newHome
		self.schedulerHasFailed = false
		forcegreet(self, c1, c2)
		T("move completed, home " .. tostring(self.currentHome))
		self.move = Move.Idle
		exitIfDone(self)
	end

	local function fail(self)
		T("THE ADOPTION SCHEDULER HAS FAILED TO START (before: " .. tostring(self.schedulerHasFailed) .. ")")
		if not self.schedulerHasFailed then
			self.schedulerHasFailed = true
			self:QueueMoveFamily(self.currentHome, true)
			self.move = Move.Idle
			exitIfDone(self)
			self:MoveFamily() -- a fresh run back to the old home
		else
			self:QueueMoveFamily(-1, false)
			self.move = Move.Idle
			exitIfDone(self)
		end
	end

	local function dirtySucceed(self)
		local spouse = self.Spouse:GetActorRef()
		if spouse ~= rt.None and not spouse:IsDead() then
			self.AllowSpouseToMove = true
			rt.cast(self.RelationshipMarriageFIN, "relationshipmarriagespousehousescript"):MoveSpouseAdoption(spouse, self.newHome)
			self.AllowSpouseToMove = false
		end
		self.CurrentHomeHouse:ForceLocationTo(self.SchedulerCurrentHomeHouse:GetLocation())
		self.CurrentHomeExterior:ForceLocationTo(self.SchedulerCurrentHomeExterior:GetLocation())
		local c1, c2 = self.Child1:GetActorRef(), self.Child2:GetActorRef()
		c1:SetActorValue("Variable06", 0)
		if c2 ~= rt.None then c2:SetActorValue("Variable06", 0) end
		self.MovingTogglePackageOn = false
		for _, a in ipairs({ self.Spouse, self.Child1, self.Child2, self.FamilyPet }) do
			local r = a:GetActorRef()
			if r ~= rt.None then r:EvaluatePackage() end
		end
		self.currentHome = self.newHome
		self.schedulerHasFailed = false
		forcegreet(self, c1, c2)
		T("dirty move completed, home " .. tostring(self.currentHome))
		self.dirtyMove = Dirty.Idle
		exitIfDone(self)
	end

	local function dirtyFail(self)
		T("DIRTY: THE ADOPTION SCHEDULER HAS FAILED TO START (before: " .. tostring(self.schedulerHasFailed) .. ")")
		if not self.schedulerHasFailed then
			self.schedulerHasFailed = true
			self:QueueMoveFamily(self.currentHome, true)
			self.dirtyMove = Dirty.Idle
			exitIfDone(self)
			self:MoveFamily() -- the Papyrus original hands off to MoveFamily here, not to itself
		else
			self:QueueMoveFamily(-1, false)
			self.dirtyMove = Dirty.Idle
			exitIfDone(self)
		end
	end

	function C:MoveFamily()
		if self.move ~= Move.Idle then
			T("MoveFamily dropped: a move is under way")
			return
		end
		self.MovingTogglePackageOn = true
		if self.BYOHRelationshipAdoptionNewAdoptionHandler:IsRunning() then
			self.BYOHRelationshipAdoptionNewAdoptionHandler:Stop()
		end
		self:QuashCritterEvents()
		moveEveryone(self, true)
		self.BYOHRelationshipAdoptionScheduler:Stop()
		self:GotoState("Moving")
		self.move = Move.Stopping
		self:OnTick() -- the poll checked at once, as the while did
	end

	function C:DirtyMoveFamily()
		if self.dirtyMove ~= Dirty.Idle then
			T("DirtyMoveFamily dropped: a dirty move is under way")
			return
		end
		self.MovingTogglePackageOn = true
		local spouse = self.Spouse:GetActorRef()
		if spouse ~= rt.None then spouse:EvaluatePackage() end
		self.Child1:GetActorRef():EvaluatePackage()
		local c2 = self.Child2:GetActorRef()
		if c2 ~= rt.None then c2:EvaluatePackage() end
		local pet = self.FamilyPet:GetActorRef()
		if pet ~= rt.None then pet:EvaluatePackage() end
		if self.BYOHRelationshipAdoptionNewAdoptionHandler:IsRunning() then
			self.BYOHRelationshipAdoptionNewAdoptionHandler:Stop()
		end
		self.BYOHRelationshipAdoptionScheduler:Stop()
		self:GotoState("Moving")
		self.dirtyMove = Dirty.AwaitStop
		self:OnTick()
	end

	local Moving = rt.state(C, "Moving")
	function Moving:OnTick()
		local sched = self.BYOHRelationshipAdoptionScheduler

		if self.moveClock <= 0 and self.move ~= Move.Idle then
			if self.move == Move.Stopping then
				if sched:IsRunning() then
					self.moveClock = 0.5
				else
					moveEveryone(self, false)
					self.moveFailCount = 0
					sched:SetStage(0)
					self.move = Move.Starting
				end
			elseif self.move == Move.Retrying then
				self.Child1:GetActorRef():MoveTo(self.newHomeRef)
				sched:SetStage(0)
				self.move = Move.Starting
			end
			if self.move == Move.Starting then
				if not sched:IsRunning() and self.moveFailCount < 10 then
					self.moveFailCount = self.moveFailCount + 1
					self.moveClock = 0.5
					self.move = Move.Retrying
				elseif not sched:IsRunning() then
					fail(self)
				else
					succeed(self)
				end
			end
		end

		if self.dirtyClock <= 0 and self.dirtyMove ~= Dirty.Idle then
			if self.dirtyMove == Dirty.AwaitStop then
				if sched:IsRunning() then
					self.dirtyClock = 0.5
				else
					local c1, c2 = self.Child1:GetActorRef(), self.Child2:GetActorRef()
					if c1:GetCurrentLocation() ~= self:TranslateHouseIntToInteriorLoc(self.newHome) then
						if c2 == rt.None then c1:MoveTo(self.newHomeRef) else self:SwapChildren() end
					end
					self.dirtyFailCount = 0
					sched:SetStage(0)
					self.dirtyMove = Dirty.Starting
				end
			elseif self.dirtyMove == Dirty.Retrying then
				sched:SetStage(0)
				self.dirtyMove = Dirty.Starting
			end
			if self.dirtyMove == Dirty.Starting then
				if not sched:IsRunning() and self.dirtyFailCount < 10 then
					self.dirtyFailCount = self.dirtyFailCount + 1
					self.dirtyClock = 0.5
					self.dirtyMove = Dirty.Retrying
				elseif not sched:IsRunning() then
					dirtyFail(self)
				else
					dirtySucceed(self)
				end
			end
		end
	end

	-- Converted body up to the move; the welcome-home half runs now, or after the move it started.
	function C:PlayerLocationChanged(newLoc, oldLoc)
		local cwHandler, cw = self.BYOHRelationshipAdoptionCWSiegeHandler, self.CWSiege
		local ext = self.CurrentHomeExterior:GetLocation()
		if not cwHandler:IsRunning() and cw:IsRunning() and cw:GetStage() > 0 and ext ~= rt.None
			and self.CWSiegeCity:GetLocation() == ext then
			cwHandler:SetStage(0)
		end
		if cwHandler:IsRunning() and not cw:IsRunning() then cwHandler:Stop() end

		if self.moveQueued and self:FamilyAwayFrom(newLoc, oldLoc) then
			local wasIdle = self.move == Move.Idle
			self:MoveFamily()
			if wasIdle and self.move ~= Move.Idle then
				self.welcomePending, self.welcomeNewLoc, self.welcomeOldLoc = true, newLoc, oldLoc
				T("PlayerLocationChanged: welcome-home check waits for the move")
				return
			end
		end
		welcomeHome(self, newLoc, oldLoc)
	end

	-- the three nested tests PlayerLocationChanged makes before it moves the family
	function C:FamilyAwayFrom(newLoc, oldLoc)
		local c1, c2, sp = self.Child1:GetActorRef(), self.Child2:GetActorRef(), self.Spouse:GetActorRef()
		local spouseFree = sp == rt.None or sp:IsInFaction(self.CurrentFollowerFaction)
		local function each(test)
			return test(c1) and (spouseFree or test(sp)) and (c2 == rt.None or test(c2))
		end
		if not each(function(a) return newLoc ~= a:GetCurrentLocation() end) then return false end
		if not each(function(a) return not a:GetCurrentLocation():IsChild(newLoc) end) then return false end
		return (newLoc == self:TranslateHouseIntToLoc(self.newHome) and not newLoc:IsChild(oldLoc))
			or each(function(a) return not newLoc:IsChild(a:GetCurrentLocation()) end)
	end
end
