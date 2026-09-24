-- pex: waiting.onactivate b021e257
-- OnActivate ran the mist sequence inline: enable feed, wait 0.1, mist01, wait 0.1, mist01a,
-- wait 0.2, then finish. Now a one-shot sequence on the clock, walked from OnTick.
local rt = require('skymod.rt')

return function(C)
	local orig_tick = C.__fn.ontick
	C.FillSeq = rt.sequence("Idle", "Feed", "Mist1", "Mist1a", "Done")
	C.__vars.fillstage = C.FillSeq.Idle
	C.__vars.fillsw = rt.stopwatch(0.0)
	local Waiting = rt.state(C, "waiting")
	local S = C.FillSeq

	function Waiting:OnActivate(activateRef)
		if not self.dostuffwithmist then return end
		self.dostuffwithmist = false
		if self.mysoundobject then self.mysoundobject:enable(self) end
		rt.static("game", "DisablePlayerControls", true, true, false, false, true, true, true, true, 0)
		self.mistfeed01:enable(true)
		self.mistfeed02:enable(true)
		self.fillstage = S.Feed
		self.fillsw = 0.0
	end

	function C:OnTick()
		orig_tick(self)
		if self.fillstage == S.Feed then
			if self.fillsw < 0.1 then return end
			self.mist01:enable(true)
			self.fillsw = self.fillsw - 0.1
			self.fillstage = S.Mist1
		end
		if self.fillstage == S.Mist1 then
			if self.fillsw < 0.1 then return end
			self.mist01a:enable(true)
			self.fillsw = self.fillsw - 0.1
			self.fillstage = S.Mist1a
		end
		if self.fillstage == S.Mist1a then
			if self.fillsw < 0.2 then return end
			self.myquest:setStage(self.stage)
			self:GotoState("complete")
			self:doCoughing()
			self.mist02:enable(true)
			self.mist03:enable(true)
			self.mist04:enable(true)
			self.fillstage = S.Done
		end
	end
end
