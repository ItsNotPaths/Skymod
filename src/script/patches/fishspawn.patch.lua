-- pex: onload 2a40b4c3
-- OnLoad waited 10 s, then spawned 25 fish 0.2 s apart. The 25-count is a fact (a loop index over
-- data), not a resume point; OnTick advances it when the clock is due.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.2)
	C.__vars.spawning = rt.bool(false)
	C.__vars.wait = rt.timer(0.0)
	C.__vars.count = rt.int(0)

	function C:OnLoad()
		self.spawning = true
		self.wait = 10.0
		self.count = 0
	end

	function C:OnTick()
		if not self.spawning or self.wait > 0 then return end
		if self.count >= 25 then
			self.spawning = false
			return
		end
		local fishRef = self:PlaceAtMe(self.FishType)
		local fish = rt.cast(fishRef, "TestFish")
		fish.Spawner = self
		fish:Start()
		self.count = self.count + 1
		self.wait = 0.2
	end
end
