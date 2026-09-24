-- pex: onactivate f4437c78
-- pex: onequipped a91ebd7d
-- Reading the Oghma Infinium waited 2 s (WaitMenuMode) before ReadOghmaInfinium, which S6 splits.
-- Now `open_t` holds the 2 s, a real timer (script-api.md section 7), and `from_world` which way
-- it was read.
local rt = require('skymod.rt')

return function(C)
	C.__vars.open_t = rt.timer(rt.None)
	C.__vars.from_world = rt.bool(false)
	local split_tick = C.__fn.ontick
	local function player() return rt.static("Game", "GetPlayer") end

	local function open(self, from_world)
		if self.open_t ~= rt.None then return end
		self.from_world = from_world
		self.open_t = 2.0
	end

	function C:OnEquipped(reader)
		if reader == player() then open(self, false) end
	end

	function C:OnActivate(reader)
		if reader == player() and not self:IsActivationBlocked() then open(self, true) end
	end

	function C:OnTick()
		split_tick(self)
		if self.open_t == rt.None or self.open_t > 0 then return end
		self.open_t = rt.None
		self:ReadOghmaInfinium(self.from_world)
	end
end
