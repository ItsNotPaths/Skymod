-- pex: battyloops f632adce
-- BattyLoops moved the bats toward the caster every 0.2 s while bBatsLoopContinue, then sent them
-- home and deleted them 0.25 s later. Now `bats` is that run and a stopwatch paces it.
local rt = require('skymod.rt')

return function(C)
	C.Bats = rt.sequence("Idle", "Following", "Returning")
	local B = C.Bats
	C.__vars.bats = B.Idle
	C.__vars.bats_sw = rt.stopwatch(0.0)
	local split_tick = C.__fn.ontick

	local function follow(self)
		local fx, caster = self.MyBatsFXObjectRef, self.CasterActor
		fx:TranslateToRef(caster, caster:GetDistance(fx) + self.fTranslationSpeed, 1)
	end

	function C:BattyLoops()
		if self.bats ~= B.Idle then return end
		self.bats = B.Following
		self.bats_sw = 0.0
		if self.bBatsLoopContinue then follow(self) end
		self:OnTick()
	end

	local function bats_tick(self)
		if self.bats == B.Following then
			if self.bBatsLoopContinue then
				if self.bats_sw < 0.2 then return end
				self.bats_sw = self.bats_sw - 0.2
				follow(self)
				return
			end
			self.MyBatsFXObjectRef:TranslateToRef(self.CasterActor, self.fTranslationSpeed, 1)
			self.bats = B.Returning
			self.bats_sw = 0.0
		elseif self.bats == B.Returning and self.bats_sw >= 0.25 then
			self.bats = B.Idle
			self.MyBatsFXObjectRef:Disable()
			self.MyBatsFXObjectRef:Delete()
			self.MyBatsFXObjectRef = rt.None
		end
	end

	function C:OnTick()
		split_tick(self)
		bats_tick(self)
	end
end
