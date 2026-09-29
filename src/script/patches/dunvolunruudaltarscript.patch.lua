-- pex: waiting.onactivate fd848e5f
-- Placing a relic hand or foot on the altar asked which one; the pick removed it from the player
-- and set its flag. All four flags set plays the pulldown animation and unlocks the cairn door.
-- OnTick in waiting reads the pick; `player` is carried from OnActivate.
local rt = require('skymod.rt')

local RELICS = {
	[0] = { item = "ReliqLH", flag = "lh" },
	[1] = { item = "ReliqRH", flag = "rh" },
	[2] = { item = "ReliqLF", flag = "lf" },
	[3] = { item = "ReliqRF", flag = "rf" },
}

return function(C)
	C.__vars.asking = rt.bool(false)
	C.__vars.player = rt.form("ObjectReference")
	local Waiting = rt.state(C, "waiting")

	function Waiting:OnActivate(actronaut)
		self.player = rt.static("Game", "GetPlayer")
		if actronaut ~= self.player then return end
		self.asking = true
		self.AltarMsg:Show()
	end

	function Waiting:OnTick()
		if not self.asking then return end
		local input = self.AltarMsg:Answer()
		if input < 0 then return self.AltarMsg:Show() end
		self.asking = false
		local r = RELICS[input]
		if r then
			self.player:RemoveItem(self[r.item], 1, false)
			self[r.flag] = true
		end
		if self.lh and self.rh and self.lf and self.rf then
			self:PlayAnimation("pulldown")
			rt.static("Game", "ShakeController", 0.1, 0.1, 0.75)
			self.CairnDoor:Lock(false, false)
		end
	end
end
