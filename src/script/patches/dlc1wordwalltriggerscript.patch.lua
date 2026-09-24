-- pex: onupdate 1569b5d8
-- pex: startfx b268f1f4
-- OnUpdate looped every tick (wait(0)) while iInTrigger>0 and the word was unlearned, starting or
-- stopping the FX. StartFX's one wait (player close enough) fired once, then held state "done"
-- until it finished. `fxOn` replaces the local cleanUpFinished; a stage field carries StartFX's wait.
local rt = require('skymod.rt')

local Learn = rt.sequence("Idle", "Waiting")

return function(C)
	C.__vars.fxOn = rt.bool(false)
	C.__vars.learn = Learn.Idle
	C.__vars.learnT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.05) -- wait(0): every tick the poll ran

	function C:OnUpdate()
		if self:GetState() == "updating" then return end -- the state's own onupdate is a no-op already
		self:GotoState("updating")
		self.fxOn = false
	end

	function C:StartFX()
		local player = rt.static("Game", "GetPlayer")
		local dist = player:GetDistance(self.looktarget)
		if (dist < self.innerradius and not player:IsInCombat()) or dist <= 200 then
			self:GotoState("done")
			self.wordlearned = true
			self.wordimodwordlearned:Apply(1)
			self.learn, self.learnT = Learn.Waiting, 2.0
			return
		end
		if dist < self.middleradius and dist >= self.innerradius then
			if not self.finishedimod03 and not player:IsInCombat() then
				self.imodloop03:ApplyCrossFade(0.25)
				self.finishedimod02, self.finishedimod03 = false, true
			end
			if not self.finishedwordanim03 then
				self.wordwall:PlayAnimation("Dark3Wild")
				self.finishedwordanim02, self.finishedwordanim03 = true, true
			end
			return
		end
		if dist < self.outerradius and dist >= self.middleradius then
			if self.finishedimod03 then
				self.finishedwordanim03 = false
				self.wordwall:PlayAnimation("Dark3ExitWild")
				self.finishedwordanim02 = true
			end
			if not self.finishedimod02 and not player:IsInCombat() then
				self.imodloop02:ApplyCrossFade(0.25)
				self.finishedimod03, self.finishedimod02 = false, true
			end
			if not self.finishedwordanim02 then
				self.wordwall:PlayAnimation("Dark2Wild")
				self.finishedwordanim02, self.finishedwordanim03 = true, false
			end
			return
		end
		if dist < 2000 and dist >= self.outerradius then
			if self.finishedimod02 or self.finishedimod03 then
				self.wordwall:PlayAnimation("Dark2ExitWild")
				rt.static("ImageSpaceModifier", "RemoveCrossFade", 0.5)
				self.finishedimod02, self.finishedimod03 = false, false
				self.finishedwordanim02, self.finishedwordanim03 = false, false
			end
		end
	end

	function C:OnTick()
		if self:GetState() == "updating" then
			if self.iintrigger > 0 and not self.wordlearned then
				if self:isLooking() then
					self:StartFX()
					self.fxOn, self.doonce = true, false
				elseif self.fxOn then
					self:StopFX()
					self.fxOn = false
				elseif not self.doonce then
					self.doonce = true
					self.wordwall:PlayAnimation("DarkXWild")
				end
			else
				if self.fxOn then
					self:StopFX()
					self.fxOn = false
				end
				if self:GetState() ~= "done" then self:GotoState("") end
			end
		end
		if self.learn == Learn.Waiting and self.learnT <= 0 then
			self.wordwall:PlayAnimation("Learned")
			self.finishedimod02, self.finishedimod03 = false, false
			rt.static("Game", "teachWord", self.myword)
			self.shoutglobal.value = self.shoutglobal.value + 1
			self.wordsound:DisableNoWait()
			self.soundwallwhisper:DisableNoWait()
			if self.myquest then self.myquest:SetStage(self.mystage) end
			if self.myenabler then self.myenabler:EnableNoWait() end
			if self.mylocrefmarker then self.mylocrefmarker:DisableNoWait() end
			self:PokeWordWallListenerQuests()
			self.learn = Learn.Idle
		end
	end
end
