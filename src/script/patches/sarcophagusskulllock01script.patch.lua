-- pex: readytotake.onactivate 713efca9
-- pex: waitingforkey.onactivate 59ecd905
-- pex: unlocked.onanimationevent 71e1e8ca
-- Every animation here ends in "Done", so one handler serves the insert, the unlock run and the
-- removal; `slot` tells them apart. `armed` is the old RegisterForAnimationEvent(self, "Done"):
-- only an armed slot runs the unlock, with its 1 s and 2 s pauses as a stopwatch.
local rt = require('skymod.rt')

local Slot = rt.sequence("Idle", "Inserting", "Inserted", "Pause1", "Unlocking", "Pause2", "Releasing", "Removing", "Done")
local function player() return rt.static("Game", "GetPlayer") end

return function(C)
	C.__vars.slot = Slot.Idle
	C.__vars.armed = rt.bool(false)
	C.__vars.slotClock = rt.stopwatch(0.0)
	C.__vars.TickRate = rt.float(0.1)

	local function go(self, stage) self.slot, self.slotClock = stage, 0.0 end

	local function insert(self, key, item)
		-- GotoState runs OnBeginState, which may start UnlockSequence on both slots (as in Papyrus)
		self:GotoState("unlocked")
		if not self.myQuest:GetStageDone(self.stageSetOnFirstActivate) then
			self.myQuest:SetStage(self.stageSetOnFirstActivate)
		end
		player():RemoveItem(key)
		self.itemThatUnlockedMe = item
		go(self, Slot.Inserting)
		self:PlayAnimation("Insert")
	end

	local Waiting = rt.state(C, "WaitingForKey")
	function Waiting:OnActivate(who)
		if player():GetItemCount(self.myKey01) == 1 then
			insert(self, self.myKey01, 1)
		elseif player():GetItemCount(self.myKey02) == 1 then
			insert(self, self.myKey02, 2)
		else
			if not self.myQuest:GetStageDone(self.stageSetOnFirstActivate) then
				self.myQuest:SetStage(self.stageSetOnFirstActivate)
			end
			self.emptySlotMessage:Show()
		end
	end

	function C:UnlockSequence()
		if self.lastUnlocked then
			rt.cast(self.myPartnerSlot, "sarcophagusskulllock01script"):UnlockSequence()
		end
		self.armed = true
		self:PlayAnimation("Unlock")
	end

	local Unlocked = rt.state(C, "Unlocked")
	function Unlocked:OnAnimationEvent(src, name)
		if src ~= self or name ~= "Done" then return end
		if self.slot == Slot.Inserting then
			-- the tail of OnActivate; its wait on the lock's Unlock01 was its last line
			go(self, Slot.Inserted)
			self.myLock:PlayAnimation("Unlock01")
			if not self.armed then return end
		end
		if self.armed and self.slot == Slot.Inserted then
			go(self, Slot.Pause1)
		elseif self.slot == Slot.Unlocking then
			self.myLock:PlayAnimation("Unlock02")
			if self.lastUnlocked then self.myQuest:SetStage(self.stageSetOnUnlock) end
			go(self, Slot.Pause2)
		elseif self.slot == Slot.Releasing then
			self.armed = false
			go(self, Slot.Done)
			self:GotoState("ReadyToTake")
		end
		-- a "Done" during Pause1/Pause2 started a second parallel run in Papyrus; it is dropped
	end

	function Unlocked:OnTick()
		if self.slot == Slot.Pause1 and self.slotClock >= 1.0 then
			self.slotClock = self.slotClock - 1.0
			self.slot = Slot.Unlocking
			self:PlayAnimation("Unlock")
		elseif self.slot == Slot.Pause2 and self.slotClock >= 2.0 then
			self.slot = Slot.Releasing
			self:PlayAnimation("Release")
		end
	end

	local Ready = rt.state(C, "ReadyToTake")
	function Ready:OnActivate(who)
		if self.slot == Slot.Removing then return end
		if self.itemThatUnlockedMe == 1 or self.itemThatUnlockedMe == 2 then
			go(self, Slot.Removing)
			self:PlayAnimation("Remove")
		end
	end

	function Ready:OnAnimationEvent(src, name)
		if src ~= self or name ~= "Done" or self.slot ~= Slot.Removing then return end
		local key = self.itemThatUnlockedMe == 1 and self.myKey01 or self.myKey02
		player():AddItem(key:GetBaseObject())
		go(self, Slot.Done)
		self:GotoState("AllDone")
		self.itemThatUnlockedMe = 0
	end
end
