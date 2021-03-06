local userEvent = assert(loadScript(SCRIPT_HOME.."/events.lua"))()

local pageStatus =
{
    display     = 2,
    editing     = 3,
    saving      = 4,
    displayMenu = 5,
    close       = 6,
    exit        = 7,
}

local uiMsp =
{
    reboot = 68,
    eepromWrite = 250
}

local currentState = pageStatus.display
local requestTimeout = 80 -- 800ms request timeout
local currentPage = 1
local currentLine = 1
local saveTS = 0
local saveTimeout = 0
local saveRetries = 0
local saveMaxRetries = 0
local pageRequested = false
local telemetryScreenActive = false
local menuActive = false
local lastRunTS = 0
local killEnterBreak = 0
local scrollPixelsY = 0

local Page = nil

local backgroundFill = TEXT_BGCOLOR or ERASE
local foregroundColor = LINE_COLOR or SOLID

local globalTextOptions = TEXT_COLOR or 0

local function saveSettings(new)
    if Page.values then
        if Page.preSave then
            payload = Page.preSave(Page)
        else
            payload = {}
            for i=1,(Page.outputBytes or #Page.values) do
                payload[i] = Page.values[i]
            end
        end
        protocol.mspWrite(Page.write, payload)
        saveTS = getTime()
        if currentState == pageStatus.saving then
            saveRetries = saveRetries + 1
        else
            currentState = pageStatus.saving
            saveRetries = 0
            saveMaxRetries = protocol.saveMaxRetries or 2 -- default 2
            saveTimeout = protocol.saveTimeout or 150     -- default 1.5s
        end
    end
end

local function invalidatePages()
    Page = nil
    currentState = pageStatus.display
    saveTS = 0
end

local function rebootFc()
    protocol.mspRead(uiMsp.reboot)
    invalidatePages()
end

local function eepromWrite()
    protocol.mspRead(uiMsp.eepromWrite)
end
local function exitScript()
    Page = nil
    currentState = pageStatus.close
end

local menuList = {
    {
        t = "Save page",
        f = saveSettings
    },
    {
        t = "Reload",
        f = invalidatePages
    },
    {
        t = "Reboot",
        f = rebootFc
    },
    {
        t = "Exit",
        f = exitScript
    }
}

local function processMspReply(cmd,rx_buf)
    if cmd == nil or rx_buf == nil then
        return
    end
    if cmd == Page.write then
        if Page.eepromWrite then
            eepromWrite()
        else
            invalidatePages()
        end
        pageRequested = false
        return
    end
    if cmd == uiMsp.eepromWrite then
        if Page.reboot then
            rebootFc()
        end
        invalidatePages()
        return
    end
    if cmd ~= Page.read then
        return
    end
    if #(rx_buf) > 0 then
        Page.values = {}
        for i=1,#(rx_buf) do
            Page.values[i] = rx_buf[i]
        end

        for i=1,#(Page.fields) do
            if (#(Page.values) or 0) >= Page.minBytes then
                local f = Page.fields[i]
                if f.vals then
                    f.value = 0;
                    for idx=1, #(f.vals) do
                        local raw_val = (Page.values[f.vals[idx]] or 0)
                        raw_val = bit32.lshift(raw_val, (idx-1)*8)
                        f.value = bit32.bor(f.value, raw_val)
                    end
                    f.value = f.value/(f.scale or 1)
                end
            end
        end
        if Page.postLoad then
            Page.postLoad(Page)
        end
    end
end

local function incMax(val, inc, base)
    return ((val + inc + base - 1) % base) + 1
end

local function incPage(inc)
    currentPage = incMax(currentPage, inc, #(PageFiles))
    Page = nil
    currentLine = 1
    collectgarbage()
end

local function incLine(inc)
    currentLine = clipValue(currentLine + inc, 1, #(Page.fields))
end

local function incMenu(inc)
    menuActive = clipValue(menuActive + inc, 1, #(menuList))
end

local function requestPage()
    if Page.read and ((Page.reqTS == nil) or (Page.reqTS + requestTimeout <= getTime())) then
        Page.reqTS = getTime()
        protocol.mspRead(Page.read)
    end
end

function drawScreenTitle(screen_title)
    if radio.resolution == lcdResolution.low then
        lcd.drawFilledRectangle(0, 0, LCD_W, 10)
        lcd.drawText(1,1,screen_title,INVERS)
    else
        lcd.drawFilledRectangle(0, 0, LCD_W, 30, TITLE_BGCOLOR)
        lcd.drawFilledRectangle(5, 5, 20, 3, MENU_TITLE_COLOR)
        lcd.drawFilledRectangle(5, 13, 20, 3, MENU_TITLE_COLOR)
        lcd.drawFilledRectangle(5, 21, 20, 3, MENU_TITLE_COLOR)
        lcd.drawText(35,5,screen_title, MENU_TITLE_COLOR)
    end
end

local function getField(x, y)
    for i=1,#(Page.fields) do
        local f = Page.fields[i]
        local x_min = f.x - 2;
        local y_min = f.y - 2;
        local val = "---"
        if f.t ~= nil then
            val = f.t
        end
        local h = lcd.getHeight(val, (f.to or 0))
        local w = lcd.getWidth(val, (f.to or 0))
        local y_max = f.y + h
        local x_max = f.x + w
        
        if ( x >= x_min) and (y >= y_min) and (x <= x_max) and (y <= y_max) then
            return i
        end
    end
    return -1
end
local function drawScreen()
    local yMinLim = Page.yMinLimit or 0
    local yMaxLim = Page.yMaxLimit or LCD_H
    local currentLineY = Page.fields[currentLine].y
    local screen_title = Page.title
    drawScreenTitle("Betaflight / "..screen_title)
    if currentLineY <= Page.fields[1].y then
        scrollPixelsY = 0
    elseif currentLineY - scrollPixelsY <= yMinLim then
        scrollPixelsY = currentLineY - yMinLim
    elseif currentLineY - scrollPixelsY >= yMaxLim then
        scrollPixelsY = currentLineY - yMaxLim
    end
    for i=1,#(Page.text) do
        local f = Page.text[i]
        local textOptions = (f.to or 0) + globalTextOptions
        if (f.y - scrollPixelsY) >= yMinLim and (f.y - scrollPixelsY) <= yMaxLim then
            lcd.drawText(f.x, f.y - scrollPixelsY, f.t, textOptions)
        end
    end
    local val = "---"
    for i=1,#(Page.fields) do
        local f = Page.fields[i]
        local text_options = (f.to or 0) + globalTextOptions
        local heading_options = text_options
        local value_options = text_options
        if i == currentLine then
            value_options = text_options + INVERS
            if currentState == pageStatus.editing then
                value_options = value_options + BLINK
            end
        end
        local spacing = 20
        if f.t ~= nil then
            if (f.y - scrollPixelsY) >= yMinLim and (f.y - scrollPixelsY) <= yMaxLim then
                lcd.drawText(f.x, f.y - scrollPixelsY, f.t, heading_options)
            end
            if f.sp ~= nil then
                spacing = f.sp
            end
        else
            spacing = 0
        end
        if f.value then
            if f.upd and Page.values then
                f.upd(Page)
            end
            val = f.value
            if f.table and f.table[f.value] then
                val = f.table[f.value]
            end
        end
        if (f.y - scrollPixelsY) >= yMinLim and (f.y - scrollPixelsY) <= yMaxLim then
            lcd.drawText(f.x + spacing, f.y - scrollPixelsY, val, value_options)
        end
    end
end

function clipValue(val,min,max)
    if val < min then
        val = min
    elseif val > max then
        val = max
    end
    return val
end

local function getCurrentField()
    return Page.fields[currentLine]
end

local function incValue(inc)
    local f = Page.fields[currentLine]
    local idx = f.i or currentLine
    local scale = (f.scale or 1)
    local mult = (f.mult or 1)
    f.value = clipValue(f.value + ((inc*mult)/scale), (f.min/scale) or 0, (f.max/scale) or 255)
    f.value = math.floor((f.value*scale)/mult + 0.5)/(scale/mult)
    for idx=1, #(f.vals) do
        Page.values[f.vals[idx]] = bit32.rshift(math.floor(f.value*scale + 0.5), (idx-1)*8)
    end
    if f.upd and Page.values then
        f.upd(Page)
    end
end
local function setValue(value)
    local f = Page.fields[currentLine]
    local idx = f.i or currentLine
    local scale = (f.scale or 1)
    if(value < f.min) then
        value = f.min
    end
    if(value > f.max) then
        value = f.max
    end
    f.value = value
    for idx=1, #(f.vals) do
        Page.values[f.vals[idx]] = bit32.rshift(math.floor(f.value*scale + 0.5), (idx-1)*8)
    end
    if f.upd and Page.values then
        f.upd(Page)
    end
end

local function drawMenu()
    local x = MenuBox.x
    local y = MenuBox.y
    local w = MenuBox.w
    local h_line = MenuBox.h_line
    local h_offset = MenuBox.h_offset
    local h = #(menuList) * h_line + h_offset*2
    
    lcd.drawFilledRectangle(x,y,w,h,foregroundColor)
    lcd.drawFilledRectangle(x+1,y+1,w-2,h-2,backgroundFill)
    if MenuBox.x_offset > h_offset then
        lcd.drawText(x+h_line/2,y+h_offset,"Menu:",globalTextOptions)
    end
    for i,e in ipairs(menuList) do
        local text_options = globalTextOptions
        if menuActive == i then
            text_options = text_options + INVERS
        end
        lcd.drawText(x+MenuBox.x_offset,y+(i-1)*h_line+h_offset,e.t,text_options)
    end
end
local function getMenuIndex(event_x, event_y)
    local x = MenuBox.x
    local y = MenuBox.y
    local w = MenuBox.w
    local h_line = MenuBox.h_line
    local h_offset = MenuBox.h_offset
    local h = #(menuList) * h_line + h_offset*2
	for i,e in ipairs(menuList) do
        local x_min = x+MenuBox.x_offset - 2;
        local y_min = y+(i-1)*h_line+h_offset - 2;
        local h = lcd.getHeight(e.t, globalTextOptions)
        local w = lcd.getWidth(e.t, globalTextOptions)
        local x_max = x_min + 2 + w
        local y_max = y_min + 2 + h
        if ( event_x >= x_min) and (event_y >= y_min) and (event_x <= x_max) and (event_y <= y_max) then
            return math.floor(i)
        end
    end
    return -1
end
local function close()
    if not protocol then
        return -2
    end
    return protocol.exitFunc()
end

function run_ui(event, wParam, lParam)
    if currentState == pageStatus.close then
        return 1
    end
    local now = getTime()
    -- if lastRunTS old than 500ms
    if lastRunTS + 50 < now then
        invalidatePages()
    end
    lastRunTS = now
    if (currentState == pageStatus.saving) then
        if (saveTS + saveTimeout < now) then
            if saveRetries < saveMaxRetries then
                saveSettings()
            else
                -- max retries reached
                currentState = pageStatus.display
                invalidatePages()
            end
        end
    end
    -- process send queue
    mspProcessTxQ()
    -- navigation
    if (event == userEvent.longPress.menu) or (event == userEvent.touch.up and wParam < 50 and lParam < 50) then -- Taranis QX7 / X9
        menuActive = 1
        currentState = pageStatus.displayMenu
    elseif userEvent.press.pageDown and (event == userEvent.longPress.enter) then -- Horus
        menuActive = 1
        killEnterBreak = 1
        currentState = pageStatus.displayMenu
    -- menu is currently displayed
    elseif currentState == pageStatus.displayMenu then
        if event == userEvent.release.exit or event == userEvent.touch.slideRight then
            currentState = pageStatus.display
        elseif event == userEvent.release.plus or event == userEvent.dial.left then
            incMenu(-1)
        elseif event == userEvent.release.minus or event == userEvent.dial.right then
            incMenu(1)
        elseif event == userEvent.touch.up then
            local idx = getMenuIndex(wParam, lParam)
            if (idx ~= -1) then
                currentState = pageStatus.display
                menuList[idx].f()
            end
        elseif event == userEvent.release.enter then
            if killEnterBreak == 1 then
                killEnterBreak = 0
            else
                currentState = pageStatus.display
                menuList[menuActive].f()
            end
        end
    -- normal page viewing
    elseif currentState <= pageStatus.display then
        if event == userEvent.press.pageUp or event == userEvent.touch.slideRight then
            if (currentPage == 1) then
                return close()
            else 
                incPage(-1)
            end
        elseif event == userEvent.release.menu or event == userEvent.press.pageDown or event == userEvent.touch.slideLeft then
            incPage(1)
        elseif event == userEvent.release.plus or event == userEvent.repeatPress.plus or event == userEvent.dial.left then
            incLine(-1)
        elseif event == userEvent.release.minus or event == userEvent.repeatPress.minus or event == userEvent.dial.right then
            incLine(1)
        elseif event == userEvent.touch.up then
            local idx = getField(wParam, lParam)
            local field = Page.fields[idx]
            if (idx ~= -1) and Page.values and Page.values[idx] and (field.ro ~= true) then
                currentLine = idx
                currentState = pageStatus.editing
                lcd.showKeyboard(KEYBOARD_NUM_INC_DEC)
            end
        elseif event == userEvent.release.enter then
            local field = Page.fields[currentLine]
            local idx = field.i or currentLine
            if Page.values and Page.values[idx] and (field.ro ~= true) then
                currentState = pageStatus.editing
                lcd.showKeyboard(KEYBOARD_NUM_INC_DEC)
            end
        elseif event == userEvent.release.exit then
            return close()
        end
    -- editing value
    elseif currentState == pageStatus.editing then
        if (event == userEvent.release.exit) or (event == userEvent.release.enter) or event == userEvent.touch.up or event == userEvent.touch.slideLeft or event == userEvent.touch.slideRight then
            currentState = pageStatus.display
            lcd.showKeyboard(KEYBOARD_NONE)
        elseif event == userEvent.press.plus or event == userEvent.repeatPress.plus or event == userEvent.dial.right or  event == userEvent.virtual.inc then
            incValue(1)
        elseif event == userEvent.press.minus or event == userEvent.repeatPress.minus or event == userEvent.dial.left or  event == userEvent.virtual.dec then
            incValue(-1)
        elseif  event == userEvent.virtual.incBig then
            incValue(2)
        elseif  event == userEvent.virtual.decBig then
            incValue(-2)
        elseif event == userEvent.virtual.min then
            setValue(Page.fields[currentLine].min)
        elseif event == userEvent.virtual.max then
            setValue(Page.fields[currentLine].max)
        end
    elseif currentState == pageStatus.close then
        currentState = pageStatus.exit;
        return close()
    end
    local nextPage = currentPage
    while Page == nil do
        Page = assert(loadScript(radio.templateHome .. PageFiles[currentPage]))()
        if Page.requiredVersion and apiVersion > 0 and Page.requiredVersion > apiVersion then
            incPage(1)

            if currentPage == nextPage then
                lcd.clear()
                lcd.drawText(NoTelem[1], NoTelem[2], "No Pages! API: " .. apiVersion, NoTelem[4])

                return 1
            end
        end
    end
    if not Page.values and currentState == pageStatus.display then
        requestPage()
    end
    lcd.clear()
    if TEXT_BGCOLOR then
        lcd.drawFilledRectangle(0, 0, LCD_W, LCD_H, TEXT_BGCOLOR)
    end
    drawScreen()
    if protocol.rssi() == 0 then
        lcd.drawText(NoTelem[1],NoTelem[2],NoTelem[3],NoTelem[4])
    end
    if currentState == pageStatus.displayMenu then
        drawMenu()
    elseif currentState == pageStatus.saving then
        lcd.drawFilledRectangle(SaveBox.x,SaveBox.y,SaveBox.w,SaveBox.h,backgroundFill)
        lcd.drawRectangle(SaveBox.x,SaveBox.y,SaveBox.w,SaveBox.h,SOLID)
        if saveRetries <= 0 then
            lcd.drawText(SaveBox.x+SaveBox.x_offset,SaveBox.y+SaveBox.h_offset,"Saving...",DBLSIZE + BLINK + (globalTextOptions))
        else
            lcd.drawText(SaveBox.x+SaveBox.x_offset,SaveBox.y+SaveBox.h_offset,"Retrying",DBLSIZE + (globalTextOptions))
        end
    end
    processMspReply(mspPollReply())
    return 0
end

return run_ui
