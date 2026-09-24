-- pex: onactivate f2c865a4
-- OnActivate's only latent site was PositionItemAndDisablePhysics, reached through DisplayItem;
-- the S6 splitter already turned that into its own OnTick continuation. Message.Show needs no
-- rewrite either (script-api.md, "Menus"). No change.
local rt = require('skymod.rt')

return function(C)
end
