local api = require("api")
local enhanced_x_up = {
    name = "Enhanced X UP",
    version = "1.2",
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
    blocklist = {},         -- Ordered list for saving/UI
    blocklist_lookup = {},  -- [OPTIMIZATION] Hash map for O(1) instant checking
    recruit_message = "",
    is_recruiting = false,
    canvas_width = 0
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
    if not name then return "" end
    local cached = name_cache[name]
    if cached then
        return cached
    end

    if name_cache_size >= NAME_CACHE_MAX_SIZE then
        name_cache = {}
        name_cache_size = 0
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

-- [OPTIMIZATION] Rebuild the hash map from the array list
local function RebuildLookup()
    state.blocklist_lookup = {}
    for i = 1, #state.blocklist do
        local name = state.blocklist[i]
        state.blocklist_lookup[GetLowerName(name)] = true
    end
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
    -- [OPTIMIZATION] Instant lookup
    return state.blocklist_lookup[GetLowerName(name)] == true
end

local function AddToBlocklist(name)
    if IsBlacklisted(name) then
        return false, name .. " is already blacklisted."
    end

    -- Add to Array
    state.blocklist[#state.blocklist + 1] = name
    -- Add to Lookup
    state.blocklist_lookup[GetLowerName(name)] = true

    SaveBlocklist()
    return true, "Added player: " .. name
end

local function RemoveFromBlocklist(name)
    local lower_name = GetLowerName(name)
    local blocklist = state.blocklist

    for i = #blocklist, 1, -1 do
        if GetLowerName(blocklist[i]) == lower_name then
            table.remove(blocklist, i)

            -- Remove from Lookup
            state.blocklist_lookup[lower_name] = nil

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
    state.blocklist_lookup = {}
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
        local empty_label = frame:CreateChildWidget("label", "empty_msg", 0, true)
        empty_label:SetText("(No entries)")
        empty_label:SetExtent(380, 20)
        empty_label:AddAnchor("TOPLEFT", frame, 0, 0)
        empty_label:Show(true)
        frame.player_widgets[1] = {label = empty_label}
        return
    end

    local visible_count = math.min(count, 5)
    for i = 1, visible_count do
        local y_offset = (i - 1) * 35

        local name_label = frame:CreateChildWidget("label", "player_" .. i, 0, true)
        name_label:SetText(blocklist[i])
        name_label:SetExtent(240, 25)
        name_label:AddAnchor("TOPLEFT", frame, 5, y_offset + 5)
        name_label:Show(true)

        local remove_btn = frame:CreateChildWidget("button", "remove_" .. i, 0, true)
        remove_btn:SetText("Remove")
        remove_btn:SetExtent(80, 25)
        remove_btn:AddAnchor("LEFT", name_label, "RIGHT", 10, 0)
        api.Interface:ApplyButtonSkin(remove_btn, BUTTON_BASIC.DEFAULT)

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
            state.blocklist_lookup[GetLowerName(entry)] = true
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


-- RECRUITMENT CONTROL


local function StartRecruiting()
    local msg = widgets.recruit_textfield:GetText()
    if not msg or msg == "" then
        LogError(MSG_PREFIX_RECRUIT .. "Please enter a recruit message.")
        return false
    end

    state.is_recruiting = true
    -- Store recruit message in lower case for insensitive matching
    state.recruit_message = GetLowerName(msg)

    widgets.recruit_button:SetText("Stop Recruiting")
    widgets.recruit_textfield:Enable(false)
    widgets.recruit_canvas:Show(true)

    LogInfo(MSG_PREFIX_RECRUIT .. "Now recruiting for: " .. msg)
    return true
end

local function StopRecruiting()
    state.is_recruiting = false
    state.recruit_message = ""

    widgets.recruit_button:SetText("Start Recruiting")
    widgets.recruit_textfield:Enable(true)
    widgets.recruit_canvas:Show(false)

    LogInfo(MSG_PREFIX_RECRUIT .. "Stopped recruiting.")
end

local function ToggleRecruiting()
    if state.is_recruiting then
        StopRecruiting()
    else
        StartRecruiting()
    end
end


-- BLACKLIST WINDOW CREATION


local function CreateBlacklistWindow()
    local window = api.Interface:CreateWindow("blacklistWindow", "Blacklist Manager", 0, 0)
    window:SetExtent(420, 460)
    window:AddAnchor("CENTER", "UIParent", 0, 0)
    window:Show(false)
    widgets.blacklist_window = window

    local instructions = window:CreateChildWidget("label", "instructions", 0, true)
    instructions:SetText("Add players to prevent raid invites")
    instructions:SetExtent(380, 20)
    instructions:AddAnchor("TOPLEFT", window, 20, 50)

    local player_label = window:CreateChildWidget("label", "player_label", 0, true)
    player_label:SetText("Player Name:")
    player_label:SetExtent(100, 20)
    player_label:AddAnchor("TOP", window, 0, 80)

    local input = W_CTRL.CreateEdit("blacklist_input", window)
    input:SetExtent(200, 30)
    input:AddAnchor("CENTER", window, -55, -110)
    input:SetMaxTextLength(32)
    input:Show(true)
    widgets.blacklist_input = input

    local add_button = window:CreateChildWidget("button", "add_player_button", 0, true)
    add_button:SetText("Add Player")
    add_button:SetExtent(100, 30)
    add_button:AddAnchor("LEFT", input, "RIGHT", 10, 0)
    api.Interface:ApplyButtonSkin(add_button, BUTTON_BASIC.DEFAULT)

    add_button:SetHandler("OnClick", function()
        local name = input:GetText()
        if not name or name == "" then
            LogError(MSG_PREFIX_BLACKLIST .. "Please enter a player name.")
            return
        end

        local success, message = AddToBlocklist(name)
        if success then
            UpdateBlacklistDisplay()
            input:SetText("")
            LogInfo(MSG_PREFIX_BLACKLIST .. message)
        else
            LogError(MSG_PREFIX_BLACKLIST .. message)
        end
    end)

    local list_label = window:CreateChildWidget("label", "list_label", 0, true)
    list_label:SetText("Current Blacklist:")
    list_label:SetExtent(300, 20)
    list_label:AddAnchor("TOPLEFT", window, 20, 150)

    local list_frame = window:CreateChildWidget("emptywidget", "list_frame", 0, true)
    list_frame:SetExtent(380, 180)
    list_frame:AddAnchor("TOPLEFT", window, 20, 175)
    list_frame:Show(true)
    widgets.blacklist_listbox = list_frame

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
    if not state.is_recruiting or not speakerName or state.recruit_message == "" then
        return
    end

    -- Normalize message to lowercase for case-insensitive matching
    local normalized_message = GetLowerName(message)
    local recruit_message = state.recruit_message -- Already lowercase

    -- Filter check
    local filter_selection = widgets.filter_dropdown.selctedIndex
    local message_matches = false

    if filter_selection == FILTER_EQUALS then
        message_matches = (normalized_message == recruit_message)
    elseif filter_selection == FILTER_CONTAINS then
        -- string.find with 'true' for 4th arg prevents regex magic characters, checks for literal string
        -- Since both inputs are lowercase, this is case-insensitive
        message_matches = (string.find(normalized_message, recruit_message, 1, true) ~= nil)
    elseif filter_selection == FILTER_STARTS_WITH then
        message_matches = (string.sub(normalized_message, 1, #recruit_message) == recruit_message)
    end

    if not message_matches then
        return
    end

    -- Check Blacklist (Optimized O(1))
    if IsBlacklisted(speakerName) then
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
        -- Check if already in team to avoid spam
        local existingMemberIndex = api.Team:GetMemberIndexByName(speakerName)
        if not existingMemberIndex then
            LogInfo(MSG_PREFIX_RECRUIT .. "Inviting " .. speakerName)
            api.Team:InviteToTeam(speakerName, false)
        end
    end
end


-- DRAG HANDLERS


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
    local settings = api.GetSettings("enhanced_x_up")
    if not settings.blocklist then
        settings.blocklist = {}
        settings.hide_cancel = false
        api.SaveSettings()
    end

    state.blocklist = settings.blocklist
    RebuildLookup()

    -- Auto-import
    local success, message = ImportBlocklist()
    if success and message ~= "Imported 0 new entries." then
        LogInfo(MSG_PREFIX_BLACKLIST .. "Auto-imported entries from file.")
    end

    -- Recruit canvas
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

    -- Raid Manager UI Hook
    local raid_manager = ADDON:GetContent(UIC.RAID_MANAGER)
    state.canvas_width = raid_manager:GetWidth()
    raid_manager:SetExtent(state.canvas_width, 510)
    widgets.raid_manager = raid_manager

    local recruit_button = raid_manager:CreateChildWidget("button", "raid_setup_button", 0, true)
    recruit_button:SetExtent(105, 30)
    recruit_button:AddAnchor("LEFT", raid_manager, 20, 140)
    recruit_button:SetText("Start Recruiting")
    api.Interface:ApplyButtonSkin(recruit_button, BUTTON_BASIC.DEFAULT)
    recruit_button:SetHandler("OnClick", ToggleRecruiting)
    widgets.recruit_button = recruit_button

    local textfield = W_CTRL.CreateEdit("recruit_message", raid_manager)
    textfield:AddAnchor("LEFT", raid_manager, 131, 140)
    textfield:SetExtent(150, 30)
    textfield:SetMaxTextLength(64)
    textfield:CreateGuideText("X CR")
    textfield:Show(true)
    widgets.recruit_textfield = textfield

    local filter = api.Interface:CreateComboBox(raid_manager)
    filter:SetExtent(100, 30)
    filter:AddAnchor("LEFT", raid_manager, 285, 140)
    filter.dropdownItem = {"Equals", "Contains", "Starts With"}
    -- Default selected index set to 2 (Contains) per request
    filter:Select(2)
    filter:Show(true)
    widgets.filter_dropdown = filter

    local dms = api.Interface:CreateComboBox(raid_manager)
    dms:SetExtent(100, 30)
    dms:AddAnchor("LEFT", raid_manager, 390, 140)
    dms.dropdownItem = {"All Chats", "Whispers", "Guild"}
    dms:Select(1)
    dms:Show(true)
    widgets.dms_only = dms

    local blacklist_button = raid_manager:CreateChildWidget("button", "blacklist_button", 0, true)
    blacklist_button:SetExtent(150, 30)
    blacklist_button:AddAnchor("LEFT", raid_manager, 20, 180)
    blacklist_button:SetText("Manage Blacklist")
    api.Interface:ApplyButtonSkin(blacklist_button, BUTTON_BASIC.DEFAULT)
    blacklist_button:SetHandler("OnClick", ToggleBlacklistWindow)
    widgets.blacklist_button = blacklist_button

    api.On("CHAT_MESSAGE", OnChatMessage)
end

local function OnUnload()
    api.Off("CHAT_MESSAGE", OnChatMessage)

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

    ClearNameCache()
end


enhanced_x_up.OnLoad = OnLoad
enhanced_x_up.OnUnload = OnUnload

return enhanced_x_up