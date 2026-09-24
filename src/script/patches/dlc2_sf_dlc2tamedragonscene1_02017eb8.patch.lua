-- pex: fragment_2 f070f3c8
-- Fragment_2 just calls RestrainDragon(true) then ValidateWorldspace(); both are now non-blocking
-- and independent (ValidateWorldspace never reads restrain state), so no change is needed here.
return function(C) end
