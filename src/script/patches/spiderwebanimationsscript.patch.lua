-- pex: onupdate 6794a541
-- pex: playwebanimations f1a1b65e
-- OnUpdate polled every 5s while webbed: pick a thrash idle, play it (PlayWebAnimations, its own
-- 5s wait), then wait 5s more and loop. PlayWebAnimations stays callable on its own (a mod may
-- call it): action, then its own 5s wait. OnUpdate now starts one cycle; OnTick continues it,
-- waiting out PlayWebAnimations' 5s, then its own 5s gap, then looping if still webbed.
local rt = require('skymod.rt')

return function(C)
	C.Loop = rt.sequence("Idle", "PlayWait", "Gap")
	C.__vars.loop = C.Loop.Idle
	C.__vars.webT = rt.timer(0.0)
	C.__vars.TickRate = rt.float(0.5)
	local S = C.Loop

	local function eligible(self) return self.inTrigger and not self.stopCondition end

	local function play(self)
		local rand = rt.static("Utility", "RandomInt", 1, 2)
		self.webActor:SetAV("Variable03", rand)
		self:PlayWebAnimations(rand)
	end

	function C:PlayWebAnimations(iRand)
		if iRand == 1 and not self.stopCondition then
			self.webActor:PlayIdle(self.idleWebThrashShort)
		elseif iRand == 2 and not self.stopCondition then
			self.webActor:PlayIdle(self.idleWebThrashShort2)
		end
		self.loop = S.PlayWait
		self.webT = 5.0
	end

	function C:OnUpdate()
		if self.loop ~= S.Idle then return end -- already looping
		if not eligible(self) then return end
		play(self)
	end

	function C:OnTick()
		if self.loop == S.Idle or self.webT > 0 then return end
		if self.loop == S.PlayWait then
			self.loop = S.Gap
			self.webT = 5.0
			return
		end
		self.loop = S.Idle
		if eligible(self) then play(self) end
	end
end
