import curses
import threading
import random
import time

def draw_line(win, height, width):
    col = random.randint(0, width-1)
    line_size = random.randint(1, height)
    speed = 0.05

    # Draw Line
    for i in range(height):
        win.addstr(i-1, col, ' ', curses.color_pair(2))
        win.addstr(i, col, ' ', curses.color_pair(1))
        win.refresh()
        time.sleep(speed)
        if i >= line_size:
            win.addstr(i-line_size, col, ' ', curses.color_pair(0))

    # Erase Line
    for i in range(i-line_size, height):
        win.addstr(i, col, ' ', curses.color_pair(0))
        win.refresh()
        time.sleep(speed)

def matrix(win):
    curses.start_color()
    curses.init_pair(1, curses.COLOR_WHITE, curses.COLOR_BLACK)
    curses.init_pair(2, curses.COLOR_GREEN, curses.COLOR_BLACK)

    while True:
        draw_line(win, *win.getmaxyx())

def main(stdscr):
    threads = []
    for _ in range(threading.active_count()):
        t = threading.Thread(target=matrix, args=(stdscr,))
        t.start()
        threads.append(t)

    for t in threads:
        t.join()

if __name__ == "__main__":
    curses.wrapper(main)
