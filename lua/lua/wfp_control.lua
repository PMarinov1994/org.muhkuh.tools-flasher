-- Create the configuration class.
local class = require 'pl.class'
local WfpControl = class()


function WfpControl:_init(tLogWriter)
  -- Get the LUA version number in the form major * 100 + minor .
  local strMaj, strMin = string.match(_VERSION, '^Lua (%d+)%.(%d+)$')
  if strMaj~=nil then
    self.LUA_VER_NUM = tonumber(strMaj) * 100 + tonumber(strMin)
  end

  -- The "penlight" module is used to parse the configuration file.
  self.pl = require'pl.import_into'()

  self.archive = require 'archive'

  -- lxp is used to parse the XML data.
  self.lxp = require 'lxp'

  -- Get the logger object from the system configuration.
  local tLogWriter = require 'log.writer.prefix'.new('[WfpControl] ', tLogWriter)
  self.tLog = require 'log'.new(
    'trace',
    tLogWriter,
    require 'log.formatter.format'.new()
  )

  -- Save the complete source to be able to reproduce the file.
  self.strSource = nil

  -- There are no targets yet.
  self.atTargets = nil

  -- The file name of the WFP archive.
  self.strWfpArchiveFile = nil
  -- The file name of the control file in the WFP archive.
  self.strWfpControlFile = nil

  -- This is the open archive.
  self.tArchive = nil

  -- This is the list of conditions from the parsed XML.
  self.atConditions = nil

  -- Map chip type to the name.
  self.atChiptyp2name = {
    [romloader.ROMLOADER_CHIPTYP_NETX500]          = "NETX500",
    [romloader.ROMLOADER_CHIPTYP_NETX100]          = "NETX500",
    [romloader.ROMLOADER_CHIPTYP_NETX50]           = "NETX50",
    [romloader.ROMLOADER_CHIPTYP_NETX10]           = "NETX10",
    [romloader.ROMLOADER_CHIPTYP_NETX56]           = "NETX56",
    [romloader.ROMLOADER_CHIPTYP_NETX56B]          = "NETX56",
    [romloader.ROMLOADER_CHIPTYP_NETX4000_RELAXED] = "NETX4000_RELAXED",
    [romloader.ROMLOADER_CHIPTYP_NETX4000_FULL]    = "NETX4000",
    [romloader.ROMLOADER_CHIPTYP_NETX4100_SMALL]   = "NETX4000",
    [romloader.ROMLOADER_CHIPTYP_NETX90_MPW]       = "NETX90_MPW",
    [romloader.ROMLOADER_CHIPTYP_NETX90]           = "NETX90",
    [romloader.ROMLOADER_CHIPTYP_NETX90B]          = "NETX90",
    [romloader.ROMLOADER_CHIPTYP_NETIOLA]          = "NETIOL",
    [romloader.ROMLOADER_CHIPTYP_NETIOLB]          = "NETIOL",
    [romloader.ROMLOADER_CHIPTYP_NETX90C]          = "NETX90",
    [romloader.ROMLOADER_CHIPTYP_NETX90D]          = "NETX90"
  }
end



function WfpControl:__search_archive_contents(strEntry)
  -- The archive has not been read from the start yet.
  local fFromStart = false

  -- No matching entry found yet.
  local tEntry = nil

  local tLog = self.tLog

  tLog.debug('Search entry "%s" in WFP archive "%s".', strEntry, self.strWfpArchiveFile)

  repeat do
    -- If the archive is not open yet, open it now.
    local tArchive = self.tArchive
    if tArchive==nil then
      tLog.debug('Open WFP archive "%s".', self.strWfpArchiveFile)

      -- Create a new reader which supports all formats and filters.
      tArchive = self.archive.ArchiveRead()
      tArchive:support_filter_all()
      tArchive:support_format_all()

      local r = tArchive:open_filename(self.strWfpArchiveFile, 16384)
      if r==0 then
        self.tArchive = tArchive
      else
        tLog.error('Failed to open archive "%s": %s', self.strWfpArchiveFile, tArchive:error_string())
        tArchive:close()
        break
      end

      -- Now the archive is read from the start.
      fFromStart = true
    end

    for tEntryCnt in tArchive:iter_header() do
      if tEntryCnt:pathname()==strEntry then
        tLog.debug('Found entry "%s"', strEntry)
        tEntry = tEntryCnt
        break
      else
        tLog.debug('Passing entry "%s"', tEntryCnt:pathname())
        tArchive:data_skip()
      end
    end

    if tEntry~=nil then
      -- Found the entry.
      break
    end

    -- Nothing found yet.

    -- Close the archive.
    tLog.debug('Closing archive "%s".', self.strWfpArchiveFile)
    tArchive:close()
    self.tArchive = nil
  end until fFromStart==true

  return tEntry
end



function WfpControl:__get_file_contents(tEntry)
  local tFileData = {}
  for strData in self.tArchive:iter_data(16384) do
    table.insert(tFileData, strData)
  end
  return table.concat(tFileData)
end



function WfpControl:getData(strFile)
  local strData
  local tLog = self.tLog
  local tData = self:__search_archive_contents(strFile)
  if tData==nil then
    tLog.error('Data file "%s" not found in the WFP archive "%s"!', strFile, self.strWfpArchiveFile)
  else
    strData = self:__get_file_contents(tData)
  end

  return strData
end



local atStringToBool = {
  ["TRUE"]  = true,
  ["FALSE"] = false,
  ["T"]     = true,
  ["F"]     = false,
  ["YES"]   = true,
  ["NO"]    = false,
  ["Y"]     = true,
  ["N"]     = false,
  ["1"]     = true, 
  ["0"]     = false
}

--- Map a string value to a boolean value. 
-- Accepts a variety of inputs:
-- true/false, t/f, yes/no, y/n, 1/0 independent of case.
-- see hboot_image.py __string_to_bool
-- @param strBool the string to be mapped to a boolean value.
-- @return boolean value true, false or nil.
local function stringToBool(strBool)
  strBool = string.upper(strBool)
  return atStringToBool[strBool]
end 

--- Expat callback function for starting an element.
-- This function is part of the callbacks for the expat parser.
-- It is called when a new element is opened.
-- @param tParser The parser object.
-- @param strName The name of the new element.
function WfpControl.__parseCfg_StartElement(tParser, strName, atAttributes)
  local aLxpAttr = tParser:getcallbacks().userdata
  local iPosLine, iPosColumn, iPosAbs = tParser:pos()

  table.insert(aLxpAttr.atCurrentPath, strName)
  local strCurrentPath = table.concat(aLxpAttr.atCurrentPath, "/")
  aLxpAttr.strCurrentPath = strCurrentPath

  if strCurrentPath=='/FlasherPackage' then
    local strVersion = atAttributes['version']
    local strHasSubdirs = atAttributes['has_subdirs']
    if strVersion==nil or strVersion=='' then
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: missing attribute "version".', iPosLine, iPosColumn)
    else
      local tVersion = aLxpAttr.Version()
      local tResult, strError = tVersion:set(strVersion)
      if tResult~=true then
        aLxpAttr.tResult = nil
        aLxpAttr.tLog.error('Error in line %d, col %d: invalid "version": %s', iPosLine, iPosColumn, strError)
      end
      aLxpAttr.tVersion = tVersion

      -- Reject the control file if the version is >= 1.4
      local tVersion_1_4 = aLxpAttr.Version()
      tVersion_1_4:set("1.4")
      if aLxpAttr.Version.compare(tVersion_1_4, tVersion) <= 0 then 
        aLxpAttr.tResult = nil
        aLxpAttr.tLog.error('Error in line %d, col %d: Control file version %s is not supported', iPosLine, iPosColumn, strVersion)
      end

      -- Print a warning if the version is < 1.2 but the has_subdirs attribute is used
      local tVersion_1_2 = aLxpAttr.Version()
      tVersion_1_2:set("1.2")
      if strHasSubdirs~=nil and aLxpAttr.Version.compare(tVersion, tVersion_1_2) < 0 then 
        aLxpAttr.tLog.warning('Warning (line %d, col %d): Control file has version < 1.2 but contains has_subdirs attribute', iPosLine, iPosColumn)
      end 
      
      -- Evaluate the value of has_subdirs to a boolean value.
      -- Default is false if has_subdirs is not present.
      local fHasSubdirs 
      if strHasSubdirs == nil then
        fHasSubdirs = false 
      else 
        fHasSubdirs = stringToBool(strHasSubdirs)
        if fHasSubdirs==nil then
          aLxpAttr.tResult = nil
          aLxpAttr.tLog.error('Error in line %d, col %d: Attribute has_subdirs has illegal value', iPosLine, iPosColumn)
        end
      end
      aLxpAttr.fHasSubdirs = fHasSubdirs
      
    end

  elseif strCurrentPath=='/FlasherPackage/Conditions/Condition' then
    -- The attribute "name" is required.
    local strName = atAttributes['name']
    if strName==nil or strName=='' then
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: missing attribute "name".', iPosLine, iPosColumn)
    else
      -- The attribute "default" is optional.
      local strDefault = atAttributes['default']
      -- The attribute "test" is optional. If set, it must be "none", "list" or "re".
      local strTest = atAttributes['test']
      -- The default is "none".
      if strTest==nil or strTest=='' then
        strTest = 'none'
      end
      if strTest~='none' and strTest~='list' and strTest~='re' then
        aLxpAttr.tResult = nil
        aLxpAttr.tLog.error('Error in line %d, col %d: invalid attribute "test", must be "none", "list" or "re".', iPosLine, iPosColumn)
      else
        aLxpAttr.tCondition = { name=strName, default=strDefault, test=strTest }
      end
    end

  elseif strCurrentPath=='/FlasherPackage/Target' then
    local strNetx = atAttributes['netx']
    if strNetx==nil or strNetx=='' then
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: missing attribute "netx".', iPosLine, iPosColumn)
    else
      local tTarget = {}
      tTarget.netX = strNetx
      tTarget.atFlashes = {}
      aLxpAttr.tCurrentTarget = tTarget
    end

  elseif strCurrentPath=='/FlasherPackage/Target/Flash' then
    local strBus = atAttributes['bus']
    if strBus==nil or strBus=='' then
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: missing attribute "bus".', iPosLine, iPosColumn)
    end

    local ulUnit
    local strUnit = atAttributes['unit']
    if strUnit==nil or strUnit=='' then
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: missing attribute "unit".', iPosLine, iPosColumn)
    else
      ulUnit = tonumber(strUnit)
      if ulUnit==nil then
        aLxpAttr.tResult = nil
        aLxpAttr.tLog.error('Error in line %d, col %d: attribute "unit" is no number: "%s".', iPosLine, iPosColumn, strUnit)
      end
    end

    local ulChipSelect
    local strChipSelect = atAttributes['chip_select']
    if strChipSelect==nil or strChipSelect=='' then
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: missing attribute "chip_select".', iPosLine, iPosColumn)
    else
      ulChipSelect = tonumber(strChipSelect)
      if ulChipSelect==nil then
        aLxpAttr.tResult = nil
        aLxpAttr.tLog.error('Error in line %d, col %d: attribute "chip_select" is no number: "%s".', iPosLine, iPosColumn, strChipSelect)
      end
    end

    local tFlash = {}
    tFlash.strBus = strBus
    tFlash.ulUnit = ulUnit
    tFlash.ulChipSelect = ulChipSelect
    tFlash.tRequirements = nil
    tFlash.atData = {}

    aLxpAttr.tCurrentFlash = tFlash

  elseif strCurrentPath=='/FlasherPackage/Target/Flash/Requirements' then
    if aLxpAttr.tCurrentTarget.tRequirements~=nil then
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: more than one "Requirements" node found. Only one is allowed.')
    else
      local strMinimumSize = atAttributes['minimum_size']
      if strMinimumSize==nil or strMinimumSize=='' then
        -- No minimum size specified.
      else
        local ulMinimumSize = tonumber(strMinimumSize)
        if ulMinimumSize==nil then
          aLxpAttr.tResult = nil
          aLxpAttr.tLog.error('Error in line %d, col %d: attribute "minimum_size" is no number: "%s".', iPosLine, iPosColumn, strMinimumSize)
        end
      end

      local strBlockSize = atAttributes['block_size']
      if strBlockSize==nil or strBlockSize=='' then
        -- No block size specified.
      else
        local ulBlockSize = tonumber(strBlockSize)
        if ulBlockSize==nil then
          aLxpAttr.tResult = nil
          aLxpAttr.tLog.error('Error in line %d, col %d: attribute "block_size" is no number: "%s".', iPosLine, iPosColumn, strBlockSize)
        end
      end

      local tRequirements = {}
      tRequirements.ulMinimumSize = ulMinimumSize
      tRequirements.ulBlockSize = ulBlockSize

      aLxpAttr.tCurrentFlash.tRequirements = tRequirements
    end

  elseif strCurrentPath=='/FlasherPackage/Target/Flash/Data' then
    local strFile = atAttributes['file']
    if strFile==nil or strFile=='' then
      -- No file name specified.
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: attribute "file" is not set.', iPosLine, iPosColumn)
    else
      local strOffset = atAttributes['offset']
      if strOffset==nil or strOffset=='' then
        strOffset = '0'
      end
      local ulOffset = tonumber(strOffset)
      if ulOffset==nil then
        aLxpAttr.tResult = nil
        aLxpAttr.tLog.error('Error in line %d, col %d: attribute "offset" is no number: "%s".', iPosLine, iPosColumn, strOffset)
      end
      local strSize = atAttributes["size"]
      local ulSize
      if strSize == nil or strSize == "" then
          -- No size specified.
          -- aLxpAttr.tResult = nil
          --aLxpAttr.tLog.error('Error in line %d, col %d: attribute "size" is not set.', iPosLine, iPosColumn)
      else
          ulSize = tonumber(strSize)
        
      end
      local strCondition = atAttributes['condition']
      if strCondition==nil then
        strCondition = ''
      end

      local tData = {}
      tData.strType = "Data"
      tData.strFile = strFile
      tData.ulSize = ulSize
      tData.ulOffset = ulOffset
      tData.strCondition = strCondition

      table.insert(aLxpAttr.tCurrentFlash.atData, tData)
    end

  elseif strCurrentPath=='/FlasherPackage/Target/Flash/Erase' then
    local strOffset = atAttributes['offset']
    if strOffset==nil or strOffset=='' then
      -- No offset specified.
      aLxpAttr.tResult = nil
      aLxpAttr.tLog.error('Error in line %d, col %d: attribute "offset" is not set.', iPosLine, iPosColumn)
    else
      local ulOffset = tonumber(strOffset)
      if ulOffset==nil then
        aLxpAttr.tResult = nil
        aLxpAttr.tLog.error('Error in line %d, col %d: attribute "offset" is no number: "%s".', iPosLine, iPosColumn, strOffset)
      else
        local strSize = atAttributes['size']
        if strSize==nil or strSize=='' then
          -- No size specified.
          aLxpAttr.tResult = nil
          aLxpAttr.tLog.error('Error in line %d, col %d: attribute "size" is not set.', iPosLine, iPosColumn)
        else
          local ulSize = tonumber(strSize)
          if ulSize==nil then
            aLxpAttr.tResult = nil
            aLxpAttr.tLog.error('Error in line %d, col %d: attribute "size" is no number: "%s".', iPosLine, iPosColumn, strSize)
          else
            local strCondition = atAttributes['condition']
            if strCondition==nil then
              strCondition = ''
            end

            local tErase = {}
            tErase.strType = "Erase"
            tErase.ulSize = ulSize
            tErase.ulOffset = ulOffset
            tErase.strCondition = strCondition

            table.insert(aLxpAttr.tCurrentFlash.atData, tErase)
          end
        end
      end
    end
  end

end



--- Expat callback function for closing an element.
-- This function is part of the callbacks for the expat parser.
-- It is called when an element is closed.
-- @param tParser The parser object.
-- @param strName The name of the closed element.
function WfpControl.__parseCfg_EndElement(tParser, strName)
  local aLxpAttr = tParser:getcallbacks().userdata
  local iPosLine, iPosColumn, iPosAbs = tParser:pos()

  local strCurrentPath = aLxpAttr.strCurrentPath
  if strCurrentPath=='/FlasherPackage/Conditions/Condition' then
    table.insert(aLxpAttr.atConditions, aLxpAttr.tCondition)
    aLxpAttr.tCondition = nil

  elseif strCurrentPath=='/FlasherPackage/Target' then
    local strNetx = aLxpAttr.tCurrentTarget.netX
    -- Does the target already exist?
    if aLxpAttr.atTargets[strNetx]==nil then
      -- No -> create the new target.
      aLxpAttr.atTargets[strNetx] = aLxpAttr.tCurrentTarget
    else
      -- Append all flash entries.
      aLxpAttr.pl.tablex(aLxpAttr.atTargets[strNetx].atFlashes, aLxpAttr.tCurrentTarget.atFlashes)
    end
    aLxpAttr.tCurrentTarget = nil

  elseif strCurrentPath=='/FlasherPackage/Target/Flash' then
    table.insert(aLxpAttr.tCurrentTarget.atFlashes, aLxpAttr.tCurrentFlash)
    aLxpAttr.tCurrentFlash = nil
  end

  table.remove(aLxpAttr.atCurrentPath)
  aLxpAttr.strCurrentPath = table.concat(aLxpAttr.atCurrentPath, "/")
end



--- Expat callback function for character data.
-- This function is part of the callbacks for the expat parser.
-- It is called when character data is parsed.
-- @param tParser The parser object.
-- @param strData The character data.
function WfpControl.__parseCfg_CharacterData(tParser, strData)
  local aLxpAttr = tParser:getcallbacks().userdata
  local pl = aLxpAttr.pl

  if aLxpAttr.strCurrentPath=="/FlasherPackage/Conditions/Condition" then
    local tData = strData
    local tCondition = aLxpAttr.tCondition
    if tCondition.test=='list' then
      tData = pl.tablex.imap(pl.stringx.strip, pl.stringx.split(strData, ','))
    end
    aLxpAttr.tCondition.constraints = tData
  end
end



function WfpControl:__parse_configuration(strConfiguration)
  local tResult = nil


  -- Save the complete source and the source URL.
  self.strSource = strConfiguration

  local aLxpAttr = {
    -- Start at root ("/").
    atCurrentPath = {""},
    strCurrentPath = nil,

    Version = require 'Version',
    tCurrentTarget = nil,
    tCurrentFlash = nil,

    tVersion = nil,
    tCondition = nil,
    atTargets = {},
    atConditions = {},

    tResult = true,
    tLog = self.tLog,
    pl = self.pl
  }

  local aLxpCallbacks = {}
  aLxpCallbacks._nonstrict    = false
  aLxpCallbacks.StartElement  = self.__parseCfg_StartElement
  aLxpCallbacks.EndElement    = self.__parseCfg_EndElement
  aLxpCallbacks.CharacterData = self.__parseCfg_CharacterData
  aLxpCallbacks.userdata      = aLxpAttr

  local tParser = self.lxp.new(aLxpCallbacks)

  local tParseResult, strMsg, uiLine, uiCol, uiPos = tParser:parse(strConfiguration)
  if tParseResult~=nil then
    tParseResult, strMsg, uiLine, uiCol, uiPos = tParser:parse()
    if tParseResult~=nil then
      tParser:close()
    end
  end

  if tParseResult==nil then
    self.tLog.error('Failed to parse the configuration: %s in line %d, column %d, position %d.', strMsg, uiLine, uiCol, uiPos)
  elseif aLxpAttr.tResult~=true then
    self.tLog.error('Failed to parse the configuration.')
  else
    self.tConfigurationVersion = aLxpCallbacks.userdata.tVersion
    self.atConfigurationTargets = aLxpCallbacks.userdata.atTargets
    self.atConditions = aLxpCallbacks.userdata.atConditions
    self.fHasSubdirs = aLxpCallbacks.userdata.fHasSubdirs

    -- Check if all required components are present.
    -- NOTE: the dependency block is optional.
    if self.tConfigurationVersion==nil then
      self.tLog.error('Failed to parse the configuration: No version found!')
    elseif self.atConfigurationTargets==nil then
      self.tLog.error('Failed to parse the configuration: No targets found!')
    else
      tResult = true
    end
  end

  return tResult
end



function WfpControl:open(strWfpArchiveFile, strWfpControlFile)
  strWfpControlFile = strWfpControlFile or 'wfp.xml'

  local tResult
  local tLog = self.tLog

  self.strWfpArchiveFile = strWfpArchiveFile
  self.strWfpControlFile = strWfpControlFile

  -- Does the archive exist?
  if self.pl.path.exists(strWfpArchiveFile)~=strWfpArchiveFile then
    tLog.error('The WFP archive "%s" does not exist.', strWfpArchiveFile)
  else
    -- Read the control file from the WFP archive.
    tLog.debug('Reading control file "%s" from the WFP archive.', strWfpControlFile)
    local strData = self:getData(strWfpControlFile)
    if strData==nil then
      tLog.error('Control file "%s" not found in the archive "%s"!', strWfpControlFile, strWfpArchiveFile)
    else
      -- Parse the XML file.
      tResult = self:__parse_configuration(strData)
    end
  end

  return tResult
end



function WfpControl:openXml(strWfpControlFile)
  local tResult
  local tLog = self.tLog

  -- Does the control file exist?
  if self.pl.path.exists(strWfpControlFile)~=strWfpControlFile then
    tLog.error('The WFP control file "%s" does not exist.', strWfpControlFile)
  else
    -- Read the control file from the WFP archive.
    tLog.debug('Reading control file "%s".', strWfpControlFile)
    local strData, strError = self.pl.utils.readfile(strWfpControlFile, false)
    if strData==nil then
      tLog.error('Failed to read the control file "%s" not found: %s', strWfpControlFile, strError)
    else
      -- Parse the XML file.
      tResult = self:__parse_configuration(strData)
    end
  end

  return tResult
end



function WfpControl:getTarget(iChiptype)
  local tTarget
  local tLog = self.tLog
  if self.atConfigurationTargets~=nil then
    local strChipType = self.atChiptyp2name[iChiptype]
    if strChipType==nil then
      tLog.error('Unknown chip type: %s', tostring(iChiptype))
    else
      tLog.debug('Selecting files for chip type %s.', strChipType)
      tTarget = self.atConfigurationTargets[strChipType]
    end
  end
  return tTarget
end



function WfpControl:__runInSandbox(atValues, strExpression)
  local tResult
  local tLog = self.tLog
  local pl = self.pl

  -- Create a sandbox.
  local atEnv = {
    ['error']=error,
    ['ipairs']=ipairs,
    ['next']=next,
    ['pairs']=pairs,
    ['print']=print,
    ['select']=select,
    ['tonumber']=tonumber,
    ['tostring']=tostring,
    ['type']=type,
    ['math']=math,
    ['string']=string,
    ['table']=table
  }
  for strKey, tValue in pairs(atValues) do
    local strValue
    local strType = type(tValue)
    if strType~='number' and strType~='boolean' and strType~='string' then
      error(string.format('Invalid value type for key %s: %s', strKey, strType))
    end
    atEnv[strKey] = tValue
  end
  local strCode = string.format('return %s', strExpression)
  local tFn, strError = pl.compat.load(strCode, 'condition code', 't', atEnv)
  if tFn==nil then
    error(string.format('Invalid expression "%s": %s', strExpression, tostring(strError)))
  end
  local fRun, tFnResult = pcall(tFn)
  if fRun==false then
    error(string.format('Failed to run the expression "%s": %s', strExpression, tostring(tResult)))
  end
  local strType = type(tFnResult)
  if strType~='boolean' then
    error(string.format('Invalid condition return type for expression "%s": %s', strExpression, strType))
  end
  tResult = tFnResult

  return tResult
end



function WfpControl:matchCondition(atData, strCondition)
  local tResult = true
  local tLog = self.tLog
  -- Does a condition exist?
  if string.len(strCondition)==0 then
    tLog.debug('Condition check: no condition -> true')
  else
    -- Evaluate the condition in a sandbox.
    tResult = self:__runInSandbox(atData, strCondition)
    tLog.debug('Condition check: "%s" -> %s', strCondition, tostring(tResult))
  end
  return tResult
end



function WfpControl:getConditions()
  return self.atConditions
end

--- Get the value of has_subdirs.
-- @return a boolean value
function WfpControl:getHasSubdirs()
  return self.fHasSubdirs
end
--- Get the value of tVersion.
-- @return a version
function WfpControl:getVersion()
  
  return self.tConfigurationVersion
end

function WfpControl:validateCondition(strKey, strValue)
  local tResult
  local strError
  local atConditions = self.atConditions

  -- Search the condition in the list.
  local tHit
  for _, tCondition in ipairs(atConditions) do
    if tCondition.name==strKey then
      tHit = tCondition
      break
    end
  end
  if tHit==nil then
    -- No condition -> always ok.
    tResult = true
  else
    local strTest = tHit.test
    if strTest=='none' then
      -- No test -> always ok.
      tResult = true
    elseif strTest=='list' then
      local atList = tHit.constraints
      for _, strElement in ipairs(atList) do
        if strElement==strValue then
          tResult = true
          break
        end
      end
      if tResult~=true then
        tResult = false
        strError = string.format('"%s" is not part of the list %s', strValue, table.concat(atList, ','))
      end
    elseif strTest=='re' then
      local strRe = tHit.constraints
      local tMatch = string.match(strValue, strRe)
      if tMatch==nil then
        tResult = false
        strError = string.format('"%s" does not match the regular expression %s', strValue, strRe)
      else
        tResult = true
      end
    else
      -- Unknown test always fails.
      tResult = false
    end
  end

  return tResult, strError
end


return WfpControl
