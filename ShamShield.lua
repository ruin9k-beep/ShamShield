--[[
  ShamShield - 1.12 / Turtle WoW
  One floating, borderless, transparent frame holding two identical slots:
    [ Shield ]  [ Weapon buff ]
  Each slot has:
    * a large button that casts the currently assigned spell
    * a small flyout toggle above it listing every learned spell of that kind
    * a small status overlay (charges / time left / OFF) on the icon
    * in combat the overlay shrinks to a big charge counter plus the timer

  Lua 5.0 rules apply: no '#' operator, no '%' operator, no string.gmatch,
  no select(), handlers use the globals this / arg1 / event.

  Controls:
    Left-click   cast the assigned spell
    Shift-drag   move the frame
    Hotkey       Key Bindings > ShamShield > Cast Weapon Buff, then Shield
                 (weapon buff first when allowed, else the shield; stones, oils and
                  poisons are never overwritten - see CanCastWeaponBuff below)
  Weapon flyout also lists the items tracked on the Items tab of the config window
  (seeded with the mana / wizard oils); each can be shown or hidden individually.
  Warning sounds are picked on the Sounds tab of the config window.
  Slash: /shamshield (or /ss; on its own it opens the config window)
         config | lock | unlock | reset | sound | test
  Sounds (shield slot only, all toggled by /ss sound):
    - in combat with no shield buff: alert every 5 seconds (not while mounted)
    - in combat, each time the shield drops to its last 3 charges: warning
    - in combat, when the shield is used up entirely: special sound
]]

ShamShieldDB = ShamShieldDB or {}

-- Spell lists. Add extra spell names here (e.g. other Turtle WoW additions).
local SHIELDS = { "Lightning Shield", "Water Shield", "Earth Shield" }
local WEAPON_BUFFS = { "Rockbiter Weapon", "Windfury Weapon",
                       "Frostbrand Weapon", "Flametongue Weapon" }
-- Items that appear in the weapon flyout when they are in your bags. The addon
-- manages these like imbues (swap / refresh rules apply to them too).
-- Starting list of tracked items. The player edits their own list on the
-- "Items" tab of /ss; this only seeds it the first time.
local DEFAULT_WEAPON_ITEMS = { "Brilliant Mana Oil", "Lesser Mana Oil",
                               "Brilliant Wizard Oil", "Wizard Oil",
                               "Lesser Wizard Oil", "Minor Wizard Oil" }

-- The live list every other part of the addon reads. It is refilled IN PLACE
-- from ShamShieldDB.weaponItems (see SyncTrackedItems), never replaced.
local WEAPON_ITEMS = {}
for i = 1, table.getn(DEFAULT_WEAPON_ITEMS) do
    table.insert(WEAPON_ITEMS, DEFAULT_WEAPON_ITEMS[i])
end

local function SyncTrackedItems()
    if not ShamShieldDB.weaponItems then
        ShamShieldDB.weaponItems = {}
        for i = 1, table.getn(DEFAULT_WEAPON_ITEMS) do
            table.insert(ShamShieldDB.weaponItems, DEFAULT_WEAPON_ITEMS[i])
        end
    end
    for i = table.getn(WEAPON_ITEMS), 1, -1 do
        table.remove(WEAPON_ITEMS, i)
    end
    for i = 1, table.getn(ShamShieldDB.weaponItems) do
        table.insert(WEAPON_ITEMS, ShamShieldDB.weaponItems[i])
    end
end

local MAIN_SIZE  = 44
local TOGGLE_H   = 14
local FLY_SIZE   = 32
local FLY_GAP    = 2
local SLOT_GAP   = 8
local FONT       = "Fonts\\FRIZQT__.TTF"
local UNKNOWN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local SOUND_INTERVAL = 5            -- seconds between alerts
-- "No shield" alert, every 5 seconds in combat. A sound file path or a
-- PlaySound name both work. Other options to try (test with /ss test alert):
--   Sound\\Spells\\Bloodlust.wav    Sound\\Creature\\Murloc\\mMurlocAggroOld.wav
--   Sound\\Doodad\\G_GongTroll01.wav
local ALERT_SOUND = "Sound\\Doodad\\G_GongTroll01.wav"
local PULSE_PERIOD = 1.5             -- seconds for one fade cycle of the low-mana overlay
local PULSE_MIN, PULSE_MAX = 0.50, 0.75
local LOW_CHARGES = 3                -- warn at this many charges and below
-- Played each time a charge is used (3, 2, 1). A game sound FILE (any path
-- containing a backslash) or a PlaySound name both work. Other bells to try:
--   Sound\\Doodad\\BellTollHorde.wav  Sound\\Doodad\\BellTollAlliance.wav
--   Sound\\Doodad\\BellTollTribal.wav  (test with /ss test low)
local LOW_SOUND = "Sound\\Doodad\\BellTollNightElf.wav"
local FALLBACK_SOUND = "TellMessage"   -- used if this client cannot play sound files
local DEPLETED_SOUND = "igQuestFailed" -- played when the shield runs out

local MAINHAND_SLOT = 16
local OFFHAND_SLOT  = 17

-- Plays an alert: either a PlaySound name ("RaidWarning") or a sound file path.
local function PlayAlert(sound)
    if string.find(sound, "\\", 1, true) then
        if PlaySoundFile then
            PlaySoundFile(sound)
        else
            PlaySound(FALLBACK_SOUND)
        end
    else
        PlaySound(sound)
    end
end

-- Sounds the player can pick for each alert (Sounds tab of /ss). "sound" is a
-- PlaySound name or a game sound file path; "none" is silent.
local SOUND_CHOICES = {
    { name = "Off (silent)",           sound = "none" },
    { name = "Raid warning",           sound = "RaidWarning" },
    { name = "Whisper ping",           sound = "TellMessage" },
    { name = "Map ping",               sound = "MapPing" },
    { name = "Quest failed",           sound = "igQuestFailed" },
    { name = "Level up",               sound = "LevelUp" },
    { name = "Auction bell",           sound = "AuctionWindowOpen" },
    { name = "Bell toll (Night Elf)",  sound = "Sound\\Doodad\\BellTollNightElf.wav" },
    { name = "Bell toll (Horde)",      sound = "Sound\\Doodad\\BellTollHorde.wav" },
    { name = "Bell toll (Alliance)",   sound = "Sound\\Doodad\\BellTollAlliance.wav" },
    { name = "Bell toll (Tribal)",     sound = "Sound\\Doodad\\BellTollTribal.wav" },
    { name = "Troll gong",             sound = "Sound\\Doodad\\G_GongTroll01.wav" },
}

-- The three alerts. "default" is used until the player picks something.
local SOUND_KINDS = {
    { key = "alert",    label = "In combat with no shield (repeats)", default = ALERT_SOUND },
    { key = "low",      label = "Shield low on charges",              default = LOW_SOUND },
    { key = "depleted", label = "Shield used up",                     default = DEPLETED_SOUND },
}

local function GetKindSound(key)
    local chosen = ShamShieldDB.sounds and ShamShieldDB.sounds[key]
    if chosen then return chosen end
    for i = 1, table.getn(SOUND_KINDS) do
        if SOUND_KINDS[i].key == key then return SOUND_KINDS[i].default end
    end
    return "none"
end

local function KindEnabled(key)
    return not (ShamShieldDB.soundOff and ShamShieldDB.soundOff[key])
end

-- Plays the sound the player picked for one kind of alert. A disabled alert
-- stays silent unless force is set (the Test button and the picker preview).
local function PlayKind(key, force)
    if not force and not KindEnabled(key) then return end
    local sound = GetKindSound(key)
    if sound ~= "none" then
        PlayAlert(sound)
    end
end

local slots = {}        -- every slot object, in display order
local shieldSlot        -- the slot that drives the combat sound alerts
local weaponSlot

---------------------------------------------------------------------------
-- Shared helpers
---------------------------------------------------------------------------
local root = CreateFrame("Frame", "ShamShieldFrame", UIParent)
root:SetWidth(MAIN_SIZE * 2 + SLOT_GAP)
root:SetHeight(MAIN_SIZE + TOGGLE_H)
root:SetMovable(true)
root:SetClampedToScreen(true)
root:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
-- No backdrop, no border: the frame itself is fully transparent.

local scanTip = CreateFrame("GameTooltip", "ShamShieldScanTip", nil, "GameTooltipTemplate")

local function PrepTip()
    scanTip:SetOwner(UIParent, "ANCHOR_NONE")
    scanTip:ClearLines()
end

local function FormatTime(t)
    if t >= 60 then
        return math.floor(t / 60) .. "m"
    end
    return math.floor(t) .. "s"
end

local function TextureMatch(a, b)
    if not a or not b then return false end
    return string.lower(a) == string.lower(b)
end

local function SavePosition()
    local left, bottom = root:GetLeft(), root:GetBottom()
    if left and bottom then
        ShamShieldDB.x = left
        ShamShieldDB.y = bottom
    end
end

local function RestorePosition()
    if ShamShieldDB.x and ShamShieldDB.y then
        root:ClearAllPoints()
        root:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", ShamShieldDB.x, ShamShieldDB.y)
    end
end

local function StartDrag()
    if IsShiftKeyDown() and not ShamShieldDB.locked then
        root:StartMoving()
    end
end

local function StopDrag()
    root:StopMovingOrSizing()
    SavePosition()
end

---------------------------------------------------------------------------
-- Per-slot state helpers
---------------------------------------------------------------------------
local pendingReplace = nil   -- set while applying an item, see REPLACE_ENCHANT

local function IsWeaponItem(name)
    for i = 1, table.getn(WEAPON_ITEMS) do
        if WEAPON_ITEMS[i] == name then return true end
    end
    return false
end

-- Finds an item in the bags. Returns bag, slot, texture, total count (or nil).
local function FindBagItem(name)
    local wanted = string.lower(name)
    local fb, fs, ftex
    local total = 0
    for bag = 0, 4 do
        for sl = 1, GetContainerNumSlots(bag) do
            local link = GetContainerItemLink(bag, sl)
            if link then
                local _, _, itemName = string.find(link, "%[(.-)%]")
                if itemName and string.lower(itemName) == wanted then
                    local tex, cnt = GetContainerItemInfo(bag, sl)
                    total = total + (cnt or 1)
                    if not fb then fb, fs, ftex = bag, sl, tex end
                end
            end
        end
    end
    if fb then return fb, fs, ftex, total end
    return nil
end

-- Uses an oil / stone from the bags on the main hand weapon.
local function UseWeaponItem(name)
    local bag, sl = FindBagItem(name)
    if not bag then return end
    UseContainerItem(bag, sl)
    if SpellIsTargeting() then
        pendingReplace = GetTime()
        PickupInventoryItem(MAINHAND_SLOT)
    end
end

local function GetSelected(slot)
    return ShamShieldDB[slot.cfg.dbKey]
end

local function SetSelected(slot, name)
    ShamShieldDB[slot.cfg.dbKey] = name
end

local function FindKnown(slot, name)
    if not name then return nil end
    for i = 1, table.getn(slot.known) do
        if slot.known[i].name == name then return slot.known[i] end
    end
    return nil
end

---------------------------------------------------------------------------
-- Status scanners (one per kind of slot). Each fills slot.state.
---------------------------------------------------------------------------

-- Is this player buff a mount? 1.12 has no IsMounted(), so look at the buff:
-- most mount icons are Ability_Mount_*, and mount buff tooltips say
-- "Increases speed by NN%". (English client text.)
local function IsMountBuff(tex)
    if tex and string.find(string.lower(tex), "ability_mount") then
        return true
    end
    for i = 2, scanTip:NumLines() do
        local line = getglobal("ShamShieldScanTipTextLeft" .. i)
        local text = line and line:GetText()
        if text and string.find(text, "Increases speed by") then
            return true
        end
    end
    return false
end

-- Shields: they are self-only, so only the player's own buffs matter.
local function ScanShield(slot, sel)
    local st = slot.state

    for i = 0, 31 do
        local idx = GetPlayerBuff(i, "HELPFUL")
        if not idx or idx < 0 then break end

        PrepTip()
        scanTip:SetPlayerBuff(idx)
        local text = ShamShieldScanTipTextLeft1:GetText()
        local tex = GetPlayerBuffTexture(idx)

        if not st.mounted and IsMountBuff(tex) then
            st.mounted = true
        end

        for k = 1, table.getn(slot.known) do
            local sp = slot.known[k]
            if text == sp.name or TextureMatch(tex, sp.texture) then
                st.anyShield = true
                if sp == sel and not st.active then
                    st.active = true
                    st.count = GetPlayerBuffApplications(idx) or 0
                    local left = GetPlayerBuffTimeLeft(idx)
                    if left and left > 0 then
                        st.expire = GetTime() + left
                        st.hasTimer = true
                    end
                end
            end
        end
    end

    -- The client only reports stack counts above 1, so a last charge can come
    -- back as 0. If the shield was counting charges a moment ago and is still
    -- up, treat it as 1 charge left.
    if st.active and st.count < 1 and slot.prevActive and slot.prevCount >= 1 then
        st.count = 1
    end

    -- Remember the most charges this shield has ever shown (its maximum).
    if st.active and st.count > 0 then
        ShamShieldDB.maxSeen = ShamShieldDB.maxSeen or {}
        if st.count > (ShamShieldDB.maxSeen[sel.name] or 0) then
            ShamShieldDB.maxSeen[sel.name] = st.count
        end
    end
end

-- Weapon buffs: read the temporary enchant on each hand, then check the
-- weapon tooltip to see WHICH imbue it is.
local function WeaponKeyword(name)
    -- Items match on their full name ("Brilliant Mana Oil");
    -- spells on their first word ("Rockbiter Weapon" -> "Rockbiter").
    if IsWeaponItem(name) then return name end
    local _, _, word = string.find(name, "^(%S+)")
    return word
end

-- Which buff the addon manages (a shaman imbue from WEAPON_BUFFS, or an item
-- from WEAPON_ITEMS) is on this hand? nil if the hand has no temporary
-- enchant, or only one the addon does not manage (stone, other oil, poison...).
--
-- The weapon tooltip is read once. Line 1 is the item name; temporary enchants
-- appear below it as e.g. "Windfury Weapon (29 min)". Requiring the bracket
-- avoids false matches on items that merely have the word in their own text.
-- The LONGEST matching name wins, so "Brilliant Wizard Oil" is never mistaken
-- for "Wizard Oil".
local function GetShamanImbue(invSlot)
    PrepTip()
    scanTip:SetInventoryItem("player", invSlot)

    local lines = {}
    for i = 2, scanTip:NumLines() do
        local line = getglobal("ShamShieldScanTipTextLeft" .. i)
        local text = line and line:GetText()
        if text and string.find(text, "%(.+%)") then
            table.insert(lines, string.lower(text))
        end
    end
    if table.getn(lines) == 0 then return nil end

    local best, bestLen = nil, 0

    local function Check(name)
        local keyword = string.lower(WeaponKeyword(name))
        if string.len(keyword) > bestLen then
            for i = 1, table.getn(lines) do
                if string.find(lines[i], keyword, 1, true) then
                    best, bestLen = name, string.len(keyword)
                    return
                end
            end
        end
    end

    for i = 1, table.getn(WEAPON_BUFFS) do Check(WEAPON_BUFFS[i]) end
    for i = 1, table.getn(WEAPON_ITEMS) do Check(WEAPON_ITEMS[i]) end
    return best
end

local function ScanWeapon(slot, sel)
    local st = slot.state
    local hasMH, mhExp, mhCharges, hasOH, ohExp, ohCharges = GetWeaponEnchantInfo()

    local bestTime = nil
    local minCharges = nil

    local function Consider(expMs, charges)
        st.active = true
        if expMs and expMs > 0 then
            local secs = expMs / 1000
            if not bestTime or secs < bestTime then bestTime = secs end
        end
        if charges and charges > 0 then
            if not minCharges or charges < minCharges then minCharges = charges end
        end
    end

    if hasMH and GetShamanImbue(MAINHAND_SLOT) == sel.name then
        Consider(mhExp, mhCharges)
    end
    if hasOH and GetShamanImbue(OFFHAND_SLOT) == sel.name then
        Consider(ohExp, ohCharges)
    end

    if st.active then
        st.count = minCharges or 0
        if bestTime then
            st.expire = GetTime() + bestTime
            st.hasTimer = true
        end
    end
end

local function ScanStatus(slot)
    local st = slot.state
    st.active = false
    st.anyShield = false
    st.mounted = false
    st.count = 0
    st.expire = nil
    st.hasTimer = false

    local sel = FindKnown(slot, GetSelected(slot))

    -- In the low-mana range the shield slot tracks the shield that WILL be
    -- cast (Water Shield), so its charges, timer and sounds are correct.
    if slot.cfg.overrideSpell then
        sel = slot.cfg.overrideSpell() or sel
    end

    -- Tracking a different spell than last scan: forget the old charge history
    -- so the switch is not mistaken for a charge being used or a shield ending.
    local name = sel and sel.name
    if name ~= slot.trackedName then
        slot.trackedName = name
        slot.prevActive = false
        slot.prevCount = 0
        slot.switched = true
    end

    if not sel then return end

    slot.cfg.scan(slot, sel)
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

-- Writes the remaining duration into statusText, colored by urgency.
local function ShowTimer(slot)
    local left = slot.state.expire - GetTime()
    if left < 0 then left = 0 end
    slot.statusText:SetText(FormatTime(left))
    if left <= 15 then
        slot.statusText:SetTextColor(1, 0.2, 0.2)
    elseif left <= 60 then
        slot.statusText:SetTextColor(1, 0.8, 0.1)
    else
        slot.statusText:SetTextColor(0.2, 1, 0.2)
    end
end

local function SetCombatFont(slot, size)
    if slot.combatFontSize ~= size then
        slot.combatFontSize = size
        slot.combatText:SetFont(FONT, size, "OUTLINE")
    end
end

local function UpdateDisplay(slot)
    local st = slot.state
    local sel = FindKnown(slot, GetSelected(slot))

    if not sel then
        slot.icon:SetTexture(UNKNOWN_ICON)
        slot.icon:SetVertexColor(0.5, 0.5, 0.5)
        slot.statusText:SetText("")
        slot.countText:SetText("")
        slot.combatText:SetText("")
        return
    end

    slot.icon:SetTexture(sel.texture)

    if UnitAffectingCombat("player") then
        -- Combat: big remaining-charges number plus the duration timer only.
        slot.countText:Hide()
        slot.combatText:Show()

        -- The duration timer stays visible in combat (when there is one).
        if st.active and st.hasTimer and st.expire then
            slot.statusText:Show()
            ShowTimer(slot)
        else
            slot.statusText:Hide()
        end

        if st.active then
            slot.icon:SetVertexColor(1, 1, 1)
            if st.count and st.count > 0 then
                SetCombatFont(slot, 28)
                slot.combatText:SetText(st.count)
                if st.count <= 1 then
                    slot.combatText:SetTextColor(1, 0.2, 0.2)
                elseif st.count <= LOW_CHARGES then
                    slot.combatText:SetTextColor(1, 0.8, 0.1)
                else
                    slot.combatText:SetTextColor(1, 1, 1)
                end
            else
                slot.combatText:SetText("")   -- no charges (timer only)
            end
        else
            slot.icon:SetVertexColor(0.5, 0.5, 0.5)
            SetCombatFont(slot, slot.cfg.combatOffSize)
            slot.combatText:SetText(slot.cfg.combatOffText)
            slot.combatText:SetTextColor(1, 0.2, 0.2)
        end
        return
    end

    -- Out of combat: full status overlay.
    slot.combatText:Hide()
    slot.statusText:Show()
    slot.countText:Show()

    if st.active then
        slot.icon:SetVertexColor(1, 1, 1)

        if st.count and st.count > 0 then
            slot.countText:SetText(st.count)
            if st.count <= 1 then
                slot.countText:SetTextColor(1, 0.8, 0.1)
            else
                slot.countText:SetTextColor(1, 1, 1)
            end
        else
            slot.countText:SetText("")
        end

        if st.hasTimer and st.expire then
            ShowTimer(slot)
        else
            slot.statusText:SetText("ON")
            slot.statusText:SetTextColor(0.2, 1, 0.2)
        end
    else
        slot.icon:SetVertexColor(0.5, 0.5, 0.5)
        slot.countText:SetText("")
        slot.statusText:SetText("OFF")
        slot.statusText:SetTextColor(1, 0.2, 0.2)
    end
end

local function SyncPrevious(slot)
    slot.prevActive = slot.state.active
    slot.prevCount = slot.state.count or 0
end

-- Compares the fresh scan with the previous one and plays charge sounds.
local function CheckChargeSounds(slot)
    local st = slot.state
    local count = st.count or 0

    if ShamShieldDB.sound ~= false and UnitAffectingCombat("player") then
        if slot.prevActive and not st.active and slot.prevCount > 0 then
            PlayKind("depleted")               -- ran out entirely
        elseif slot.prevActive and st.active and count > 0
               and count < slot.prevCount and count <= LOW_CHARGES then
            PlayKind("low")                    -- a charge was used up
        end
    end

    SyncPrevious(slot)
end

-- silent = true skips sounds (used when the selection / spellbook changes,
-- so switching spells doesn't look like a shield running out).
local function Refresh(slot, silent)
    ScanStatus(slot)
    if slot.switched then
        slot.switched = false
        silent = true
    end
    if silent or not slot.cfg.chargeSounds then
        SyncPrevious(slot)
    else
        CheckChargeSounds(slot)
    end
    UpdateDisplay(slot)
end

---------------------------------------------------------------------------
-- Flyout
---------------------------------------------------------------------------
local function SelectSpell(slot, name)
    SetSelected(slot, name)
    slot.flyout:Hide()
    Refresh(slot, true)
end

local function GetFlyButton(slot, i)
    if slot.flyBtns[i] then return slot.flyBtns[i] end

    local b = CreateFrame("Button", "ShamShield" .. slot.cfg.name .. "FlyButton" .. i, slot.flyout)
    b:SetWidth(FLY_SIZE)
    b:SetHeight(FLY_SIZE)
    b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    b:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")

    local t = b:CreateTexture(nil, "BACKGROUND")
    t:SetAllPoints(b)
    t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon = t

    b:SetScript("OnClick", function()
        SelectSpell(slot, this.spellName)
    end)
    b:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if this.isItem then
            local bag, sl = FindBagItem(this.spellName)
            if bag then
                GameTooltip:SetBagItem(bag, sl)
            else
                GameTooltip:SetText(this.spellName)
                GameTooltip:AddLine("None in your bags", 0.6, 0.6, 0.6)
            end
        else
            GameTooltip:SetSpell(this.spellIndex, BOOKTYPE_SPELL)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    slot.flyBtns[i] = b
    return b
end

local function LayoutFlyout(slot)
    for i = 1, table.getn(slot.flyBtns) do
        slot.flyBtns[i]:Hide()
    end

    -- Hidden items stay tracked (and selectable) but get no flyout button.
    local n = 0
    for i = 1, table.getn(slot.known) do
        local sp = slot.known[i]
        if not sp.hidden then
            n = n + 1
            local b = GetFlyButton(slot, n)
            b.spellName = sp.name
            b.spellIndex = sp.index
            b.isItem = sp.isItem
            b.icon:SetTexture(sp.texture)
            if sp.isItem and not sp.available then
                b.icon:SetVertexColor(0.4, 0.4, 0.4)
            else
                b.icon:SetVertexColor(1, 1, 1)
            end
            b:ClearAllPoints()
            b:SetPoint("BOTTOM", slot.flyout, "BOTTOM", 0, (n - 1) * (FLY_SIZE + FLY_GAP))
            b:Show()
        end
    end
    slot.shownCount = n

    local h = n
    if h < 1 then h = 1 end
    slot.flyout:SetHeight(h * FLY_SIZE + (h - 1) * FLY_GAP)
end

---------------------------------------------------------------------------
-- Spellbook scan
---------------------------------------------------------------------------
local function ScanSpellbook(slot)
    local wanted = slot.cfg.spells
    local found = {}
    local i = 1
    while true do
        local name = GetSpellName(i, BOOKTYPE_SPELL)
        if not name then break end
        for s = 1, table.getn(wanted) do
            if name == wanted[s] then
                -- Later ranks come later in the book, so this keeps the highest.
                found[name] = { name = name, index = i,
                                texture = GetSpellTexture(i, BOOKTYPE_SPELL) }
            end
        end
        i = i + 1
    end

    slot.known = {}
    for s = 1, table.getn(wanted) do
        if found[wanted[s]] then
            table.insert(slot.known, found[wanted[s]])
        end
    end

    -- Items (e.g. Brilliant Mana Oil) are ALWAYS listed, so the selection never
    -- silently jumps to a spell when the last one is used. "available" says
    -- whether any are in the bags right now; the icon is remembered from the
    -- last time one was seen.
    if slot.cfg.items then
        ShamShieldDB.itemTex = ShamShieldDB.itemTex or {}
        for s = 1, table.getn(slot.cfg.items) do
            local name = slot.cfg.items[s]
            local bag, sl, tex = FindBagItem(name)
            if bag and tex then
                ShamShieldDB.itemTex[name] = tex
            end
            table.insert(slot.known, {
                name = name,
                isItem = true,
                available = bag and true or false,
                hidden = (ShamShieldDB.hiddenItems and ShamShieldDB.hiddenItems[name]) and true or false,
                texture = tex or ShamShieldDB.itemTex[name] or UNKNOWN_ICON,
            })
        end
    end

    if not FindKnown(slot, GetSelected(slot)) then
        if slot.known[1] then
            SetSelected(slot, slot.known[1].name)
        else
            SetSelected(slot, nil)
        end
    end

    LayoutFlyout(slot)
    Refresh(slot, true)
end

---------------------------------------------------------------------------
-- Casting / bindings
---------------------------------------------------------------------------
local function CastSelected(slot, announce)
    local sel = FindKnown(slot, GetSelected(slot))
    if slot.cfg.overrideSpell then
        sel = slot.cfg.overrideSpell() or sel
    end
    if not sel then return end

    -- Slots can veto a cast (the weapon slot protects existing weapon buffs).
    if slot.cfg.canCast then
        local ok, reason = slot.cfg.canCast()
        if not ok then
            if announce and reason then
                DEFAULT_CHAT_FRAME:AddMessage("ShamShield: " .. reason)
            end
            return
        end
    end

    if sel.isItem then
        UseWeaponItem(sel.name)
    else
        CastSpellByName(sel.name)
    end
end

-- May the addon cast the selected weapon buff right now? (Used by the weapon
-- button AND the hotkey.) Returns allowed, reason.
--   * no weapon selected / learned, or no weapon equipped    -> no
--   * main hand has no temporary enchant                      -> yes
--   * main hand has anything that is NOT a shaman imbue
--     (sharpening stone, weightstone, oil, poison, ...)       -> NEVER, whatever
--                                                                the settings say
--   * main hand has a DIFFERENT shaman imbue                  -> yes (swap it)
--   * main hand has the SAME shaman imbue                     -> only once it has
--     ShamShieldDB.recastMinutes minutes or fewer left (0 = never refresh)
-- GetWeaponEnchantInfo() reports ANY temporary weapon enchant; the tooltip
-- check then tells shaman imbues apart from everything else.
local function CanCastWeaponBuff()
    local sel = FindKnown(weaponSlot, GetSelected(weaponSlot))
    if not sel then return false end
    if not GetInventoryItemLink("player", MAINHAND_SLOT) then return false end

    if sel.isItem and not sel.available then
        return false, "you have no " .. sel.name .. " in your bags."
    end

    local hasMH, mhExp = GetWeaponEnchantInfo()
    if not hasMH then return true end

    local current = GetShamanImbue(MAINHAND_SLOT)
    if not current then
        return false, "your main hand has a weapon buff the addon does not manage; not overwriting it."
    end

    -- Optional: item-based buffs (oils, stones, ...) are never overwritten,
    -- whether by a spell imbue, a different item, or a refresh of the same one.
    if IsWeaponItem(current) and ShamShieldDB.neverOverwriteItems then
        return false, current .. " is on your weapon; not overwriting item buffs (see /ss config)."
    end

    if current ~= sel.name then return true end

    local minutes = ShamShieldDB.recastMinutes or 0
    if mhExp and mhExp > 0 and (mhExp / 60000) <= minutes then
        return true
    end
    return false, sel.name .. " is still active with more than " .. minutes
                  .. " min left; not recasting."
end

-- Maximum charges of a shield: the number in its spell tooltip ("3 charges"),
-- or the highest count ever seen on the buff, whichever is larger. 0 = unknown.
local function ShieldMaxCharges(sel)
    local max = 0

    PrepTip()
    scanTip:SetSpell(sel.index, BOOKTYPE_SPELL)
    for i = 1, scanTip:NumLines() do
        local line = getglobal("ShamShieldScanTipTextLeft" .. i)
        local text = line and line:GetText()
        if text then
            local _, _, n = string.find(text, "(%d+) charges?")
            if n then
                max = tonumber(n)
                break
            end
        end
    end

    local seen = ShamShieldDB.maxSeen and ShamShieldDB.maxSeen[sel.name]
    if seen and seen > max then max = seen end
    return max
end

-- Low-mana override: when your mana is below waterShieldManaPercent (0 = off)
-- and Water Shield is learned, the shield button and the hotkey cast Water
-- Shield instead of the selected shield, ignoring every other shield setting.
-- Returns the Water Shield spell entry while the override is active, else nil.
local function LowManaWaterShield()
    local pct = ShamShieldDB.waterShieldManaPercent or 0
    if pct <= 0 then return nil end

    local maxMana = UnitManaMax("player")
    if not maxMana or maxMana <= 0 then return nil end
    if UnitMana("player") / maxMana * 100 >= pct then return nil end

    return FindKnown(shieldSlot, "Water Shield")
end

-- Low-health override: when your health is below earthShieldHealthPercent
-- (0 = off) and Earth Shield is learned, the shield button and hotkey cast
-- Earth Shield instead of the selected shield. Returns the spell entry or nil.
local function LowHealthEarthShield()
    local pct = ShamShieldDB.earthShieldHealthPercent or 0
    if pct <= 0 then return nil end

    local maxHealth = UnitHealthMax("player")
    if not maxHealth or maxHealth <= 0 then return nil end
    if UnitIsDeadOrGhost("player") then return nil end
    if UnitHealth("player") / maxHealth * 100 >= pct then return nil end

    return FindKnown(shieldSlot, "Earth Shield")
end

-- Mana cost of a spell, read from its tooltip ("123 Mana"). 0 = unknown.
local function SpellManaCost(sp)
    PrepTip()
    scanTip:SetSpell(sp.index, BOOKTYPE_SPELL)
    for i = 1, scanTip:NumLines() do
        local line = getglobal("ShamShieldScanTipTextLeft" .. i)
        local text = line and line:GetText()
        if text then
            local _, _, n = string.find(text, "(%d+) Mana")
            if n then return tonumber(n) end
        end
    end
    return 0
end

-- The shield the addon will cast instead of the selected one, if any.
--   * Critical health (Earth Shield option) and enough mana for Earth Shield
--       -> Earth Shield
--   * Critical health but NOT enough mana for Earth Shield
--       -> Water Shield (if learned), whatever the mana option says
--   * Otherwise low mana (Water Shield option) -> Water Shield
local function AutoShield()
    local earth = LowHealthEarthShield()
    if earth then
        local cost = SpellManaCost(earth)
        if cost <= 0 or UnitMana("player") >= cost then
            return earth
        end
        local water = FindKnown(shieldSlot, "Water Shield")
        if water then return water end
        return earth   -- no Water Shield to fall back on
    end
    return LowManaWaterShield()
end

-- May the addon cast the selected shield right now? Not if that same shield is
-- already up with its maximum charges (recasting would waste the mana).
-- Selecting a different shield is still allowed: that is a swap, not a refresh.
local function CanCastShield()
    if AutoShield() then return true end

    local sel = FindKnown(shieldSlot, GetSelected(shieldSlot))
    if not sel then return false end

    -- Optional override: Water Shield may always be recast, ignoring the
    -- maximum-charges rule and both refresh thresholds below.
    if sel.name == "Water Shield" and ShamShieldDB.alwaysRecastWater then
        return true
    end

    local st = shieldSlot.state
    if not st.active then return true end

    -- Never refresh a shield that is already full.
    if st.count > 0 then
        local max = ShieldMaxCharges(sel)
        if max > 0 and st.count >= max then
            return false, sel.name .. " is already at maximum charges (" .. max .. ")."
        end
    end

    -- Optional thresholds (0 = that threshold is off). When either is on, an
    -- active shield may only be refreshed once it is low enough on charges OR
    -- on time.
    local minStacks = ShamShieldDB.shieldRefreshStacks or 0
    local minMinutes = ShamShieldDB.shieldRefreshMinutes or 0
    if minStacks > 0 or minMinutes > 0 then
        local low = false
        if minStacks > 0 and st.count > 0 and st.count <= minStacks then
            low = true
        end
        if minMinutes > 0 and st.hasTimer and st.expire
           and (st.expire - GetTime()) / 60 <= minMinutes then
            low = true
        end
        if not low then
            return false, sel.name .. " is not low enough to refresh yet (see /ss config)."
        end
    end
    return true
end

-- The single hotkey (called by Bindings.xml): the weapon buff first if it is
-- allowed (see above), otherwise the selected shield.
function ShamShield_Cast()
    if not AutoShield() and CanCastWeaponBuff() then
        CastSelected(weaponSlot)
    else
        CastSelected(shieldSlot)
    end
end

BINDING_HEADER_SHAMSHIELD = "ShamShield"
BINDING_NAME_SHAMSHIELD_CAST = "Cast Weapon Buff, then Shield"

---------------------------------------------------------------------------
-- Slot factory: builds the frames for one slot and wires up its scripts
---------------------------------------------------------------------------
local function CreateSlot(cfg)
    local slot = {
        cfg = cfg,
        known = {},
        flyBtns = {},
        state = { active = false, anyShield = false, mounted = false, count = 0, expire = nil, hasTimer = false },
        prevActive = false,
        prevCount = 0,
    }

    local holder = CreateFrame("Frame", "ShamShield" .. cfg.name .. "Slot", root)
    holder:SetWidth(MAIN_SIZE)
    holder:SetHeight(MAIN_SIZE + TOGGLE_H)
    holder:SetPoint(cfg.anchor, root, cfg.anchor, 0, 0)
    slot.holder = holder

    -- Large cast button -----------------------------------------------------
    local main = CreateFrame("Button", "ShamShield" .. cfg.name .. "Button", holder)
    main:SetWidth(MAIN_SIZE)
    main:SetHeight(MAIN_SIZE)
    main:SetPoint("BOTTOM", holder, "BOTTOM", 0, 0)
    main:RegisterForClicks("LeftButtonUp")
    main:RegisterForDrag("LeftButton")
    main:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
    main:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    slot.main = main

    local icon = main:CreateTexture(nil, "BACKGROUND")
    icon:SetAllPoints(main)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetTexture(UNKNOWN_ICON)
    slot.icon = icon

    -- Low-mana warning: Water Shield's icon fades over the selected shield's.
    -- ARTWORK layer keeps the status text drawn on top of it.
    local overlay = main:CreateTexture(nil, "ARTWORK")
    overlay:SetAllPoints(main)
    overlay:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    overlay:SetAlpha(PULSE_MIN)
    overlay:Hide()
    slot.overlay = overlay

    local statusText = main:CreateFontString(nil, "OVERLAY")
    statusText:SetFont(FONT, 11, "OUTLINE")
    statusText:SetPoint("BOTTOM", main, "BOTTOM", 0, 3)
    slot.statusText = statusText

    local countText = main:CreateFontString(nil, "OVERLAY")
    countText:SetFont(FONT, 12, "OUTLINE")
    countText:SetPoint("TOPRIGHT", main, "TOPRIGHT", -2, -2)
    slot.countText = countText

    -- Big charge number shown instead of the other text while in combat.
    local combatText = main:CreateFontString(nil, "OVERLAY")
    combatText:SetFont(FONT, 28, "OUTLINE")
    combatText:SetPoint("CENTER", main, "CENTER", 0, 4)
    combatText:Hide()
    slot.combatText = combatText
    slot.combatFontSize = 28

    -- Flyout toggle (arrow above the button) ---------------------------------
    local toggle = CreateFrame("Button", "ShamShield" .. cfg.name .. "Toggle", holder)
    toggle:SetWidth(MAIN_SIZE)
    toggle:SetHeight(TOGGLE_H)
    toggle:SetPoint("BOTTOM", main, "TOP", 0, 0)
    toggle:RegisterForDrag("LeftButton")
    toggle:SetNormalTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up")
    toggle:SetPushedTexture("Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down")
    toggle:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    toggle:GetNormalTexture():SetTexCoord(0.2, 0.8, 0.25, 0.75)
    toggle:GetPushedTexture():SetTexCoord(0.2, 0.8, 0.25, 0.75)
    slot.toggle = toggle

    local flyout = CreateFrame("Frame", "ShamShield" .. cfg.name .. "Flyout", holder)
    flyout:SetFrameStrata("DIALOG")
    flyout:SetWidth(FLY_SIZE)
    flyout:SetHeight(FLY_SIZE)
    flyout:SetPoint("BOTTOM", toggle, "TOP", 0, 2)
    flyout:Hide()
    slot.flyout = flyout

    -- Scripts ------------------------------------------------------------------
    main:SetScript("OnDragStart", StartDrag)
    main:SetScript("OnDragStop", StopDrag)
    toggle:SetScript("OnDragStart", StartDrag)
    toggle:SetScript("OnDragStop", StopDrag)

    main:SetScript("OnClick", function()
        CastSelected(slot, true)
    end)

    main:SetScript("OnEnter", function()
        local sel = FindKnown(slot, GetSelected(slot))
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        if sel then
            if sel.isItem then
                local bag, sl = FindBagItem(sel.name)
                if bag then
                    GameTooltip:SetBagItem(bag, sl)
                else
                    GameTooltip:SetText(sel.name)
                    GameTooltip:AddLine("None in your bags", 0.6, 0.6, 0.6)
                end
            else
                GameTooltip:SetSpell(sel.index, BOOKTYPE_SPELL)
            end
            local auto = cfg.overrideSpell and cfg.overrideSpell()
            if auto then
                GameTooltip:AddLine("Auto: casts " .. auto.name, 0.4, 0.8, 1)
            end
            GameTooltip:AddLine("Shift-drag: move", 0.7, 0.7, 0.7)
        else
            GameTooltip:SetText(cfg.noneText)
        end
        GameTooltip:Show()
    end)
    main:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    toggle:SetScript("OnClick", function()
        if flyout:IsShown() then
            flyout:Hide()
        else
            LayoutFlyout(slot)
            if slot.shownCount > 0 then
                flyout.idle = 0
                flyout:Show()
            end
        end
    end)
    toggle:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
        GameTooltip:SetText(cfg.chooseText)
        GameTooltip:Show()
    end)
    toggle:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Auto-close the flyout shortly after the mouse leaves it.
    flyout:SetScript("OnUpdate", function()
        if MouseIsOver(flyout) or MouseIsOver(toggle) then
            this.idle = 0
        else
            this.idle = (this.idle or 0) + arg1
            if this.idle > 0.6 then this:Hide() end
        end
    end)

    table.insert(slots, slot)
    return slot
end

shieldSlot = CreateSlot({
    name = "Shield",
    spells = SHIELDS,
    dbKey = "selected",
    anchor = "BOTTOMLEFT",
    scan = ScanShield,
    canCast = CanCastShield,
    overrideSpell = AutoShield,
    chargeSounds = true,
    combatOffText = "0",
    combatOffSize = 28,
    noneText = "No shield spells learned",
    chooseText = "Choose shield",
})

weaponSlot = CreateSlot({
    name = "Weapon",
    spells = WEAPON_BUFFS,
    dbKey = "selectedWeapon",
    anchor = "BOTTOMRIGHT",
    scan = ScanWeapon,
    canCast = CanCastWeaponBuff,
    items = WEAPON_ITEMS,
    chargeSounds = false,
    combatOffText = "OFF",
    combatOffSize = 16,
    noneText = "No weapon buff spells learned",
    chooseText = "Choose weapon buff",
})

---------------------------------------------------------------------------
-- Combat options (set in /ss config)
---------------------------------------------------------------------------
-- combatNoMouse:    buttons ignore the mouse while in combat (hotkey still works)
-- combatHideFlyout: flyout arrows and open flyout lists are hidden in combat
local function ApplyCombatSettings()
    local inCombat = UnitAffectingCombat("player")
    local noMouse = inCombat and ShamShieldDB.combatNoMouse
    local hideFlyout = inCombat and ShamShieldDB.combatHideFlyout

    for i = 1, table.getn(slots) do
        local slot = slots[i]

        slot.main:EnableMouse(not noMouse)
        slot.toggle:EnableMouse(not noMouse)

        if noMouse or hideFlyout then
            slot.flyout:Hide()
        end

        if hideFlyout then
            slot.toggle:Hide()
        else
            slot.toggle:Show()
        end
    end

    if noMouse then
        GameTooltip:Hide()
    end
end

---------------------------------------------------------------------------
-- Events / timers
---------------------------------------------------------------------------
local tick = 0
local soundElapsed = 0
local bagDirty = false
local pulseActive = false
local pulseSpell = nil
local pulseTime = 0

local function ShieldMissing()
    return table.getn(shieldSlot.known) > 0
       and not shieldSlot.state.active and not shieldSlot.state.anyShield
end

root:SetScript("OnUpdate", function()
    tick = tick + arg1
    if tick >= 0.25 then
        tick = 0
        if bagDirty then
            bagDirty = false
            ScanSpellbook(weaponSlot)   -- bags changed: refresh the item entries
        end
        -- Re-scan: refreshes countdowns and catches charge / imbue changes.
        for i = 1, table.getn(slots) do
            Refresh(slots[i])
        end

        -- Auto-shield warning overlay: shown while Earth / Water Shield would be auto-cast
        -- over a different selected shield.
        local ws = AutoShield()
        if ws and ws.name ~= GetSelected(shieldSlot) then
            if not pulseActive or pulseSpell ~= ws.name then
                pulseActive = true
                pulseSpell = ws.name
                pulseTime = 0
                shieldSlot.overlay:SetTexture(ws.texture)
                shieldSlot.overlay:Show()
            end
        elseif pulseActive then
            pulseActive = false
            shieldSlot.overlay:Hide()
        end
    end

    -- Fade the overlay back and forth between PULSE_MIN and PULSE_MAX.
    if pulseActive then
        pulseTime = pulseTime + arg1
        local mid = (PULSE_MAX + PULSE_MIN) / 2
        local amp = (PULSE_MAX - PULSE_MIN) / 2
        shieldSlot.overlay:SetAlpha(mid + amp * math.sin(pulseTime * 2 * math.pi / PULSE_PERIOD))
    end

    -- Combat alert: first plays SOUND_INTERVAL seconds after the shield goes
    -- missing (so it does not overlap the "shield used up" sound), then repeats.
    if ShamShieldDB.sound ~= false and UnitAffectingCombat("player")
       and not UnitIsDeadOrGhost("player") and not shieldSlot.state.mounted
       and ShieldMissing() then
        soundElapsed = soundElapsed + arg1
        if soundElapsed >= SOUND_INTERVAL then
            soundElapsed = 0
            PlayKind("alert")
        end
    else
        soundElapsed = 0
    end
end)

root:RegisterEvent("ADDON_LOADED")
root:RegisterEvent("PLAYER_ENTERING_WORLD")
root:RegisterEvent("SPELLS_CHANGED")
root:RegisterEvent("LEARNED_SPELL_IN_TAB")
root:RegisterEvent("PLAYER_AURAS_CHANGED")
root:RegisterEvent("BAG_UPDATE")
root:RegisterEvent("REPLACE_ENCHANT")
root:RegisterEvent("UNIT_INVENTORY_CHANGED")
root:RegisterEvent("PLAYER_REGEN_DISABLED")
root:RegisterEvent("PLAYER_REGEN_ENABLED")

root:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" then
        if arg1 ~= "ShamShield" then return end
        local localized, token = UnitClass("player")
        if localized ~= "Shaman" and token ~= "SHAMAN" then
            root:Hide()
            root:UnregisterAllEvents()
            return
        end
        SyncTrackedItems()
        local sc = ShamShieldDB.scale
        if not sc or sc < 0.5 or sc > 2 then sc = 1 end
        root:SetScale(sc)          -- before RestorePosition: offsets use this scale
        RestorePosition()
        ApplyCombatSettings()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "SPELLS_CHANGED"
        or event == "LEARNED_SPELL_IN_TAB" then
        for i = 1, table.getn(slots) do ScanSpellbook(slots[i]) end
        ApplyCombatSettings()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        for i = 1, table.getn(slots) do UpdateDisplay(slots[i]) end
        ApplyCombatSettings()
    elseif event == "BAG_UPDATE" then
        bagDirty = true
    elseif event == "REPLACE_ENCHANT" then
        -- Only auto-confirm the "replace enchant?" popup for an item the addon
        -- just applied itself (CanCastWeaponBuff already vetted the overwrite).
        if pendingReplace and GetTime() - pendingReplace < 3 then
            pendingReplace = nil
            ReplaceEnchant()
            StaticPopup_Hide("REPLACE_ENCHANT")
        end
    elseif event == "UNIT_INVENTORY_CHANGED" then
        if arg1 == "player" then Refresh(slots[2]) end
    else
        for i = 1, table.getn(slots) do Refresh(slots[i]) end
    end
end)

---------------------------------------------------------------------------
-- Config window (/ss or /ss config), organised in tabs
---------------------------------------------------------------------------
local CONFIG_TABS = { "General", "Visuals", "Limits", "Items", "Sounds" }

-- Checkbox options. To add one: add a line here (pick its tab) and read
-- ShamShieldDB[key] where needed.
local CONFIG_OPTIONS = {
    { tab = "General", key = "locked",           label = "Lock the frame position (no moving)" },
    { tab = "General", key = "combatNoMouse",    label = "Make the frame non-interactable in combat" },
    { tab = "General", key = "combatHideFlyout", label = "Hide the flyout buttons in combat" },
    { tab = "Limits",  key = "alwaysRecastWater", label = "Always allow Water Shield recast" },
    { tab = "Limits",  key = "neverOverwriteItems", label = "Never overwrite item buffs (oils, stones)" },
}

-- Number options: typed into a box. max caps the value, 0 is always allowed.
local NUMBER_OPTIONS = {
    { tab = "Limits", key = "recastMinutes", unit = "minutes", max = 120, integer = false,
      label = "Weapon imbue: recast it only when it has this many minutes "
              .. "(or fewer) left. 0 = never refresh an active imbue. "
              .. "Stones, oils and poisons are never overwritten." },
    { tab = "Limits", key = "shieldRefreshStacks", unit = "charges", max = 99, integer = true,
      label = "Shield: refresh it only when it has this many charges "
              .. "(or fewer) left. 0 = off. A full shield is never refreshed." },
    { tab = "Limits", key = "shieldRefreshMinutes", unit = "minutes", max = 120, integer = false,
      label = "Shield: refresh it only when it has this many minutes "
              .. "(or fewer) left. 0 = off. If both shield options are on, "
              .. "either one allows a refresh." },
    { tab = "Limits", key = "earthShieldHealthPercent", unit = "% health", max = 100, integer = true,
      label = "Health: below this percentage of your health, the shield button "
              .. "and hotkey always cast Earth Shield (if learned), ignoring all "
              .. "other shield settings. Takes priority over the mana option. 0 = off." },
    { tab = "Limits", key = "waterShieldManaPercent", unit = "% mana", max = 100, integer = true,
      label = "Mana: below this percentage of your mana, the shield button and "
              .. "hotkey always cast Water Shield (if learned), ignoring all "
              .. "other shield settings. 0 = off." },
}
local NUMBER_ROW_H = 74
local ITEM_ROW_H = 26
local SCALE_MIN, SCALE_MAX = 0.5, 2.0
local PAGE_TOP = 66          -- distance from the top of the window to a page
local PAGE_PAD = 18          -- space under the last row of a page

local config

local function ShowNumber(box)
    box:SetText(tostring(ShamShieldDB[box.opt.key] or 0))
end

local function CommitNumber(box)
    local opt = box.opt
    local n = tonumber(box:GetText())
    if n and n >= 0 then
        if n > opt.max then n = opt.max end
        if opt.integer then n = math.floor(n) end
        ShamShieldDB[opt.key] = n
    end
    ShowNumber(box)   -- normalise, or revert if the entry was invalid
end

-- UI scale: one decimal, SCALE_MIN..SCALE_MAX. Scales the whole ShamShield
-- frame around its centre so it does not jump across the screen.
local function RoundScale(n)
    n = math.floor(n * 10 + 0.5) / 10
    if n < SCALE_MIN then n = SCALE_MIN end
    if n > SCALE_MAX then n = SCALE_MAX end
    return n
end

local function ApplyScale(newScale)
    newScale = RoundScale(newScale)
    ShamShieldDB.scale = newScale

    local oldScale = root:GetScale()
    if math.abs(oldScale - newScale) < 0.001 then return end

    local left, bottom = root:GetLeft(), root:GetBottom()
    local w, h = root:GetWidth(), root:GetHeight()
    root:SetScale(newScale)

    if left and bottom then
        local ratio = oldScale / newScale
        local x = (left + w / 2) * ratio - w / 2
        local y = (bottom + h / 2) * ratio - h / 2
        root:ClearAllPoints()
        root:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
        ShamShieldDB.x = x
        ShamShieldDB.y = y
    end
end

local function CreateConfigFrame()
    local f = CreateFrame("Frame", "ShamShieldConfig", UIParent)
    f:SetWidth(360)
    f:SetHeight(200)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    f:SetFrameStrata("DIALOG")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function() this:StartMoving() end)
    f:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -18)
    title:SetText("ShamShield Options")

    local close = CreateFrame("Button", "ShamShieldConfigClose", f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    f.pages = {}
    f.tabButtons = {}
    f.checks = {}
    f.boxes = {}

    -- Sound picker popup: one shared list, reopened under whichever picker
    -- button was clicked. Choosing an entry saves it and previews the sound.
    local function OpenSoundPicker(btn)
        local picker = f.soundPicker
        if not picker then
            picker = CreateFrame("Frame", "ShamShieldSoundPicker", f)
            picker:SetFrameStrata("FULLSCREEN_DIALOG")
            picker:SetWidth(224)
            picker:SetHeight(table.getn(SOUND_CHOICES) * 18 + 16)
            picker:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 16,
                insets = { left = 4, right = 4, top = 4, bottom = 4 },
            })
            picker:SetBackdropColor(0, 0, 0, 1)
            picker:EnableMouse(true)

            for i = 1, table.getn(SOUND_CHOICES) do
                local b = CreateFrame("Button", nil, picker)
                b:SetWidth(208)
                b:SetHeight(18)
                b:SetPoint("TOPLEFT", picker, "TOPLEFT", 8, -(8 + (i - 1) * 18))
                b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                local t = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                t:SetPoint("LEFT", b, "LEFT", 4, 0)
                t:SetText(SOUND_CHOICES[i].name)
                b.choice = SOUND_CHOICES[i]
                b:SetScript("OnClick", function()
                    local kind = picker.kind
                    ShamShieldDB.sounds = ShamShieldDB.sounds or {}
                    ShamShieldDB.sounds[kind] = this.choice.sound
                    if picker.owner then picker.owner:SetText(this.choice.name) end
                    picker:Hide()
                    PlayKind(kind, true)
                end)
            end

            -- Close shortly after the mouse leaves the list and its button.
            picker:SetScript("OnUpdate", function()
                if MouseIsOver(this) or (this.owner and MouseIsOver(this.owner)) then
                    this.idle = 0
                else
                    this.idle = (this.idle or 0) + arg1
                    if this.idle > 0.8 then this:Hide() end
                end
            end)
            picker:Hide()
            f.soundPicker = picker
        end

        if picker:IsShown() and picker.owner == btn then
            picker:Hide()
            return
        end
        picker.owner = btn
        picker.kind = btn.kind
        picker.idle = 0
        picker:ClearAllPoints()
        picker:SetPoint("TOPLEFT", btn, "BOTTOMLEFT", 0, -2)
        picker:Show()
    end

    local checkIndex = 0
    local boxIndex = 0

    -- Builds the contents of one tab and returns its page frame -----------------
    local function BuildPage(tabName)
        local page = CreateFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -PAGE_TOP)
        page:SetWidth(360)
        local y = 0   -- how far down the next row goes

        -- Checkboxes
        for i = 1, table.getn(CONFIG_OPTIONS) do
            local opt = CONFIG_OPTIONS[i]
            if opt.tab == tabName then
                checkIndex = checkIndex + 1
                local cb = CreateFrame("CheckButton", "ShamShieldConfigCheck" .. checkIndex,
                                       page, "OptionsCheckButtonTemplate")
                cb:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -y)
                getglobal(cb:GetName() .. "Text"):SetText(opt.label)
                cb.dbKey = opt.key
                cb:SetScript("OnClick", function()
                    if this:GetChecked() then
                        ShamShieldDB[this.dbKey] = true
                        PlaySound("igMainMenuOptionCheckBoxOn")
                    else
                        ShamShieldDB[this.dbKey] = nil
                        PlaySound("igMainMenuOptionCheckBoxOff")
                    end
                    ApplyCombatSettings()
                end)
                table.insert(f.checks, cb)
                y = y + 28
            end
        end

        -- Visuals: UI scale slider + numeric box
        if tabName == "Visuals" then
            local slider = CreateFrame("Slider", "ShamShieldConfigScale", page,
                                       "OptionsSliderTemplate")
            slider:SetWidth(200)
            slider:SetPoint("TOPLEFT", page, "TOPLEFT", 34, -(y + 26))
            slider:SetMinMaxValues(SCALE_MIN, SCALE_MAX)
            slider:SetValueStep(0.1)
            getglobal("ShamShieldConfigScaleText"):SetText("UI scale")
            getglobal("ShamShieldConfigScaleLow"):SetText(string.format("%.1f", SCALE_MIN))
            getglobal("ShamShieldConfigScaleHigh"):SetText(string.format("%.1f", SCALE_MAX))

            local box = CreateFrame("EditBox", "ShamShieldConfigScaleBox", page,
                                    "InputBoxTemplate")
            box:SetWidth(46)
            box:SetHeight(20)
            box:SetPoint("LEFT", slider, "RIGHT", 22, 0)
            box:SetAutoFocus(false)
            box:SetMaxLetters(4)

            f.scaleSlider = slider
            f.scaleBox = box

            slider:SetScript("OnValueChanged", function()
                if f.syncing then return end
                local v = RoundScale(this:GetValue())
                box:SetText(string.format("%.1f", v))
                ApplyScale(v)
            end)

            local function CommitScale()
                local n = tonumber(box:GetText())
                if n then
                    n = RoundScale(n)
                    f.syncing = true
                    slider:SetValue(n)
                    f.syncing = false
                    ApplyScale(n)
                end
                box:SetText(string.format("%.1f", ShamShieldDB.scale or 1))
            end
            box:SetScript("OnEnterPressed", function()
                CommitScale()
                this:ClearFocus()
            end)
            box:SetScript("OnEditFocusLost", CommitScale)
            box:SetScript("OnEscapePressed", function()
                box:SetText(string.format("%.1f", ShamShieldDB.scale or 1))
                this:ClearFocus()
                f:Hide()                 -- Escape closes the window even while typing
            end)

            y = y + 70
        end

        -- Number boxes
        for j = 1, table.getn(NUMBER_OPTIONS) do
            local opt = NUMBER_OPTIONS[j]
            if opt.tab == tabName then
                boxIndex = boxIndex + 1

                local label = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                label:SetPoint("TOPLEFT", page, "TOPLEFT", 26, -(y + 6))
                label:SetWidth(310)
                label:SetJustifyH("LEFT")
                label:SetText(opt.label)

                local box = CreateFrame("EditBox", "ShamShieldConfigNumber" .. boxIndex,
                                        page, "InputBoxTemplate")
                box:SetWidth(50)
                box:SetHeight(20)
                box:SetPoint("TOPLEFT", page, "TOPLEFT", 32, -(y + 50))
                box:SetAutoFocus(false)
                box:SetMaxLetters(5)
                box.opt = opt

                local unit = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                unit:SetPoint("LEFT", box, "RIGHT", 6, 0)
                unit:SetText(opt.unit)

                box:SetScript("OnEnterPressed", function()
                    CommitNumber(this)
                    this:ClearFocus()
                end)
                box:SetScript("OnEditFocusLost", function()
                    CommitNumber(this)
                end)
                box:SetScript("OnEscapePressed", function()
                    ShowNumber(this)     -- drop anything typed but not confirmed
                    this:ClearFocus()
                    f:Hide()             -- Escape closes the window even while typing
                end)

                table.insert(f.boxes, box)
                y = y + NUMBER_ROW_H
            end
        end

        -- Items: the player's own list of weapon buff items ------------------------
        if tabName == "Items" then
            local intro = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            intro:SetPoint("TOPLEFT", page, "TOPLEFT", 26, -(y + 4))
            intro:SetWidth(310)
            intro:SetJustifyH("LEFT")
            intro:SetText("Items tracked as weapon buffs (oils, stones, ...). Tick a box "
                          .. "to show the item in the weapon flyout; untick to hide it. "
                          .. "Type the exact item name to add one.")
            y = y + 56

            local box = CreateFrame("EditBox", "ShamShieldConfigItemBox", page, "InputBoxTemplate")
            box:SetWidth(200)
            box:SetHeight(20)
            box:SetPoint("TOPLEFT", page, "TOPLEFT", 32, -y)
            box:SetAutoFocus(false)
            box:SetMaxLetters(60)

            local add = CreateFrame("Button", "ShamShieldConfigItemAdd", page, "UIPanelButtonTemplate")
            add:SetWidth(60)
            add:SetHeight(22)
            add:SetPoint("LEFT", box, "RIGHT", 10, 0)
            add:SetText("Add")
            y = y + 30

            local restore = CreateFrame("Button", "ShamShieldConfigItemRestore", page,
                                        "UIPanelButtonTemplate")
            restore:SetWidth(170)
            restore:SetHeight(22)
            restore:SetPoint("TOPLEFT", page, "TOPLEFT", 28, -y)
            restore:SetText("Restore default oils")
            y = y + 34

            f.itemListTop = y
            f.itemRows = {}

            local RefreshItemRows

            local function HasTrackedItem(name)
                local lname = string.lower(name)
                for i = 1, table.getn(ShamShieldDB.weaponItems) do
                    if string.lower(ShamShieldDB.weaponItems[i]) == lname then
                        return true
                    end
                end
                return false
            end

            -- Rebuild the live list and the weapon flyout after any change.
            local function ItemsChanged()
                SyncTrackedItems()
                ScanSpellbook(weaponSlot)
                RefreshItemRows()
            end

            local function DoAdd()
                local text = box:GetText() or ""
                local _, _, linked = string.find(text, "%[(.-)%]")   -- pasted item link
                local name = linked or text
                name = string.gsub(name, "^%s+", "")
                name = string.gsub(name, "%s+$", "")
                if name == "" then return end

                if HasTrackedItem(name) then
                    DEFAULT_CHAT_FRAME:AddMessage("ShamShield: " .. name .. " is already tracked.")
                    return
                end
                table.insert(ShamShieldDB.weaponItems, name)
                box:SetText("")
                ItemsChanged()
            end

            local function RemoveItem(name)
                for i = 1, table.getn(ShamShieldDB.weaponItems) do
                    if ShamShieldDB.weaponItems[i] == name then
                        table.remove(ShamShieldDB.weaponItems, i)
                        break
                    end
                end
                if ShamShieldDB.hiddenItems then ShamShieldDB.hiddenItems[name] = nil end
                ItemsChanged()
            end

            add:SetScript("OnClick", DoAdd)
            box:SetScript("OnEnterPressed", function()
                DoAdd()
                this:ClearFocus()
            end)
            box:SetScript("OnEscapePressed", function()
                this:SetText("")
                this:ClearFocus()
                f:Hide()
            end)

            restore:SetScript("OnClick", function()
                for i = 1, table.getn(DEFAULT_WEAPON_ITEMS) do
                    if not HasTrackedItem(DEFAULT_WEAPON_ITEMS[i]) then
                        table.insert(ShamShieldDB.weaponItems, DEFAULT_WEAPON_ITEMS[i])
                    end
                end
                ItemsChanged()
            end)

            local function GetItemRow(i)
                if f.itemRows[i] then return f.itemRows[i] end

                local row = CreateFrame("Frame", nil, page)
                row:SetWidth(330)
                row:SetHeight(ITEM_ROW_H)
                row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -(f.itemListTop + (i - 1) * ITEM_ROW_H))

                local cb = CreateFrame("CheckButton", "ShamShieldConfigItemShow" .. i, row,
                                       "OptionsCheckButtonTemplate")
                cb:SetPoint("LEFT", row, "LEFT", 22, 0)
                cb:SetScript("OnClick", function()
                    local name = this:GetParent().itemName
                    ShamShieldDB.hiddenItems = ShamShieldDB.hiddenItems or {}
                    if this:GetChecked() then
                        ShamShieldDB.hiddenItems[name] = nil     -- shown
                    else
                        ShamShieldDB.hiddenItems[name] = true    -- hidden
                    end
                    ScanSpellbook(weaponSlot)
                end)
                row.check = cb

                local rm = CreateFrame("Button", "ShamShieldConfigItemRemove" .. i, row,
                                       "UIPanelButtonTemplate")
                rm:SetWidth(64)
                rm:SetHeight(20)
                rm:SetPoint("RIGHT", row, "RIGHT", -22, 0)
                rm:SetText("Remove")
                rm:SetScript("OnClick", function()
                    RemoveItem(this:GetParent().itemName)
                end)

                f.itemRows[i] = row
                return row
            end

            RefreshItemRows = function()
                local list = ShamShieldDB.weaponItems or {}
                local n = table.getn(list)

                for i = 1, n do
                    local row = GetItemRow(i)
                    row.itemName = list[i]
                    getglobal(row.check:GetName() .. "Text"):SetText(list[i])
                    if ShamShieldDB.hiddenItems and ShamShieldDB.hiddenItems[list[i]] then
                        row.check:SetChecked(nil)
                    else
                        row.check:SetChecked(1)
                    end
                    row:Show()
                end
                for i = n + 1, table.getn(f.itemRows) do
                    f.itemRows[i]:Hide()
                end

                local rows = n
                if rows < 1 then rows = 1 end
                page.height = f.itemListTop + rows * ITEM_ROW_H + 8
                page:SetHeight(page.height)
                -- grow / shrink the window if this tab is the one showing
                if f.currentTab and f.pages[f.currentTab] == page then
                    f:SetHeight(PAGE_TOP + page.height + PAGE_PAD)
                end
            end
            f.refreshItems = RefreshItemRows

            y = f.itemListTop
        end

        -- Sounds: pick the sound for each alert ---------------------------------
        if tabName == "Sounds" then
            local intro = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            intro:SetPoint("TOPLEFT", page, "TOPLEFT", 26, -(y + 4))
            intro:SetWidth(310)
            intro:SetJustifyH("LEFT")
            intro:SetText("Choose the sound for each warning. Click Test to hear it. "
                          .. "Untick a warning to turn it off. /ss sound switches all of them off.")
            y = y + 44

            f.soundButtons = {}
            f.soundChecks = {}
            for k = 1, table.getn(SOUND_KINDS) do
                local kind = SOUND_KINDS[k]

                -- Checkbox: ticked = this warning is on.
                local cb = CreateFrame("CheckButton", "ShamShieldConfigSoundOn" .. k, page,
                                       "OptionsCheckButtonTemplate")
                cb:SetPoint("TOPLEFT", page, "TOPLEFT", 22, -y)
                getglobal(cb:GetName() .. "Text"):SetText(kind.label)
                cb.kind = kind.key
                cb:SetScript("OnClick", function()
                    ShamShieldDB.soundOff = ShamShieldDB.soundOff or {}
                    if this:GetChecked() then
                        ShamShieldDB.soundOff[this.kind] = nil
                        PlaySound("igMainMenuOptionCheckBoxOn")
                    else
                        ShamShieldDB.soundOff[this.kind] = true
                        PlaySound("igMainMenuOptionCheckBoxOff")
                    end
                end)
                f.soundChecks[k] = cb

                local btn = CreateFrame("Button", "ShamShieldConfigSound" .. k, page,
                                        "UIPanelButtonTemplate")
                btn:SetWidth(210)
                btn:SetHeight(22)
                btn:SetPoint("TOPLEFT", page, "TOPLEFT", 28, -(y + 32))
                btn.kind = kind.key
                btn:SetScript("OnClick", function()
                    OpenSoundPicker(this)
                end)
                f.soundButtons[k] = btn

                local test = CreateFrame("Button", "ShamShieldConfigSoundTest" .. k, page,
                                         "UIPanelButtonTemplate")
                test:SetWidth(60)
                test:SetHeight(22)
                test:SetPoint("LEFT", btn, "RIGHT", 8, 0)
                test:SetText("Test")
                test.kind = kind.key
                test:SetScript("OnClick", function()
                    PlayKind(this.kind, true)
                end)

                y = y + 64
            end
        end

        page.height = y
        page:SetHeight(y)
        page:Hide()
        return page
    end

    -- Tabs ---------------------------------------------------------------------
    local function SelectTab(index)
        f.currentTab = index
        for i = 1, table.getn(CONFIG_TABS) do
            if i == index then
                f.pages[i]:Show()
                f.tabButtons[i]:Disable()    -- the active tab looks pressed / greyed
            else
                f.pages[i]:Hide()
                f.tabButtons[i]:Enable()
            end
        end
        if f.soundPicker then f.soundPicker:Hide() end
        f:SetHeight(PAGE_TOP + f.pages[index].height + PAGE_PAD)
    end

    for i = 1, table.getn(CONFIG_TABS) do
        f.pages[i] = BuildPage(CONFIG_TABS[i])

        local tab = CreateFrame("Button", "ShamShieldConfigTab" .. i, f, "UIPanelButtonTemplate")
        tab:SetWidth(64)
        tab:SetHeight(22)
        tab:SetPoint("TOPLEFT", f, "TOPLEFT", 18 + (i - 1) * 66, -40)
        tab:SetText(CONFIG_TABS[i])
        tab.index = i
        tab:SetScript("OnClick", function()
            PlaySound("igMainMenuOptionCheckBoxOn")
            SelectTab(this.index)
        end)
        f.tabButtons[i] = tab
    end

    -- Refresh every control from the saved settings each time the window opens.
    f:SetScript("OnShow", function()
        for j = 1, table.getn(this.boxes) do
            ShowNumber(this.boxes[j])
        end
        for i = 1, table.getn(this.checks) do
            local cb = this.checks[i]
            if ShamShieldDB[cb.dbKey] then
                cb:SetChecked(1)
            else
                cb:SetChecked(nil)
            end
        end
        if this.scaleSlider then
            local sc = ShamShieldDB.scale or 1
            this.syncing = true
            this.scaleSlider:SetValue(sc)
            this.syncing = false
            this.scaleBox:SetText(string.format("%.1f", sc))
        end
        if this.refreshItems then this.refreshItems() end
        if this.soundChecks then
            for k = 1, table.getn(this.soundChecks) do
                if KindEnabled(this.soundChecks[k].kind) then
                    this.soundChecks[k]:SetChecked(1)
                else
                    this.soundChecks[k]:SetChecked(nil)
                end
            end
        end
        if this.soundButtons then
            for k = 1, table.getn(this.soundButtons) do
                local btn = this.soundButtons[k]
                local sound = GetKindSound(btn.kind)
                local text = sound
                for i = 1, table.getn(SOUND_CHOICES) do
                    if SOUND_CHOICES[i].sound == sound then text = SOUND_CHOICES[i].name end
                end
                btn:SetText(text)
            end
        end
        SelectTab(this.currentTab or 1)
    end)

    tinsert(UISpecialFrames, "ShamShieldConfig")   -- Escape closes it
    f:Hide()
    return f
end

local function SyncConfigChecks()
    if not config then return end
    for i = 1, table.getn(config.checks) do
        local cb = config.checks[i]
        if ShamShieldDB[cb.dbKey] then
            cb:SetChecked(1)
        else
            cb:SetChecked(nil)
        end
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_SHAMSHIELD1 = "/shamshield"
SLASH_SHAMSHIELD2 = "/ss"
SlashCmdList["SHAMSHIELD"] = function(msg)
    msg = string.lower(msg or "")
    -- "/ss" on its own opens the config window, same as "/ss config".
    if msg == "config" or string.find(msg, "^%s*$") then
        if not config then config = CreateConfigFrame() end
        if config:IsShown() then
            config:Hide()
        else
            config:Show()
        end
    elseif msg == "lock" then
        ShamShieldDB.locked = true
        SyncConfigChecks()
        DEFAULT_CHAT_FRAME:AddMessage("ShamShield: locked.")
    elseif msg == "unlock" then
        ShamShieldDB.locked = nil
        SyncConfigChecks()
        DEFAULT_CHAT_FRAME:AddMessage("ShamShield: unlocked (Shift-drag to move).")
    elseif msg == "sound" then
        if ShamShieldDB.sound == false then
            ShamShieldDB.sound = true
            DEFAULT_CHAT_FRAME:AddMessage("ShamShield: sound alerts ON.")
        else
            ShamShieldDB.sound = false
            DEFAULT_CHAT_FRAME:AddMessage("ShamShield: sound alerts OFF.")
        end
    elseif string.find(msg, "^test") then
        local _, _, which = string.find(msg, "^test%s*(%a*)")
        if which == "low" then
            PlayKind("low", true)
        elseif which == "depleted" then
            PlayKind("depleted", true)
        elseif which == "alert" then
            PlayKind("alert", true)
        else
            DEFAULT_CHAT_FRAME:AddMessage("ShamShield: /ss test low | depleted | alert")
        end
    elseif msg == "debug" then
        -- Prints what the client reports for each of your buffs, so charge
        -- counting problems can be diagnosed.
        local out = function(t) DEFAULT_CHAT_FRAME:AddMessage("ShamShield: " .. t) end
        out("tracking shield = " .. tostring(shieldSlot.state.active and "active" or "not active")
            .. ", count = " .. tostring(shieldSlot.state.count)
            .. ", selected = " .. tostring(GetSelected(shieldSlot)))
        for i = 0, 31 do
            local idx = GetPlayerBuff(i, "HELPFUL")
            if not idx or idx < 0 then break end
            PrepTip()
            scanTip:SetPlayerBuff(idx)
            local name = ShamShieldScanTipTextLeft1:GetText()
            out("buff " .. idx .. ": " .. tostring(name)
                .. " | applications = " .. tostring(GetPlayerBuffApplications(idx))
                .. " | time left = " .. tostring(GetPlayerBuffTimeLeft(idx)))
        end
    elseif msg == "reset" then
        ShamShieldDB.x = nil
        ShamShieldDB.y = nil
        root:ClearAllPoints()
        root:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
        DEFAULT_CHAT_FRAME:AddMessage("ShamShield: position reset.")
    else
        DEFAULT_CHAT_FRAME:AddMessage("ShamShield: /ss config | lock | unlock | reset | sound | test | debug")
    end
end
