local AddonName, Addon = ...

-- Libs
local HBD = LibStub("HereBeDragons-2.0")
local HBDPins = LibStub("HereBeDragons-Pins-2.0")

-- Upvalues
local format, next, pairs, print, tconcat =
      format, next, pairs, print, table.concat

local C_Map, C_TaxiMap, Enum = C_Map, C_TaxiMap, Enum
local WorldMapFrame, WorldMapTooltip = WorldMapFrame, WorldMapTooltip
local FlightPointDataProviderMixin = FlightPointDataProviderMixin
local IsIndoors, UnitFactionGroup = IsIndoors, UnitFactionGroup

-- Modules
local Core = DethsLibLoader("DethsAddonLib", "1.0"):Create(AddonName)

-- Consts
local PLAYER_FACTION_GROUP = nil
local TAXI_NODES = {}

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

-- local function debug(...) print(format("|cFF98FB98[%s]|r", AddonName), ...) end

-- ============================================================================
-- OnUpdate() and HBD Callback
-- ============================================================================

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

  -- Ignore nodes with these textureKitPrefix entries
  local TEXTURE_KIT_PREFIX_IGNORE = {
    FlightMaster_Ferry = true
  }

  -- HBD Callback
  HBD.RegisterCallback(AddonName, "PlayerZoneChanged", function(_, mapID)
    canUseWhistle = false

    if not mapID then return end
    currentMapID = mapID
    currentZoneMapID = mapID

    local mapInfo = C_Map.GetMapInfo(mapID)
    if not mapInfo then return end
    currentZoneMapName = mapInfo.name

    -- Update data based on current zone and continent
    while mapInfo.mapType and (mapInfo.mapType > Enum.UIMapType.Continent) do
      if (mapInfo.mapType == Enum.UIMapType.Zone) then
        currentZoneMapName = mapInfo.name
        currentZoneMapID = mapInfo.mapID
      end
      mapInfo = C_Map.GetMapInfo(mapInfo.parentMapID)
      if not mapInfo then return end
    end

    if (mapInfo.mapType ~= Enum.UIMapType.Continent) then return end
    canUseWhistle = WHISTLE_CONTINENTS[mapInfo.mapID]
    if not canUseWhistle then return end
    
    -- Update taxi data for current zone
    local taxiNodes = C_TaxiMap.GetTaxiNodesForMap(currentZoneMapID)
    if not taxiNodes or (#taxiNodes == 0) then canUseWhistle = false return end
    
    local factionGroup = UnitFactionGroup("PLAYER")
    for k in pairs(TAXI_NODES) do TAXI_NODES[k] = nil end

    for _, node in pairs(taxiNodes) do
      if FlightPointDataProviderMixin:ShouldShowTaxiNode(factionGroup, node) then
        if
          -- Only add nodes in the current zone
          node.name:find(currentZoneMapName, 1, true) and
          -- Ignore nodes with certain textureKitPrefix entries
          not TEXTURE_KIT_PREFIX_IGNORE[node.textureKitPrefix]
        then
          TAXI_NODES[#TAXI_NODES+1] = node
        end
      end
    end

    timer = DELAY -- update immediately
  end)
end

-- ============================================================================
-- Pin Pool
-- ============================================================================

local getPin, clearPins, hidePins do
  local FMW_TEXTURE_ID = 132161
  local pins = {}
  local pool = {}
  local count = 0

  local function onEnter(self)
    -- Show highlight
    self.highlight:SetAlpha(0.4)
    -- Show tooltip
    WorldMapTooltip:SetOwner(self, "ANCHOR_RIGHT")
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

  hidePins = function()
    for _, pin in pairs(pins) do pin:Hide() end
  end
end

-- ============================================================================
-- General Functions
-- ============================================================================

do -- UpdateTaxis()
  local THRESHOLD = 40 -- yards
  local last_x, last_y = -1, -1

  function Core:UpdateTaxis()
    if not whistleCanBeUsed() then
      for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end
      return
    end

    local x, y, mapID = HBD:GetPlayerZonePosition()
    if not (x and y and mapID) then return end

    -- Return if player hasn't moved
    if (last_x == x) and (last_y == y) then return end
    last_x, last_y = x, y

    -- Clear data
    for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end

    -- If no taxis, return
    if (#TAXI_NODES == 0) then return end

    -- Calculate nearest taxis
    local currentNearest = TAXI_NODES[1]
    local currentDistance = HBD:GetZoneDistance(currentMapID, x, y, currentZoneMapID, currentNearest.position.x, currentNearest.position.y)
    nearestTaxis[1] = currentNearest

    for i=2, #TAXI_NODES do
      local taxi = TAXI_NODES[i]
      local distance = HBD:GetZoneDistance(currentMapID, x, y, currentZoneMapID, taxi.position.x, taxi.position.y)
      -- If closer outside threshold
      if (distance <= (currentDistance - THRESHOLD)) then -- wipe and add
        for k in pairs(nearestTaxis) do nearestTaxis[k] = nil end
        nearestTaxis[#nearestTaxis+1] = taxi
        currentDistance = distance
      -- If within threshold
      elseif (distance <= (currentDistance + THRESHOLD)) then -- add
        nearestTaxis[#nearestTaxis+1] = taxi
      end
    end

    clearPins()
    pinsNeedUpdate = true
  end
end

function Core:UpdatePins()
  if not whistleCanBeUsed() then clearPins() return end
  if not WorldMapFrame:IsVisible() then hidePins() return end
  if not pinsNeedUpdate then return end
  pinsNeedUpdate = false

  -- Add pins to map
  for _, taxi in pairs(nearestTaxis) do
    HBDPins:AddWorldMapIconMap(
      Addon,
      getPin(taxi.name),
      currentZoneMapID,
      taxi.position.x,
      taxi.position.y
    )
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
