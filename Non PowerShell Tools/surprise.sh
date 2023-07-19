#!/bin/bash

# Check if tput command is available
if ! command -v tput &>/dev/null; then
    echo "tput not found. Please install ncurses-utils package."
    exit 1
fi

# Check if seq command is available
if ! command -v seq &>/dev/null; then
    echo "seq not found. Please install coreutils package."
    exit 1
fi

# Check if parallel command is available
if ! command -v parallel &>/dev/null; then
    echo "parallel not found. Please install parallel package."
    exit 1
fi

N_COLUMN=$(tput cols)
N_LINE=$(($(tput lines) - 1))

# Check if N_COLUMN is zero
if [ "$N_COLUMN" -eq 0 ]; then
    echo "Error: The script must be run in a terminal with a width greater than zero."
    exit 1
fi

# Check if N_LINE is zero
if [ "$N_LINE" -eq 0 ]; then
    echo "Error: The script must be run in a terminal with a height greater than one."
    exit 1
fi

function get_char {
    RANDOM_U=$(echo $(((RANDOM % 9) + 0)))
    RANDOM_D=$(echo $(((RANDOM % 9) + 0)))

    #https://unicode-table.com/en/#kangxi-radicals
    CHAR_TYPE="\u04"

    printf "%s" "$CHAR_TYPE$RANDOM_D$RANDOM_U"
}

function cursor_position {
    echo "\033[$1;${RANDOM_COLUMN}H"
}

function write_char {
    CHAR=$(get_char)
    print_char $1 $2 $CHAR
}

function erase_char {
    CHAR="\u0020" #Space char
    print_char $1 $2 $CHAR
}

function print_char {
    CURSOR=$(cursor_position $1)
    echo -e "$CURSOR$2$3"
}

function draw_line {
    RANDOM_COLUMN=$((RANDOM % N_COLUMN))
    RANDOM_LINE_SIZE=$(echo $(((RANDOM % $N_LINE) + 1)))
    SPEED=0.05

    COLOR="\033[32m"      #GREEN
    COLOR_HEAD="\033[37m" #WHITE

    #Draw Line
    for i in $(seq 1 $N_LINE); do
        write_char $((i - 1)) $COLOR
        write_char $i $COLOR_HEAD
        sleep $SPEED
        if [ $i -ge $RANDOM_LINE_SIZE ]; then
            erase_char $((i - RANDOM_LINE_SIZE))
        fi
    done

    #Erase Line
    for i in $(seq $((i - $RANDOM_LINE_SIZE)) $N_LINE); do
        erase_char $i
        sleep $SPEED
    done
}

function matrix {
    tput setab 000 #Background Black
    clear
    draw_line
}
export -f get_char
export -f cursor_position
export -f write_char
export -f erase_char
export -f print_char
export -f draw_line
export -f matrix

# Export N_COLUMN and N_LINE
export N_COLUMN
export N_LINE

# Start time
start_time=$(date +%s)

# Run matrix in as many threads a possible at the same time
parallel -j0 matrix ::: $(seq 1 "$(nproc)")

# End time
end_time=$(date +%s)

# Calculate execution time
execution_time=$((end_time - start_time))

echo "Execution time: $execution_time seconds"
