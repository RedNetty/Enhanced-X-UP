local api = require("api")
local enhanced_x_up = {
    name = "Enhanced X UP",
    version = "1.1",
    author = "Yuck",
    desc = "Raid recruitment with player blacklist."
}

-- CONSTANTS


local MSG_PREFIX_RECRUIT = "[Recruit] "
local MSG_PREFIX_BLACKLIST = "[Blacklist] "

local FILTER_EQUALS = 1
local FILTER_CONTAINS = 2
local FILTER_STARTS_WITH = 3

local CHAT_ALL = 1
local CHAT_WHISPERS = 2
local CHAT_GUILD = 3

local CHANNEL_WHISPER = -3
local CHANNEL_GUILD = 7

local NAME_CACHE_MAX_SIZE = 1000


-- STATE VARIABLES


local state = {
    blocklist = {},
    recruit_message = "",
    is_recruiting = false,
    canvas_width = 0,
    event_handler = nil  -- Store the event handler reference
}

-- Widget references
local widgets = {
    recruit_button = nil,
    recruit_textfield = nil,
    filter_dropdown = nil,
    dms_only = nil,
    blacklist_button = nil,
    recruit_canvas = nil,
    cancel_button = nil,
    raid_manager = nil,
    blacklist_window = nil,
    blacklist_input = nil,
    blacklist_listbox = nil
}

-- Cache for lowercase names to avoid repeated string.lower() calls
local name_cache = {}
local name_cache_size = 0


-- UTILITY FUNCTIONS


local function GetLowerName(name)
    local cached = name_cache[name]
    if cached then
        return cached
    end

    if name_cache_size >= NAME_CACHE_MAX_SIZE then
        ClearNameCache()
    end

    local lower = string.lower(name)
    name_cache[name] = lower
    name_cache_size = name_cache_size + 1
    return lower
end

local function ClearNameCache()
    name_cache = {}
    name_cache_size = 0
end

local function LogInfo(message)
    api.Log:Info(message)
end

local function LogError(message)
    api.Log:Err(message)
end


-- BLACKLIST CORE FUNCTIONS


local function SaveBlocklist()
    local settings = api.GetSettings("enhanced_x_up")
    settings.blocklist = state.blocklist
    api.SaveSettings()

    if #state.blocklist > 0 then
        api.File:Write("enhanced_x_up/blacklist.lua", state.blocklist)
    end
end

local function IsBlacklisted(name)
    local lower_name = GetLowerName(name)
    local blocklist = state.blocklist

    for i = 1, #blocklist do
        if GetLowerName(blocklist[i]) == lower_name then
            return true
        end
    end
    return false
end

local function AddToBlocklist(name)
    if IsBlacklisted(name) then
        return false, name .. " is already blacklisted."
    end

    state.blocklist[#state.blocklist + 1] = name
    SaveBlocklist()
    return true, "Added player: " .. name
end

local function RemoveFromBlocklist(name)
    local lower_name = GetLowerName(name)
    local blocklist = state.blocklist

    for i = #blocklist, 1, -1 do
        if GetLowerName(blocklist[i]) == lower_name then
            table.remove(blocklist, i)
            SaveBlocklist()
            ClearNameCache()
            return true, "Removed: " .. name
        end
    end
    return false, "Entry not found: " .. name
end

local function ClearBlocklist()
    if #state.blocklist == 0 then
        return false, "List is already empty."
    end

    state.blocklist = {}
    SaveBlocklist()
    ClearNameCache()
    return true, "All entries cleared."
end

local function DestroyWidgetList(widget_list)
    if not widget_list then return end

    for i = 1, #widget_list do
        if widget_list[i].label then
            widget_list[i].label:ReleaseHandler("all")
            widget_list[i].label:Show(false)
        end
        if widget_list[i].button then
            widget_list[i].button:ReleaseHandler("all")
            widget_list[i].button:Show(false)
        end
    end
end

local function UpdateBlacklistDisplay()
    local frame = widgets.blacklist_listbox
    if not frame then return end

    DestroyWidgetList(frame.player_widgets)
    frame.player_widgets = {}

    local blocklist = state.blocklist
    local count = #blocklist

    if count == 0 then
        -- Show "no entries" message
        local empty_label = frame:CreateChildWidget("label", "empty_msg", 0, true)
        empty_label:SetText("(No entries)")
        empty_label:SetExtent(380, 20)
        empty_label:AddAnchor("TOPLEFT", frame, 0, 0)
        empty_label:Show(true)
        frame.player_widgets[1] = {label = empty_label}
        return
    end

    -- Create label + button for each player (max 5 visible to fit in window), eventually gonna change this.
    local visible_count = math.min(count, 5)
    for i = 1, visible_count do
        local y_offset = (i - 1) * 35

        -- Player name label
        local name_label = frame:CreateChildWidget("label", "player_" .. i, 0, true)
        name_label:SetText(blocklist[i])
        name_label:SetExtent(240, 25)
        name_label:AddAnchor("TOPLEFT", frame, 5, y_offset + 5)
        name_label:Show(true)

        -- Remove button
        local remove_btn = frame:CreateChildWidget("button", "remove_" .. i, 0, true)
        remove_btn:SetText("Remove")
        remove_btn:SetExtent(80, 25)
        remove_btn:AddAnchor("LEFT", name_label, "RIGHT", 10, 0)
        api.Interface:ApplyButtonSkin(remove_btn, BUTTON_BASIC.DEFAULT)

        -- Store the player name for removal
        remove_btn.playerName = blocklist[i]
        remove_btn:SetHandler("OnClick", function(self)
            local success, message = RemoveFromBlocklist(self.playerName)
            if success then
                UpdateBlacklistDisplay()
                LogInfo(MSG_PREFIX_BLACKLIST .. message)
            else
                LogError(MSG_PREFIX_BLACKLIST .. message)
            end
        end)
        remove_btn:Show(true)

        frame.player_widgets[i] = {label = name_label, button = remove_btn}
    end

    -- Show count if more than 5 entries
    if count > 5 then
        local more_label = frame:CreateChildWidget("label", "more_msg", 0, true)
        more_label:SetText("... and " .. (count - 5) .. " more (use Export/Import)")
        more_label:SetExtent(380, 20)
        more_label:AddAnchor("TOPLEFT", frame, 5, 175)
        more_label:Show(true)
        frame.player_widgets[visible_count + 1] = {label = more_label}
    end
end


-- IMPORT/EXPORT FUNCTIONS


local function ImportBlocklist()
    local imported_list = api.File:Read("enhanced_x_up/blacklist.lua")
    if not imported_list or type(imported_list) ~= "table" then
        return false, "Import failed. File not found or invalid."
    end

    local added_count = 0
    local blocklist = state.blocklist

    for i = 1, #imported_list do
        local entry = imported_list[i]
        if not IsBlacklisted(entry) then
            blocklist[#blocklist + 1] = entry
            added_count = added_count + 1
        end
    end

    if added_count > 0 then
        SaveBlocklist()
        ClearNameCache()
    end

    return true, "Imported " .. added_count .. " new entries."
end

local function ExportBlocklist()
    if #state.blocklist == 0 then
        return false, "Nothing to export."
    end

    api.File:Write("enhanced_x_up/blacklist.lua", state.blocklist)
    return true, "Exported " .. #state.blocklist .. " entries to enhanced_x_up/blacklist.lua"
end


-- RECRUITMENT FUNCTIONS


local function StartRecruiting()
    local message_text = widgets.recruit_textfield:GetText()
    if message_text == "" then
        LogError(MSG_PREFIX_RECRUIT .. "Please enter a recruitment message.")
        return
    end

    state.recruit_message = GetLowerName(message_text)
    state.is_recruiting = true

    widgets.recruit_canvas:Show(true)
    widgets.recruit_button:SetText("Recruiting...")
    widgets.recruit_button:Enable(false)
    widgets.recruit_textfield:Enable(false)
    widgets.filter_dropdown:Enable(false)
    widgets.dms_only:Enable(false)

    LogInfo(MSG_PREFIX_RECRUIT .. "Started recruiting. Message: '" .. message_text .. "'")
end

local function StopRecruiting()
    state.is_recruiting = false
    state.recruit_message = ""

    widgets.recruit_canvas:Show(false)
    widgets.recruit_button:SetText("Start Recruiting")
    widgets.recruit_button:Enable(true)
    widgets.recruit_textfield:Enable(true)
    widgets.filter_dropdown:Enable(true)
    widgets.dms_only:Enable(true)

    LogInfo(MSG_PREFIX_RECRUIT .. "Stopped recruiting.")
end

local function ToggleRecruiting()
    if state.is_recruiting then
        StopRecruiting()
    else
        StartRecruiting()
    end
end


-- BLACKLIST WINDOW UI


local function CreateBlacklistWindow()
    local window = api.Interface:CreateEmptyWindow("blacklistWindow")
    window:SetExtent(420, 450)
    window:AddAnchor("CENTER", "UIParent", 0, 0)
    window:SetTitle("Player Blacklist")
    window:Show(false)
    widgets.blacklist_window = window

    -- Background
    local bg = window:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
    bg:SetTextureInfo("bg_quest")
    bg:SetColor(0, 0, 0, 0.8)
    bg:AddAnchor("TOPLEFT", window, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", window, 0, 0)

    -- Title bar
    local title = window:CreateChildWidget("label", "title", 0, true)
    title:SetExtent(400, 30)
    title:AddAnchor("TOP", window, 0, 10)
    title:SetText("Player Blacklist Manager")
    title:SetAlign(ALIGN.CENTER)
    ApplyTextColor(title, FONT_COLOR.TITLE)
    title:Show(true)

    -- Close button
    local close_button = window:CreateChildWidget("button", "close_button", 0, true)
    close_button:SetText("X")
    close_button:SetExtent(30, 30)
    close_button:AddAnchor("TOPRIGHT", window, -10, 10)
    api.Interface:ApplyButtonSkin(close_button, BUTTON_BASIC.DEFAULT)
    close_button:SetHandler("OnClick", function()
        window:Show(false)
    end)

    -- Input section
    local input_label = window:CreateChildWidget("label", "input_label", 0, true)
    input_label:SetExtent(400, 20)
    input_label:AddAnchor("TOPLEFT", window, 20, 50)
    input_label:SetText("Add Player to Blacklist:")
    input_label:Show(true)

    local input_field = W_CTRL.CreateEdit("blacklist_input", window)
    input_field:SetExtent(250, 30)
    input_field:AddAnchor("TOPLEFT", window, 20, 75)
    input_field:SetMaxTextLength(32)
    input_field:CreateGuideText("Player Name")
    input_field:Show(true)
    widgets.blacklist_input = input_field

    local add_button = window:CreateChildWidget("button", "add_button", 0, true)
    add_button:SetText("Add")
    add_button:SetExtent(100, 30)
    add_button:AddAnchor("LEFT", input_field, "RIGHT", 10, 0)
    api.Interface:ApplyButtonSkin(add_button, BUTTON_BASIC.DEFAULT)

    add_button:SetHandler("OnClick", function()
        local player_name = input_field:GetText()
        if player_name == "" then
            LogError(MSG_PREFIX_BLACKLIST .. "Please enter a player name.")
            return
        end

        local success, message = AddToBlocklist(player_name)
        if success then
            input_field:SetText("")
            UpdateBlacklistDisplay()
            LogInfo(MSG_PREFIX_BLACKLIST .. message)
        else
            LogError(MSG_PREFIX_BLACKLIST .. message)
        end
    end)

    -- List section
    local list_label = window:CreateChildWidget("label", "list_label", 0, true)
    list_label:SetExtent(400, 20)
    list_label:AddAnchor("TOPLEFT", window, 20, 120)
    list_label:SetText("Blacklisted Players:")
    list_label:Show(true)

    local listbox = window:CreateChildWidget("emptywidget", "listbox", 0, true)
    listbox:SetExtent(380, 220)
    listbox:AddAnchor("TOPLEFT", window, 20, 145)
    listbox.player_widgets = {}
    widgets.blacklist_listbox = listbox

    -- Bottom buttons (centered and lowered to prevent overlap)
    -- Window width: 420px
    -- Button group width: 90 + 10 + 90 + 10 + 90 = 290px
    -- Center position: (420 - 290) / 2 = 65px from left
    local clear_button = window:CreateChildWidget("button", "clear_button", 0, true)
    clear_button:SetText("Clear All")
    clear_button:SetExtent(90, 30)
    clear_button:AddAnchor("TOPLEFT", window, 65, 390)
    api.Interface:ApplyButtonSkin(clear_button, BUTTON_BASIC.DEFAULT)

    clear_button:SetHandler("OnClick", function()
        local success, message = ClearBlocklist()
        if success then
            UpdateBlacklistDisplay()
        end
        if success then
            LogInfo(MSG_PREFIX_BLACKLIST .. message)
        else
            LogError(MSG_PREFIX_BLACKLIST .. message)
        end
    end)

    local export_button = window:CreateChildWidget("button", "export_button", 0, true)
    export_button:SetText("Export")
    export_button:SetExtent(90, 30)
    export_button:AddAnchor("LEFT", clear_button, "RIGHT", 10, 0)
    api.Interface:ApplyButtonSkin(export_button, BUTTON_BASIC.DEFAULT)

    export_button:SetHandler("OnClick", function()
        local success, message = ExportBlocklist()
        if success then
            LogInfo(MSG_PREFIX_BLACKLIST .. message)
        else
            LogError(MSG_PREFIX_BLACKLIST .. message)
        end
    end)

    local import_button = window:CreateChildWidget("button", "import_button", 0, true)
    import_button:SetText("Import")
    import_button:SetExtent(90, 30)
    import_button:AddAnchor("LEFT", export_button, "RIGHT", 10, 0)
    api.Interface:ApplyButtonSkin(import_button, BUTTON_BASIC.DEFAULT)

    import_button:SetHandler("OnClick", function()
        local success, message = ImportBlocklist()
        if success then
            UpdateBlacklistDisplay()
        end
        if success then
            LogInfo(MSG_PREFIX_BLACKLIST .. message)
        else
            LogError(MSG_PREFIX_BLACKLIST .. message)
        end
    end)

    UpdateBlacklistDisplay()
end

local function ToggleBlacklistWindow()
    if not widgets.blacklist_window then
        CreateBlacklistWindow()
    end
    local window = widgets.blacklist_window
    window:Show(not window:IsVisible())
end


-- CHAT MESSAGE HANDLING


local function OnChatMessage(channelId, speakerId, _, speakerName, message)
    -- WE EXIT FAST AF
    if not state.is_recruiting or not speakerName or state.recruit_message == "" then
        return
    end

    -- Normalize message once
    local normalized_message = GetLowerName(message)
    local recruit_message = state.recruit_message

    -- Filter check - verify message matches first
    local filter_selection = widgets.filter_dropdown.selctedIndex
    local message_matches = false

    if filter_selection == FILTER_EQUALS then
        message_matches = (normalized_message == recruit_message)
    elseif filter_selection == FILTER_CONTAINS then
        message_matches = (string.find(normalized_message, recruit_message, 1, true) ~= nil)
    elseif filter_selection == FILTER_STARTS_WITH then
        message_matches = (string.sub(normalized_message, 1, #recruit_message) == recruit_message)
    end

    -- Only proceed if message matches
    if not message_matches then
        return
    end

    -- Now check blacklist (only for matching messages)
    if IsBlacklisted(speakerName) then
        LogInfo(MSG_PREFIX_RECRUIT .. "Blocked " .. speakerName .. " (player blacklisted)")
        return
    end

    -- Chat source check
    local recruit_method = widgets.dms_only.selctedIndex
    local should_invite = false

    if recruit_method == CHAT_ALL then
        should_invite = true
    elseif recruit_method == CHAT_WHISPERS and channelId == CHANNEL_WHISPER then
        should_invite = true
    elseif recruit_method == CHAT_GUILD and channelId == CHANNEL_GUILD then
        should_invite = true
    end

    if should_invite then
        LogInfo(MSG_PREFIX_RECRUIT .. "Inviting " .. speakerName)
        api.Team:InviteToTeam(speakerName, false)
    end
end


-- DRAG HANDLERS (defined once + reused)


local function OnCanvasDragStart(self)
    if api.Input:IsShiftKeyDown() then
        self:StartMoving()
        api.Cursor:ClearCursor()
        api.Cursor:SetCursorImage(CURSOR_PATH.MOVE, 0, 0)
    end
end

local function OnCanvasDragStop(self)
    self:StopMovingOrSizing()
    api.Cursor:ClearCursor()
end


-- INITIALIZATION


local function OnLoad()
    -- Load settings
    local settings = api.GetSettings("enhanced_x_up")
    if not settings.blocklist then
        settings.blocklist = {}
        settings.hide_cancel = false
        api.SaveSettings()
    end

    state.blocklist = settings.blocklist

    -- Auto-import
    local success, message = ImportBlocklist()
    if success and message ~= "Imported 0 new entries." then
        LogInfo(MSG_PREFIX_BLACKLIST .. "Auto-imported entries from file.")
    end

    -- Create recruit canvas
    local canvas = api.Interface:CreateEmptyWindow("recruitWindow")
    canvas:AddAnchor("CENTER", "UIParent", 0, 50)
    canvas:SetExtent(200, 100)
    canvas:Show(false)
    widgets.recruit_canvas = canvas

    local bg = canvas:CreateNinePartDrawable(TEXTURE_PATH.HUD, "background")
    bg:SetTextureInfo("bg_quest")
    bg:SetColor(0, 0, 0, 0.5)
    bg:AddAnchor("TOPLEFT", canvas, 0, 0)
    bg:AddAnchor("BOTTOMRIGHT", canvas, 0, 0)

    local cancel_button = canvas:CreateChildWidget("button", "cancel_x", 0, true)
    cancel_button:SetText("Stop Recruiting")
    cancel_button:AddAnchor("TOPLEFT", canvas, "TOPLEFT", 37, 34)
    api.Interface:ApplyButtonSkin(cancel_button, BUTTON_BASIC.DEFAULT)
    cancel_button:SetHandler("OnClick", StopRecruiting)
    widgets.cancel_button = cancel_button

    canvas:SetHandler("OnDragStart", OnCanvasDragStart)
    canvas:SetHandler("OnDragStop", OnCanvasDragStop)
    canvas:EnableDrag(true)

    -- Setup raid manager UI
    local raid_manager = ADDON:GetContent(UIC.RAID_MANAGER)
    state.canvas_width = raid_manager:GetWidth()
    raid_manager:SetExtent(state.canvas_width, 510)
    widgets.raid_manager = raid_manager

    -- Recruit button
    local recruit_button = raid_manager:CreateChildWidget("button", "raid_setup_button", 0, true)
    recruit_button:SetExtent(105, 30)
    recruit_button:AddAnchor("LEFT", raid_manager, 20, 140)
    recruit_button:SetText("Start Recruiting")
    api.Interface:ApplyButtonSkin(recruit_button, BUTTON_BASIC.DEFAULT)
    recruit_button:SetHandler("OnClick", ToggleRecruiting)
    widgets.recruit_button = recruit_button

    -- Recruit textfield
    local textfield = W_CTRL.CreateEdit("recruit_message", raid_manager)
    textfield:AddAnchor("LEFT", raid_manager, 131, 140)
    textfield:SetExtent(150, 30)
    textfield:SetMaxTextLength(64)
    textfield:CreateGuideText("X CR")
    textfield:Show(true)
    widgets.recruit_textfield = textfield

    -- Filter dropdown
    local filter = api.Interface:CreateComboBox(raid_manager)
    filter:SetExtent(100, 30)
    filter:AddAnchor("LEFT", raid_manager, 285, 140)
    filter.dropdownItem = {"Equals", "Contains", "Starts With"}
    filter:Select(1)
    filter:Show(true)
    widgets.filter_dropdown = filter

    -- Chat source dropdown
    local dms = api.Interface:CreateComboBox(raid_manager)
    dms:SetExtent(100, 30)
    dms:AddAnchor("LEFT", raid_manager, 390, 140)
    dms.dropdownItem = {"All Chats", "Whispers", "Guild"}
    dms:Select(1)
    dms:Show(true)
    widgets.dms_only = dms

    -- Blacklist button
    local blacklist_button = raid_manager:CreateChildWidget("button", "blacklist_button", 0, true)
    blacklist_button:SetExtent(150, 30)
    blacklist_button:AddAnchor("LEFT", raid_manager, 20, 180)
    blacklist_button:SetText("Manage Blacklist")
    api.Interface:ApplyButtonSkin(blacklist_button, BUTTON_BASIC.DEFAULT)
    blacklist_button:SetHandler("OnClick", ToggleBlacklistWindow)
    widgets.blacklist_button = blacklist_button

    -- Register event handler and store reference
    state.event_handler = OnChatMessage
    api.On("CHAT_MESSAGE", state.event_handler)
end

local function OnUnload()
    -- Since the API doesn't have an Off method, we simply set the recruiting state to false
    -- The event handler will still be called but will return early due to the state check
    state.is_recruiting = false
    state.event_handler = nil

    if widgets.recruit_button then
        widgets.recruit_button:Show(false)
        widgets.recruit_textfield:Show(false)
        widgets.raid_manager:SetExtent(state.canvas_width, 395)
        widgets.recruit_canvas:Show(false)
        widgets.filter_dropdown:Show(false)
        widgets.dms_only:Show(false)
        widgets.blacklist_button:Show(false)
    end

    if widgets.blacklist_window then
        if widgets.blacklist_listbox and widgets.blacklist_listbox.player_widgets then
            DestroyWidgetList(widgets.blacklist_listbox.player_widgets)
        end
        widgets.blacklist_window:Show(false)
    end

    -- Clear cache on unload
    ClearNameCache()
end


-- ADDON REGISTRATION


enhanced_x_up.OnLoad = OnLoad
enhanced_x_up.OnUnload = OnUnload

return enhanced_x_up