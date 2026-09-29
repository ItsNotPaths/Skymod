-- pex: onactivate 2611b352
-- Sleeping in a jail bed read the pick from Show(jailTime) at once. The event now asks; OnTick
-- reads the answer and serves the time.
local rt = require('skymod.rt')

return function(C)
	C.__vars.asking = rt.bool(false)

	local function player() return rt.static("Game", "GetPlayer") end

	function C:OnActivate(akActivateRef)
		if akActivateRef ~= player() then return end
		self.JailTime = 10
		self.asking = true
		self.JailBedMsg:Show(self.JailTime)
	end

	function C:OnTick()
		if not self.asking then return end
		local choice = self.JailBedMsg:Answer()
		if choice < 0 then return self.JailBedMsg:Show(self.JailTime) end
		self.asking = false
		if choice ~= 0 then return end
		rt.static("Game", "ServeTime")
	end
end
