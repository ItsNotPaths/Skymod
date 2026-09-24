-- pex: fragment_18 865e123d
-- OpenPortal's closing path (triggerRef, false) never waits: it registers for the seal's "done"
-- event and returns at once, so Fragment_18's Enable/AddItem right after it need no ordering fix.
-- Left as converted.
local rt = require('skymod.rt')

return function(C) end
