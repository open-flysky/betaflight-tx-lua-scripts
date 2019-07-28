
return 
{
    press = {
        minus = EVT_MINUS_FIRST,
        plus = EVT_PLUS_FIRST,
        pageDown = EVT_PAGEDN_FIRST or EVT_SLIDE_LEFT,
        pageUp = EVT_PAGEUP_FIRST or EVT_LEFT_BREAK or EVT_SLIDE_RIGHT
    },
    longPress = {
        enter = EVT_ENTER_LONG,
        menu = EVT_MENU_LONG or EVT_RIGHT_LONG
    },
    repeatPress = {
        minus = EVT_MINUS_REPT,
        plus = EVT_PLUS_REPT
    },
    release = {
        enter = EVT_ENTER_BREAK or EVT_ROT_BREAK,
        exit = EVT_EXIT_BREAK,
        menu = EVT_MENU_BREAK or EVT_RIGHT_BREAK,
        minus = EVT_MINUS_BREAK,
        plus = EVT_PLUS_BREAK
    },
    dial = {
        left = EVT_ROT_LEFT or EVT_UP_BREAK,
        right = EVT_ROT_RIGHT or EVT_DOWN_BREAK
    },
    touch = {
        slideLeft = EVT_SLIDE_LEFT,
        slideRight = EVT_SLIDE_RIGHT,
        up = EVT_TOUCH_UP,
        down = EVT_TOUCH_DOWN,
    },
    virtual = {
        min = EVT_VK_MIN,
        max = EVT_VK_MAX,
        dec = EVT_VK_DEC,
        inc = EVT_VK_INC,
        incBig = EVT_VK_INC_LARGE,
        decBig = EVT_VK_DEC_LARGE,
        default = EVT_VK_DEFAULT
    }
}
