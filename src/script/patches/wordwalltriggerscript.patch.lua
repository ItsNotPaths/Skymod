-- pex: onupdate d217de57
-- pex: startfx b268f1f4
-- OnUpdate ran a busy while(wait(0)) loop for the trigger's whole life, calling StartFX/StopFX
-- each frame; StartFX itself waited 2s before finishing once the word was learned. Both are now
-- OnTick: one pass of the loop body per tick, and a timer for the 2s finish.
local rt = require('skymod.rt')

return function(C)
	C.__vars.wwticking = rt.bool(false)
	C.__vars.wwclean = rt.bool(true)
	C.__vars.learnt = rt.timer(rt.None)

	local function finish_learned(self)
		self.wordwall:playAnimation("Learned")
		self.finishedimod02 = false
		self.finishedimod03 = false
		rt.static("Game", "TeachWord", self.myword)
		self.shoutglobal.value = self.shoutglobal.value + 1
		self.wordsound:disableNoWait(false)
		self.soundwallwhisper:disableNoWait(false)
		if self.myquest then self.myquest:setStage(self.mystage) end
		if self.myenabler then self.myenabler:enableNoWait(false) end
		if self.mylocrefmarker then self.mylocrefmarker:disableNoWait(false) end
		self:PokeWordWallListenerQuests()
	end

	function C:StartFX()
		local player = rt.static("Game", "GetPlayer")
		local dist = player:GetDistance(self.looktarget)
		if (dist < self.innerradius and not player:IsInCombat()) or dist <= 200 then
			self:GotoState("done")
			self.wordlearned = true
			self.wordimodwordlearned:Apply(1)
			self.learnt = 2.0
			return
		end
		if dist < self.middleradius and dist >= self.innerradius then
			self.wordsound:enableNoWait(false)
			self.soundwallwhisper:enableNoWait(false)
			if not self.finishedimod03 and not player:IsInCombat() then
				self.imodloop03:ApplyCrossFade(0.25)
				self.finishedimod02 = false
				self.finishedimod03 = true
			end
			if not self.finishedwordanim03 then
				self.wordwall:playAnimation("Dark3Wild")
				self.finishedwordanim02 = true
				self.finishedwordanim03 = true
			end
			return
		end
		if dist < self.outerradius and dist >= self.middleradius then
			self.wordsound:disableNoWait(false)
			self.soundwallwhisper:disableNoWait(false)
			if self.finishedimod03 then
				self.finishedwordanim03 = false
				self.wordwall:playAnimation("Dark3ExitWild")
				self.finishedwordanim02 = true
			end
			if not self.finishedimod02 and not player:IsInCombat() then
				self.imodloop02:ApplyCrossFade(0.25)
				self.finishedimod03 = false
				self.finishedimod02 = true
			end
			if not self.finishedwordanim02 then
				self.wordwall:playAnimation("Dark2Wild")
				self.finishedwordanim02 = true
				self.finishedwordanim03 = false
			end
			return
		end
		if dist < 2000 and dist >= self.outerradius then
			if self.finishedimod02 or self.finishedimod03 then
				self.wordwall:playAnimation("Dark2ExitWild")
				rt.static("ImageSpaceModifier", "RemoveCrossFade", 0.5)
				self.finishedimod02 = false
				self.finishedimod03 = false
				self.finishedwordanim02 = false
				self.finishedwordanim03 = false
			end
		end
	end

	function C:OnUpdate()
		if self.wwticking then return end -- RegisterForUpdate is one-shot; a second start is dropped
		self.wwticking = true
		self.wwclean = true
		self:OnTick() -- Papyrus checked at once (wait(0))
	end

	function C:OnTick()
		if self.learnt ~= rt.None then
			if self.learnt > 0 then return end
			self.learnt = rt.None
			finish_learned(self)
			return
		end
		if not self.wwticking then return end
		if self.iintrigger <= 0 or self.wordlearned then
			if not self.wwclean then
				self:StopFX()
				self.wwclean = true
			end
			self.wwticking = false
			return
		end
		if self:isLooking() then
			self:StartFX()
			self.wwclean = false
			self.doonce = false
		elseif not self.wwclean then
			self:StopFX()
			self.wwclean = true
		elseif not self.doonce then
			self.doonce = true
			self.wordwall:playAnimation("DarkXWild")
		end
	end
end
