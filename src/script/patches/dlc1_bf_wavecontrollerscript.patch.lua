-- pex: countdead 39e5e3f5
-- pex: onactivate 0a34162d
-- OnActivate woke up to 8 linked statues, a random SpawnTimeMin..Max apart. CountDead, once enough
-- had died, waited to set the quest stage and again to wake the next wave. Now OnTick walks
-- both: `next_link` is the next statue to wake, `counting` the stage of the count's ending.
local rt = require('skymod.rt')

return function(C)
	C.Count = rt.sequence("Idle", "SettingStage", "NextWave")
	local S = C.Count
	C.__vars.spawning = rt.bool(false)
	C.__vars.next_link = rt.int(0)
	C.__vars.spawn_t = rt.timer(0.0)
	C.__vars.counting = S.Idle
	C.__vars.count_t = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.1)

	function C:OnActivate(akActionRef)
		if self.spawning then return end
		self.spawning = true
		self.next_link = 1
		self.spawn_t = 0.0
		self:OnTick()
	end

	function C:CountDead()
		self.CurrentDead = self.CurrentDead + 1
		if self.CurrentDead < self.MaxDead + self.AdditionalDeathsRequired - self.MinusDeathsRequired then return end
		if self.counting ~= S.Idle then return end
		self.counting = S.SettingStage
		self.count_t = self.DelayBeforeSettingStage
	end

	local function spawn_tick(self)
		if not self.spawning or self.spawn_t > 0 then return end
		while self.next_link <= 8 do
			local link = self:GetLinkedRef(self["LinkCustom0" .. self.next_link])
			self.next_link = self.next_link + 1
			if link then
				self:ActivateActors(link)
				self.spawn_t = self.spawn_t + rt.static("Utility", "RandomFloat", self.SpawnTimeMin, self.SpawnTimeMax)
				return
			end
		end
		self.spawning = false
	end

	local function count_tick(self)
		if self.counting == S.Idle or self.count_t > 0 then return end
		if self.counting == S.SettingStage then
			if self.myQuest then self.myQuest:SetStage(self.myQuestStage) end
			if not self:GetLinkedRef() then
				self.counting = S.Idle
				return
			end
			self.counting = S.NextWave
			self.count_t = self.count_t + self.DelayBeforeSpawningNextWave
			return
		end
		self.counting = S.Idle
		self:GetLinkedRef():Activate(self)
	end

	function C:OnTick()
		spawn_tick(self)
		count_tick(self)
	end
end
