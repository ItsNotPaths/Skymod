-- pex: onupdate 1569b5d8
-- pex: startfx b268f1f4
-- Default-state OnUpdate ran the wall's look/proximity loop every tick (wait(0)) until iInTrigger
-- dropped or the word was learned; StartFX itself waited 2 s before its learned-word tail. Now
-- OnTick in the "updating" state runs one pass per tick, and the tail runs from a class-level
-- check so it still fires after StartFX moves the ref to state "done".
local rt = require('skymod.rt')

return function(C)
	C.__vars.sfT = rt.timer(0.0)
	C.__vars.sfPending = rt.bool(false)
	C.__vars.cleanUpFinished = rt.bool(true) -- was a local in Papyrus; now spans OnTick calls

	function C:OnUpdate()
		self.cleanUpFinished = true
		self:GotoState("updating")
		self:OnTick()
	end

	function C:StartFX()
		local player = rt.static("Game", "GetPlayer")
		local d = player:GetDistance(self.lookTarget)
		if (d < self.innerRadius and not player:IsInCombat()) or d <= 200 then
			self:GotoState("done")
			self.wordLearned = true
			self.wordIMODWordLearned:Apply(1)
			self.sfPending = true
			self.sfT = 2.0 -- fresh wait: sfT idles until the word is learned
			return
		end
		if d < self.middleRadius and d >= self.innerRadius then
			if not self.finishedIMOD03 and not player:IsInCombat() then
				self.IMODLoop03:ApplyCrossFade(0.25)
				self.finishedIMOD02 = false
				self.finishedIMOD03 = true
			end
			if not self.finishedWordAnim03 then
				self.wordWall:PlayAnimation("Dark3Wild")
				self.finishedWordAnim02 = true
				self.finishedWordAnim03 = true
			end
			return
		end
		if d < self.outerRadius and d >= self.middleRadius then
			if self.finishedIMOD03 then
				self.finishedWordAnim03 = false
				self.wordWall:PlayAnimation("Dark3ExitWild")
				self.finishedWordAnim02 = true
			end
			if not self.finishedIMOD02 and not player:IsInCombat() then
				self.IMODLoop02:ApplyCrossFade(0.25)
				self.finishedIMOD03 = false
				self.finishedIMOD02 = true
			end
			if not self.finishedWordAnim02 then
				self.wordWall:PlayAnimation("Dark2Wild")
				self.finishedWordAnim02 = true
				self.finishedWordAnim03 = false
			end
			return
		end
		if d < 2000 and d >= self.outerRadius then
			if self.finishedIMOD02 or self.finishedIMOD03 then
				self.wordWall:PlayAnimation("Dark2ExitWild")
				rt.static("ImageSpaceModifier", "RemoveCrossFade", 0.5)
				self.finishedIMOD02 = false
				self.finishedIMOD03 = false
				self.finishedWordAnim02 = false
				self.finishedWordAnim03 = false
			end
		end
	end

	local function trigger_loop(self)
		if self.iInTrigger <= 0 or self.wordLearned then
			if not self.cleanUpFinished then
				self.cleanUpFinished = true
				self:StopFX()
			end
			if self:GetState() ~= "done" then self:GotoState("") end
			return
		end
		if self:isLooking() then
			self:StartFX()
			self.cleanUpFinished = false
			self.doOnce = false
		elseif not self.cleanUpFinished then
			self.cleanUpFinished = true
			self:StopFX()
		elseif not self.doOnce then
			self.doOnce = true
			self.wordWall:PlayAnimation("DarkXWild")
		end
	end

	-- One class-level OnTick: StartFX moves the ref to state "done" before its own tail waits,
	-- so the tail must be checked outside the "updating" state too.
	function C:OnTick()
		if self:GetState() == "updating" then trigger_loop(self) end
		if self.sfPending and self.sfT <= 0 then
			self.sfPending = false
			self.wordWall:PlayAnimation("Learned")
			self.finishedIMOD02 = false
			self.finishedIMOD03 = false
			rt.static("Game", "TeachWord", self.myWord)
			self.shoutGlobal.value = self.shoutGlobal.value + 1
			self.wordSound:DisableNoWait()
			self.soundWallWhisper:DisableNoWait()
			if self.myQuest then self.myQuest:SetStage(self.myStage) end
			if self.myEnabler then self.myEnabler:EnableNoWait() end
			if self.myLocRefMarker then self.myLocRefMarker:DisableNoWait() end
			self:PokeWordWallListenerQuests()
		end
	end
end
