-- Auto-generated zone categories. Do not edit manually.
-- Version: fe92f475

local _dnl = DeathNotificationLib.Internal ---@class _dnl
if not _dnl then return end

_dnl.D.ZONE_CATEGORIES = {
  ["Kalimdor"] = { 1411, 1412, 1413, 1438, 1439, 1440, 1441, 1442, 1443, 1444, 1445, 1446, 1447, 1448, 1449, 1450, 1451, 1452, 1454, 1456, 1457, 1943, 1947, 1950 },
  ["Eastern Kingdoms"] = { 1416, 1417, 1418, 1419, 1420, 1421, 1422, 1423, 1424, 1425, 1426, 1427, 1428, 1429, 1430, 1431, 1432, 1433, 1434, 1435, 1436, 1437, 1453, 1455, 1458, 1941, 1942, 1954, 1957 },
  ["Outland"] = { 1944, 1946, 1948, 1949, 1951, 1952, 1953, 1955 },
}

if _dnl.IS_FOREVER then
  _dnl.D.ZONE_CATEGORIES["Azeroth"] = _dnl.D.ZONE_CATEGORIES["Azeroth"] or {}
  table.insert(_dnl.D.ZONE_CATEGORIES["Azeroth"], 2521) -- Zephras Isle
  _dnl.D.ZONE_CATEGORIES["Eastern Kingdoms"] = _dnl.D.ZONE_CATEGORIES["Eastern Kingdoms"] or {}
  table.insert(_dnl.D.ZONE_CATEGORIES["Eastern Kingdoms"], 2548) -- Riverglades
  _dnl.D.ZONE_CATEGORIES["Kalimdor"] = _dnl.D.ZONE_CATEGORIES["Kalimdor"] or {}
  table.insert(_dnl.D.ZONE_CATEGORIES["Kalimdor"], 2482) -- Mount Hyjal
  table.insert(_dnl.D.ZONE_CATEGORIES["Kalimdor"], 2524) -- Darkspear Islands
  table.insert(_dnl.D.ZONE_CATEGORIES["Kalimdor"], 2652) -- Shen'dralas
end
