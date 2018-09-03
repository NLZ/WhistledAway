local AddonName, Addon = ...

-- Libs
local HBD = LibStub("HereBeDragons-2.0")
local HBDPins = LibStub("HereBeDragons-Pins-2.0")

-- Upvalues
local floor, format, ipairs, pairs, print, tconcat, tremove =
      floor, format, ipairs, pairs, print, table.concat, table.remove

local sqrt = math.sqrt

local WorldMapTooltip = WorldMapTooltip

-- Modules
local Core = DethsLibLoader("DethsAddonLib", "1.0"):Create(AddonName)
Core.Nearest = {} -- Array of nearest flight master names

-- Consts
local WHISTLE_MAPS = {
  -- uiMapIDs for calls to C_TaxiMap.GetTaxiNodesForMap()
  [630] = true, -- Azsuna (Broken Isles)
  [885] = true, -- Antoran Wastes (Argus)
  [830] = true, -- Krokuun (Argus)
  [882] = true, -- Mac'Aree (Argus)
  [895] = true, -- Tiragarde Sound (Kul'tiras)
  [862] = true, -- Zuldazar (Zandalar)

  -- [[ Debug ]] --
  -- [63] = true, -- Ashenvale
}

local WHISTLE_CONTINENTS = {
  -- uiMapIDs for continents where the FMW can be used
  [619] = true, -- Broken Isles
  [905] = true, -- Argus
  [876] = true, -- Kul'tiras
  [875] = true, -- Zandalar

  -- [[ Debug ]]
  -- [12] = true, -- Kalimdor
}

local TAXI_NODES = {}

-- Variables
local currentMapID = -1
local currentZoneMapID = -1
local currentMapName = ""
local canUseWhistle = false

-- ============================================================================
-- DAL Functions
-- ============================================================================

function Core:OnInitialize()
  self:Print("Loaded!")

  -- -- Initialize Taxi data
  -- local factionGroup = UnitFactionGroup("PLAYER")
  -- local FlightPointDataProviderMixin = FlightPointDataProviderMixin
  -- for mapID in pairs(WHISTLE_MAPS) do
  --   local taxiNodes = C_TaxiMap.GetTaxiNodesForMap(mapID)
  --   print(format("%d taxis in %d", #taxiNodes, mapID))
  --   for i, taxiNodeInfo in ipairs(taxiNodes) do
  --     if FlightPointDataProviderMixin:ShouldShowTaxiNode(factionGroup, taxiNodeInfo) then
  --       TAXI_NODES[#TAXI_NODES+1] = taxiNodeInfo
  --     end
  --   end
  -- end

  -- print("Total Taxis:", "#"..#TAXI_NODES)
end

do -- OnUpdate()
  local DELAY = 1 -- seconds
  local timer = DELAY

  function Core:OnUpdate(elapsed)
    if not canUseWhistle then return end
    timer = timer + elapsed
    if (timer >= DELAY) then
      self:UpdateNearest()
      timer = 0
    end
  end

  -- HBD Callback
  HBD.RegisterCallback(AddonName, "PlayerZoneChanged", function(_, mapID)
    Core:Print("HBD PlayerZoneChanged, MapID = "..tostring(mapID))
    currentMapID = mapID
    currentZoneMapID = mapID

    local mapInfo = C_Map.GetMapInfo(mapID or 0)
    if mapInfo and mapInfo.name then
      timer = DELAY
      currentMapName = mapInfo.name

      -- Update data based on current zone and continent
      while mapInfo.mapType and (mapInfo.mapType > Enum.UIMapType.Continent) do
        if (mapInfo.mapType == Enum.UIMapType.Zone) then
          -- print("Map name:", mapInfo.name)
          currentMapName = mapInfo.name
          currentZoneMapID = mapInfo.mapID
        end
        mapInfo = C_Map.GetMapInfo(mapInfo.parentMapID)
      end

      if (mapInfo.mapType == Enum.UIMapType.Continent) then
        canUseWhistle = WHISTLE_CONTINENTS[mapInfo.mapID]
        -- print("Can use whistle? ", tostring(canUseWhistle))
        
        -- Update taxi data for current map
        local factionGroup = UnitFactionGroup("PLAYER")
        local FlightPointDataProviderMixin = FlightPointDataProviderMixin
        local taxiNodes = C_TaxiMap.GetTaxiNodesForMap(mapID)
        -- print(format("%d taxis", #taxiNodes, mapID))
        for i, taxiNodeInfo in ipairs(taxiNodes) do
          if FlightPointDataProviderMixin:ShouldShowTaxiNode(factionGroup, taxiNodeInfo) then
            TAXI_NODES[taxiNodeInfo.name] = taxiNodeInfo
          end
        end
      end
    end
  end)
end

-- ============================================================================
-- Pin Pool
-- ============================================================================

local getPin, clearPins do
  local FMW_TEXTURE_ID = 132161
  local pins = {}
  local pool = {}
  local count = 0

  local function onEnter(self)
    -- Show highlight
    self.highlight:SetAlpha(0.4)
    -- Show tooltip
    WorldMapTooltip:SetOwner(self, "ANCHOR_TOP")
    WorldMapTooltip:SetText(AddonName)
    WorldMapTooltip:AddLine(self.name, 1, 1, 1)
    WorldMapTooltip:Show()
  end

  local function onLeave(self)
    self.highlight:SetAlpha(0)
    WorldMapTooltip:Hide()
  end

  getPin = function()
    local pin = tremove(pool)
    
    if not pin then
      count = count + 1
      pin = CreateFrame("Button", AddonName.."Pin"..count)
      pin:SetSize(20, 20)

      pin.texture = pin:CreateTexture(AddonName.."PinTexture"..count, "BACKGROUND")
      pin.texture:SetTexture(FMW_TEXTURE_ID)
      pin.texture:SetAllPoints()

      pin.highlight = pin:CreateTexture(pin:GetName().."Hightlight", "HIGHLIGHT")
      pin.highlight:SetTexture(FMW_TEXTURE_ID)
      pin.highlight:SetBlendMode("ADD")
      pin.highlight:SetAlpha(0)
      pin.highlight:SetAllPoints(pin.texture)

      pin:SetScript("OnEnter", onEnter)
      pin:SetScript("OnLeave", onLeave)

      pins[#pins+1] = pin
    end

    pin:Show()
    return pin
  end

  clearPins = function()
    for _, pin in pairs(pins) do
      pin:Hide()
      pool[#pool+1] = pin
    end
  end
end

-- ============================================================================
-- General Functions
-- ============================================================================

do -- Print()
  local title = format("|cFF98FB98[%s]|r ", AddonName)
  function Core:Print(msg) print(title..msg) end
end

do -- UpdateNearest()
  local TAXI_NAME_PATTERN = "(.+),"
  local THRESHOLD = 0.005
  
  local lastX, lastY = -1, -1
  local zoneTaxis = {}
  local nearestTaxis = {}

  local function getDistance(x, y, x2, y2)
    local dx, dy = x - x2, y - y2
    return sqrt(dx * dx + dy * dy)
  end

  function Core:UpdateNearest()
    local x, y, mapID = HBD:GetPlayerZonePosition()
    if not x then return end

    -- Return if player hasn't moved
    if (lastX == x) and (lastY == y) then return end
    lastX = x
    lastY = y

    -- Clear data
    clearPins()
    HBDPins:RemoveAllWorldMapIcons(Addon)

    for k in pairs(self.Nearest) do self.Nearest[k] = nil end
    for k in pairs(zoneTaxis) do zoneTaxis[k] = nil end
    for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end

    -- Get taxis in current zone
    for _, taxi in pairs(TAXI_NODES) do
      if (taxi.name:find(currentMapName, 1, true)) then
        zoneTaxis[#zoneTaxis+1] = taxi
      end
    end

    if (#zoneTaxis == 0) then return end

    -- Calculate nearest taxis
    local currentNearest = zoneTaxis[1]
    local currentDistance = HBD:GetZoneDistance(currentMapID, x, y, currentZoneMapID, currentNearest.position.x, currentNearest.position.y)
    -- print("currentDistance", currentDistance)
    self.Nearest[1] = currentNearest.name:match(TAXI_NAME_PATTERN)
    nearestTaxis[1] = currentNearest

    for i=2, #zoneTaxis do
      local taxi = zoneTaxis[i]
      local distance = HBD:GetZoneDistance(currentMapID, x, y, currentZoneMapID, taxi.position.x, taxi.position.y)
      -- print("distance", distance)
      -- If closer, wipe nearests and set to nearest
      if (distance < (currentDistance - THRESHOLD)) then -- wipe and add
        -- print("set current to", taxi.name)
        for k in pairs(self.Nearest) do self.Nearest[k] = nil end
        for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end
        self.Nearest[#self.Nearest+1] = taxi.name:match(TAXI_NAME_PATTERN)
        nearestTaxis[#nearestTaxis+1] = taxi
        currentDistance = distance
      elseif (distance < (currentDistance + THRESHOLD)) then -- add
        self.Nearest[#self.Nearest+1] = taxi.name:match(TAXI_NAME_PATTERN)
        nearestTaxis[#nearestTaxis+1] = taxi
      end
    end

    -- print("#nearestTaxis", #nearestTaxis)

    -- Add pins to map
    for _, taxi in pairs(nearestTaxis) do
      local pin = getPin()
      pin.name = taxi.name
      HBDPins:AddWorldMapIconMap(Addon, pin, currentMapID, taxi.position.x, taxi.position.y)
    end
  end
end

-- ============================================================================
-- Tooltip Hook
-- ============================================================================

do
  -- local FMW_ID = "774" -- Malachite ID, for debugging
  FMW_ID = "141605" -- Flight Master's Whistle Item ID
  local LEFT = format("|cFF98FB98%s:|r", AddonName)
  local buffer = {}

  local function concat(t)
    for k in pairs(buffer) do buffer[k] = nil end
    if (#t == 1) then return t[1] end
    for i=1, (#t - 1) do buffer[#buffer+1] = t[i]..", " end
    buffer[#buffer+1] = t[#t]
    return tconcat(buffer)
  end

  local function onTooltipSetItem(self)
    if not canUseWhistle or (#Core.Nearest == 0) then return end

    -- Verify the item is the Flight Master's Whistle
    local link = select(2, self:GetItem())
    if not link then return end
    local id = link:match("item:(%d+)")
    if not id or (id ~= FMW_ID) then return end
    
    self:AddLine(" ") -- Blank Line
    self:AddDoubleLine(LEFT, concat(Core.Nearest), nil, nil, nil, 1, 1, 1)
  end

  GameTooltip:HookScript("OnTooltipSetItem", onTooltipSetItem)
end
