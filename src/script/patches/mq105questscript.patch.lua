-- pex: greybeardspeakingeffect 73fa6300
-- GreybeardSpeakingEffect played the outro shake in four named beats (0.4, 0.2, 0.1, 0.3 of
-- fTotalTime). A sequence stage plus one timer now walks them in OnTick. The class already ticks
-- for another mechanical split; call it first.
local rt = require('skymod.rt')

local function trace(self, msg) rt.static("Debug", "Trace", tostring(self) .. " " .. msg) end

return function(C)
	-- each stage names the step that runs when speechWait runs out; Idle is the fact callers read
	C.Speech = rt.sequence("Idle", "Dust2", "Dust3", "Dust4", "Settle")
	C.__vars.speech = C.Speech.Idle
	C.__vars.speechWait = rt.timer(0.0)
	C.__vars.speechTime = rt.float(2.0) -- fTotalTime, carried across the waits
	rt.params(C, "GreybeardSpeakingEffect", { { "fTotalTime", 2.0 } })

	local function player() return rt.static("Game", "GetPlayer") end

	function C:GreybeardSpeakingEffect(fTotalTime)
		if self.speech ~= C.Speech.Idle then
			trace(self, "GreybeardSpeakingEffect(" .. fTotalTime .. "): already speaking, dropped")
			return
		end
		self.speech, self.speechWait, self.speechTime = C.Speech.Dust2, 0.4 * fTotalTime, fTotalTime
		trace(self, "GreybeardSpeakingEffect(" .. fTotalTime .. ")")
		self.AMBRumbleShakeGreybeards:Play(player())
		self.GreybeardOutroIMOD:Apply(1.0)
		self.OutroDust1:Activate(player(), false)
		self.OutroTrigger:KnockAreaEffect(0.25, 250.0)
		rt.static("Game", "ShakeController", 0.5, 0.5, fTotalTime)
		rt.static("Game", "ShakeCamera", { afStrength = 0.1 * fTotalTime })
	end

	local split_tick = C.__fn.ontick
	function C:OnTick()
		split_tick(self)
		if self.speech == C.Speech.Idle or self.speechWait > 0 then return end
		local S, step, t = C.Speech, self.speech, self.speechTime
		if step == S.Dust2 then
			self.speech, self.speechWait = S.Dust3, 0.2 * t
			self.OutroDust2:Activate(player(), false)
		elseif step == S.Dust3 then
			self.speech, self.speechWait = S.Dust4, 0.1 * t
			self.OutroDust3:Activate(player(), false)
		elseif step == S.Dust4 then
			self.speech, self.speechWait = S.Settle, 0.3 * t
			self.OutroTrigger:KnockAreaEffect(0.2, 250.0)
			self.OutroDust4:Activate(player(), false)
		else
			self.speech = S.Idle
			self.OutroTrigger:KnockAreaEffect(0.2, 250.0)
			rt.static("Game", "ShakeCamera", { afStrength = 0.01 * t })
			self.OutroDust1:Activate(player(), false)
		end
		trace(self, "GreybeardSpeakingEffect step " .. tostring(step))
	end
end
