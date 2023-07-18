$esc = $([char]27)

$N_LINE = ($Host.UI.RawUI.WindowSize.Height - 1)
$N_COLUMN = $Host.UI.RawUI.WindowSize.Width

function get_char {
    $RANDOM_U = (Get-Random -Minimum 0 -Maximum 9)
    $RANDOM_D = (Get-Random -Minimum 0 -Maximum 9)

    #https://unicode-table.com/en/#kangxi-radicals
    $CHAR_TYPE = [char]0x04

    return "$CHAR_TYPE$RANDOM_D$RANDOM_U"
}

function draw_line {
    $RANDOM_COLUMN = (Get-Random -Minimum 0 -Maximum $N_COLUMN)
    $RANDOM_LINE_SIZE = (Get-Random -Minimum 1 -Maximum ($N_LINE + 1))
    $SPEED = 0.05

    $COLOR = "`e[32m"      # GREEN
    $COLOR_HEAD = "`e[37m" # WHITE

    # Draw Line
    for ($i = 1; $i -le $N_LINE; $i++) {
        write_char ($i - 1) $COLOR
        write_char $i $COLOR_HEAD
        Start-Sleep -Milliseconds ([int]($SPEED * 1000))
        if ($i -ge $RANDOM_LINE_SIZE) {
            erase_char ($i - $RANDOM_LINE_SIZE)
        }
    }

    # Erase Line
    for ($i = ($i - $RANDOM_LINE_SIZE); $i -le $N_LINE; $i++) {
        erase_char $i
        Start-Sleep -Milliseconds ([int]($SPEED * 1000))
    }
}

function cursor_position {
    param($line)
    return "`e[${line};${$RANDOM_COLUMN}H"
}

function write_char {
    param($line, $color)
    $CHAR = get_char
    print_char $line $color $CHAR
}

function erase_char {
    param($line)
    $CHAR = ' '
    print_char $line $color $CHAR
}

function print_char {
    param($line, $color, $char)
    $CURSOR = cursor_position $line
    Write-Host "$CURSOR$color$char"
}

function matrix {
    Clear-Host
    while ($true) {
        draw_line
        Start-Sleep -Seconds 0.5
    }
}

matrix
