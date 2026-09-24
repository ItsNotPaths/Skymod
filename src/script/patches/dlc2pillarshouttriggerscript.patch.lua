-- pex: gatherspectators be9b5653 d090438f
-- pex: monsterappears 1ddb6662 a78b3353
-- pex: onhit c6847738
-- OnHit ran GatherSpectators (poll DLC2PillarDestroyed:IsStopped, then a now-immediate
-- SendStoryEventAndWait), then StoneExplodes and the stone update, then MonsterAppears (poll the
-- alias fill, minimum 5 s), then EVPAliases and EnableAndActivate. Now one stage field plus a
-- timer carries OnHit's tail through both polls in OnTick.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.5)
	C.Stage = rt.sequence("Idle", "Gathering", "Appearing")
	C.__vars.phStage = C.Stage.Idle
	C.__vars.gsT = rt.timer(0.0)
	C.__vars.gsMonster = rt.form("ObjectReference")
	C.__vars.myLinkedStone = rt.form("DLC2StandingStoneScript")
	C.__vars.maT = rt.timer(0.0)
	C.__vars.maCount = rt.int(0)

	function C:GatherSpectators()
		self.gsMonster = self:GetLinkedRef(self.DLC2LinkPillarMonster)
		self.DLC2PillarDestroyed:Stop()
		self.phStage = C.Stage.Gathering
		self.gsT = 0.0
		self:OnTick()
	end

	function C:MonsterAppears()
		self.myMonster:RegisterPillarShoutTrigger(self)
		self.myMonster:Enable()
		self.myMonster:Activate(self)
		if not self.QuestMonsterAlias then
			self.phStage = C.Stage.Idle
			return self:__finishAppear()
		end
		self.QuestMonsterAlias:ForceRefTo(self.myMonster)
		self.maCount = 0
		self.phStage = C.Stage.Appearing
		self.maT = 0.0
		self:OnTick()
	end

	function C:__finishAppear()
		if self.QuestToSetStagesIn and self.QuestStageToSetWhenLurkerSpawned then
			self.QuestToSetStagesIn:SetStage(self.QuestStageToSetWhenLurkerSpawned)
		end
		self.monsterAppeared = true
		rt.cast(self.DLC2PillarDestroyed, "DLC2PillarDestroyedSpectatorsScript"):EVPAliases()
		self:EnableAndActivate()
	end

	function C:OnTick()
		if self.phStage == C.Stage.Gathering then
			if self.gsT > 0 then return end
			if not self.DLC2PillarDestroyed:IsStopped() then
				self.gsT = self.gsT + 1.0
				return
			end
			self.phStage = C.Stage.Idle
			self.DLC2PillarDestroyedStart:SendStoryEventAndWait{ akRef1 = self, akRef2 = self.gsMonster }
			self:StoneExplodes()
			self.myLinkedStone.Freed = true
			self.myLinkedStone:SetDestroyed(false)
			self:MonsterAppears()
		elseif self.phStage == C.Stage.Appearing then
			if self.maT > 0 then return end
			if self.QuestMonsterAlias:GetReference() ~= self.myMonster or self.maCount < 5 then
				self.maCount = self.maCount + 1
				self.maT = self.maT + 1.0
				return
			end
			self.phStage = C.Stage.Idle
			self:__finishAppear()
		end
	end

	function C:OnHit(akAggressor, akSource, akProjectile, abPowerAttack, abSneakAttack, abBashAttack, abHitBlocked)
		self.myMonster = self:GetLinkedRef(self.DLC2LinkPillarMonster)
		if self.DoOnce then return end
		if akSource ~= self.DLC2VoiceBendToWill1 and akSource ~= self.DLC2VoiceBendToWill2
			and akSource ~= self.DLC2VoiceBendToWill3 then
			return
		end
		self.DoOnce = true
		local myLinkedToggle = self:GetLinkedRef(self.DLC2LinkPillarToggle)
		self.myLinkedStone = self:GetLinkedRef(self.DLC2LinkPillarStandingStone)
		self.myLinkedStone:SetDestroyed(true)
		myLinkedToggle:Disable()
		self:GatherSpectators()
	end
end
