-- pex: completestoryquest d5e744b5
-- pex: kickoffreconquests 7f362297
-- pex: swapfollowers 6bf42c2d
-- CompleteStoryQuest polled every 0.5 s until the stopped story quest stopped running;
-- KickOffReconQuests sent the recon story event every 0.5 s until a quest took it. Both polls are
-- now OnTick; `endingStory` and `reconOwed` are the facts that callers wait on.
-- SwapFollowers is unchanged: DismissFollower(2) keeps the follower count, so nothing after it
-- depends on the dismissal; its callers wait on FollowerScript's "Dismissing" state instead.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.endingStory = rt.form("CompanionsStoryQuest")
	C.__vars.endingT = rt.timer(0.0)
	C.__vars.reconOwed = rt.bool(false) -- no recon quest has taken the story event yet
	C.__vars.reconT = rt.timer(0.0)
	local split_tick = C.__fn.ontick

	local function finish_story(self, story)
		self.endingStory = rt.None
		self.CurrentStoryQuest = rt.None
		self.StoryQuestIsRunning = false
		if story ~= self.C03 and story ~= self.C04 and story ~= self.C05 then
			self.RadiantMiscObjQuest:SetObjectiveDisplayed(10, true)
		end
		if story == self.C02 then self:OpenSkyforge() end
	end

	function C:CompleteStoryQuest(storyToEnd)
		if self.endingStory then return end
		self.endingStory = storyToEnd
		self.endingT = 0.0
		storyToEnd:Teardown()
		storyToEnd:Stop()
		self:OnTick()
	end

	local function story_tick(self)
		if not self.endingStory or self.endingT > 0 then return end
		if self.endingStory:IsRunning() then
			self.endingT = 0.5
			return
		end
		finish_story(self, self.endingStory)
	end

	function C:KickOffReconQuests()
		if self.__reconKicked or self.reconOwed then return end
		self.RadiantAelaBlock = true
		if self.AelaCurrentQuest then
			self.AelaCurrentQuest:Stop()
			self.AelaCurrentQuest = rt.None
		end
		if self.AelaNextQuest then
			self.AelaNextQuest:Stop()
			self.AelaNextQuest = rt.None
		end
		self.AelaInReconMode = true
		self.reconOwed = true
		self.reconT = 0.0
		self:OnTick()
	end

	local function recon_tick(self)
		if not self.reconOwed or self.reconT > 0 then return end
		if not self.ReconRadiantKeyword:SendStoryEventAndWait() then
			self.reconT = 0.5
			return
		end
		self.reconOwed = false
		self.ReconRadiantKeyword:SendStoryEvent()
		self.RadiantAelaBlock = false
	end

	function C:OnTick()
		split_tick(self)
		story_tick(self)
		recon_tick(self)
	end
end
