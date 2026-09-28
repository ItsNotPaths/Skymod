-- OnActivate opens the inventory, waits 0.1 s, then turns the mannequin AI off. Every instance ticked every tick for it; at 0.1 s the wait ends at most 0.1 s late.
local rt = require('skymod.rt')

return function(C)
	C.__vars.TickRate = rt.float(0.1)
end
