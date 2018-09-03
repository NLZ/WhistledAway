local AddonName, Addon = ...

-- Libs
local HBD = LibStub("HereBeDragons-2.0")
local HBDPins = LibStub("HereBeDragons-Pins-2.0")

-- Upvalues
local format, pairs, print, tconcat = format, pairs, print, table.concat

local C_Map, C_TaxiMap, Enum = C_Map, C_TaxiMap, Enum
local WorldMapFrame, WorldMapTooltip = WorldMapFrame, WorldMapTooltip
local FlightPointDataProviderMixin = FlightPointDataProviderMixin
local IsIndoors, UnitFactionGroup = IsIndoors, UnitFactionGroup

-- Modules
local Core = DethsLibLoader("DethsAddonLib", "1.0"):Create(AddonName)

-- Consts
local PLAYER_FACTION_GROUP = nil
local TAXI_NODES = {}

local WHISTLE_MAPS = {
  -- uiMapIDs for calls to C_TaxiMap.GetTaxiNodesForMap()
  [630] = true, -- Azsuna (Broken Isles)
  [885] = true, -- Antoran Wastes (Argus)
  [830] = true, -- Krokuun (Argus)
  [882] = true, -- Mac'Aree (Argus)
  [895] = true, -- Tiragarde Sound (Kul'tiras)
  [862] = true, -- Zuldazar (Zandalar)
}

local WHISTLE_MAPS_IGNORE = {
  [627] = true, -- Dalaran
}

local WHISTLE_CONTINENTS = {
  -- uiMapIDs for continents where the FMW can be used
  [619] = true, -- Broken Isles
  [905] = true, -- Argus
  [876] = true, -- Kul'tiras
  [875] = true, -- Zandalar
}

-- Variables
local currentMapID = -1     -- map where the player is, such as Boralus
local currentZoneMapID = -1 -- map of the actual zone, such as Tiragarde Sound
local currentZoneMapName = ""
local canUseWhistle = false
local pinsNeedUpdate = false
local nearestTaxis = {}

-- ============================================================================
-- Helper Functions
-- ============================================================================

local function whistleCanBeUsed()
  return canUseWhistle and not IsIndoors()
end

-- Debug
local function debug(...) print(format("|cFF98FB98[%s]|r", AddonName, ...)) end

-- ============================================================================
-- DAL Functions
-- ============================================================================

function Core:OnInitialize()
  PLAYER_FACTION_GROUP = UnitFactionGroup("PLAYER")
end

do -- OnUpdate()
  local DELAY = 1 -- seconds
  local timer = DELAY

  function Core:OnUpdate(elapsed)
    timer = timer + elapsed
    if (timer >= DELAY) then
      self:UpdateTaxis()
      timer = 0
    end
    self:UpdatePins()
  end

  -- HBD Callback
  HBD.RegisterCallback(AddonName, "PlayerZoneChanged", function(_, mapID)
    currentMapID = mapID
    currentZoneMapID = mapID

    local mapInfo = C_Map.GetMapInfo(mapID or 0)
    if mapInfo and mapInfo.name then
      currentZoneMapName = mapInfo.name

      -- Update data based on current zone and continent
      while mapInfo.mapType and (mapInfo.mapType > Enum.UIMapType.Continent) do
        if (mapInfo.mapType == Enum.UIMapType.Zone) then
          currentZoneMapName = mapInfo.name
          currentZoneMapID = mapInfo.mapID
        end
        mapInfo = C_Map.GetMapInfo(mapInfo.parentMapID)
      end

      if (mapInfo.mapType == Enum.UIMapType.Continent) then
        canUseWhistle = WHISTLE_CONTINENTS[mapInfo.mapID] and not WHISTLE_MAPS_IGNORE[currentMapID]
        if not canUseWhistle then return end
        -- Update taxi data for current map
        local taxiNodes = C_TaxiMap.GetTaxiNodesForMap(mapID)
        for _, taxiNodeInfo in pairs(taxiNodes) do
          if FlightPointDataProviderMixin:ShouldShowTaxiNode(PLAYER_FACTION_GROUP, taxiNodeInfo) then
            TAXI_NODES[taxiNodeInfo.name] = taxiNodeInfo
          end
        end
      end

      timer = DELAY -- update immediately
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

  getPin = function(name)
    local pin = next(pool)
    
    if pin then
      pool[pin] = nil
    else
      count = count + 1
      pin = CreateFrame("Button", AddonName.."Pin"..count, WorldMapFrame)
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

    pin.name = name
    pin:Show()
    return pin
  end

  clearPins = function()
    for _, pin in pairs(pins) do
      pin:Hide()
      pool[pin] = true
    end
    HBDPins:RemoveAllWorldMapIcons(Addon)
  end
end

-- ============================================================================
-- General Functions
-- ============================================================================

do -- UpdateTaxis()
  local THRESHOLD = 100 * 0.5 -- yards
  local lastX, lastY = -1, -1
  local zoneTaxis = {}

  function Core:UpdateTaxis()
    if not whistleCanBeUsed() then
      for k in pairs(zoneTaxis) do zoneTaxis[k] = nil end
      for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end
      return
    end

    local x, y, mapID = HBD:GetPlayerZonePosition()
    if not x then return end

    -- Return if player hasn't moved
    if (lastX == x) and (lastY == y) then return end
    lastX = x
    lastY = y

    -- Clear data
    for k in pairs(zoneTaxis) do zoneTaxis[k] = nil end
    for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end

    -- Get taxis in current zone
    for _, taxi in pairs(TAXI_NODES) do
      if (taxi.name:find(currentZoneMapName, 1, true)) then
        zoneTaxis[#zoneTaxis+1] = taxi
      end
    end

    -- If no taxis, return
    if (#zoneTaxis == 0) then return end

    -- Calculate nearest taxis
    local currentNearest = zoneTaxis[1]
    local currentDistance = HBD:GetZoneDistance(currentMapID, x, y, currentZoneMapID, currentNearest.position.x, currentNearest.position.y)
    nearestTaxis[1] = currentNearest

    for i=2, #zoneTaxis do
      local taxi = zoneTaxis[i]
      local distance = HBD:GetZoneDistance(currentMapID, x, y, currentZoneMapID, taxi.position.x, taxi.position.y)
      -- If closer, wipe nearests and set to nearest
      if (distance < (currentDistance - THRESHOLD)) then -- wipe and add
        for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end
        nearestTaxis[#nearestTaxis+1] = taxi
        currentDistance = distance
      elseif (distance < (currentDistance + THRESHOLD)) then -- add
        nearestTaxis[#nearestTaxis+1] = taxi
      end
    end

    clearPins()
    pinsNeedUpdate = true
  end
end

function Core:UpdatePins()
  if not whistleCanBeUsed() then clearPins() return end
  if not WorldMapFrame:IsVisible() or not pinsNeedUpdate then return end
  pinsNeedUpdate = false

  -- Add pins to map
  for _, taxi in pairs(nearestTaxis) do
    HBDPins:AddWorldMapIconMap(Addon, getPin(taxi.name), currentMapID, taxi.position.x, taxi.position.y)
  end
end

-- ============================================================================
-- Tooltip Hook
-- ============================================================================

do
  local FMW_ID = "141605" -- Flight Master's Whistle Item ID
  local LEFT = format("|cFF98FB98%s:|r", AddonName)
  local buffer = {}

  local function sortFunc(a, b) return a.name < b.name end

  -- "Tradewinds Market, Tiragarde Sound" -> "Tradewinds Market"
  local function getTaxiName(taxi)
    local name = taxi.name:match("(.+),")
    return name or taxi.name
  end

  local function getTaxiNames()
    if (#nearestTaxis == 1) then return getTaxiName(nearestTaxis[1]) end
    table.sort(nearestTaxis, sortFunc)
    for k in pairs(buffer) do buffer[k] = nil end
    for i=1, (#nearestTaxis - 1) do
      buffer[#buffer+1] = getTaxiName(nearestTaxis[i])..", "
    end
    buffer[#buffer+1] = getTaxiName(nearestTaxis[#nearestTaxis])
    return tconcat(buffer)
  end

  local function onTooltipSetItem(self)
    if not whistleCanBeUsed() or (#nearestTaxis == 0) then return end

    -- Verify the item is the Flight Master's Whistle
    local link = select(2, self:GetItem())
    if not link then return end
    local id = link:match("item:(%d+)")
    if not id or (id ~= FMW_ID) then return end
    
    self:AddLine(" ") -- Blank Line
    self:AddDoubleLine(LEFT, getTaxiNames(), nil, nil, nil, 1, 1, 1)
  end

  GameTooltip:HookScript("OnTooltipSetItem", onTooltipSetItem)
end
