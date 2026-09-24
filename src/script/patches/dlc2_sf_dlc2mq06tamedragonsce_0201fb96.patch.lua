-- pex: fragment_6 b8bf219c 581be348
-- Fragment_6 just calls RestrainDragon(true) then ValidateWorldspace(); both are now non-blocking
-- and independent (ValidateWorldspace never reads restrain state), so no change is needed here.
return function(C) end
