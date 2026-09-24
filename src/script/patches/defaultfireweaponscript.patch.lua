-- pex: fireloop.onbeginstate a9052b3f
-- OnBeginState(FireLoop) looped: roll a wait, wait it out, fire (or check the quest stage) once,
-- then loop. Now a timer plus a bool for whether the next tick should fire or reroll the wait.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
	C.__vars.t = rt.timer(0.0)
	C.__vars.needsroll = rt.bool(true)
	local FireLoop = rt.state(C, "FireLoop")

	local function roll(self)
		self.needsroll = true
		self.waittimer = rt.static("Utility", "RandomFloat", self.minwaittime, self.maxwaittime)
		self.t = self.waittimer
	end

	function FireLoop:OnBeginState()
		roll(self)
	end

	function FireLoop:OnTick()
		if self.t > 0 then return end
		if not self.needsroll then
			roll(self)
			return
		end
		if self.myquest then
			if self.myquest:IsRunning() then
				if self.myquest:GetStage() >= self.stagetostopfire then
					self.looping = false
				elseif self.myquest:GetStage() >= self.stagetostartfire then
					if self:IsEnabled() then
						self.weapontype:Fire(self, self.ammotype)
						self.timesfired = self.timesfired + 1
					end
					if self.timestofire ~= -1 and self.timesfired == self.timestofire then
						self.looping = false
					end
				end
			else
				self.needsroll = false -- the quest isn't running: wait 8s, then reroll before checking again
				self.t = 8
				return
			end
		else
			if self:IsEnabled() then
				self.weapontype:Fire(self, self.ammotype)
				self.timesfired = self.timesfired + 1
			else
				self.looping = false
			end
			if self.timestofire ~= -1 and self.timesfired == self.timestofire then
				self.looping = false
			end
		end
		if not self.looping then
			self:GotoState("Waiting")
			return
		end
		roll(self)
	end
end
