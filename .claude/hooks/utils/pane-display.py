#!/usr/bin/env python3
"""Live agent activity display for tmux pane — tails subagent transcript JSONL."""
import sys, json, time, os, signal, shutil

def main():
    name = sys.argv[1]
    bg_ansi = sys.argv[2]
    fg_ansi = sys.argv[3]
    transcript = sys.argv[4] if len(sys.argv) > 4 else ""
    t0 = time.time()

    # Hide cursor
    sys.stdout.write('\033[?25l')
    sys.stdout.flush()

    def cleanup(*_):
        sys.stdout.write('\033[?25h\n')
        sys.stdout.flush()
        sys.exit(0)
    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)

    TOOL_ICONS = {
        'Read': '\U0001f4d6', 'Edit': '\u270f\ufe0f ', 'Write': '\U0001f4dd',
        'Bash': '\U0001f4bb', 'Grep': '\U0001f50d', 'Glob': '\U0001f4c2',
        'Agent': '\U0001f916', 'WebSearch': '\U0001f310', 'WebFetch': '\U0001f310',
    }

    lines = []

    def get_dims():
        sz = shutil.get_terminal_size(fallback=(40, 12))
        return sz.columns, sz.lines

    def add_line(text):
        cols, rows = get_dims()
        truncated = text[:cols - 4]
        lines.append(truncated)
        max_lines = max(rows - 6, 3)
        while len(lines) > max_lines:
            lines.pop(0)

    def render(status="RUNNING"):
        cols, rows = get_dims()
        elapsed = int(time.time() - t0)
        m, s = divmod(elapsed, 60)
        sys.stdout.write('\033[H\033[J\n')
        # Colored agent name label
        sys.stdout.write(f'  \033[1;38;5;{fg_ansi};48;5;{bg_ansi}m {name} \033[0m')
        sys.stdout.write(f'  \033[2m{m:02d}:{s:02d}\033[0m\n\n')
        # Activity lines
        for ln in lines:
            sys.stdout.write(f'  {ln}\n')
        # Bottom status
        if not lines:
            sys.stdout.write(f'  \033[38;5;{fg_ansi}m\u25cf\033[0m {status}\n')
        sys.stdout.flush()

    # Wait for transcript file (up to 30s)
    if transcript:
        wait_start = time.time()
        while not os.path.exists(transcript):
            render("Initializing...")
            time.sleep(0.3)
            if time.time() - wait_start > 30:
                break

    # If no transcript available, fall back to simple timer
    if not transcript or not os.path.exists(transcript):
        while True:
            render()
            time.sleep(1)

    # Tail the transcript JSONL and parse activity
    with open(transcript, 'r') as f:
        while True:
            line = f.readline()
            if line.strip():
                try:
                    obj = json.loads(line)
                    msg = obj.get('message', {})
                    role = msg.get('role', '')
                    if role == 'assistant':
                        for content in msg.get('content', []):
                            ctype = content.get('type', '')
                            if ctype == 'text':
                                text = content.get('text', '').strip()
                                if text:
                                    for tline in text.split('\n'):
                                        tline = tline.strip()
                                        if tline:
                                            add_line(tline)
                                            break
                            elif ctype == 'tool_use':
                                tool = content.get('name', '?')
                                icon = TOOL_ICONS.get(tool, '\U0001f527')
                                inp = content.get('input', {})
                                brief = ''
                                if tool in ('Read', 'Edit', 'Write'):
                                    p = inp.get('file_path', '')
                                    brief = '/'.join(p.split('/')[-2:]) if '/' in p else p
                                elif tool == 'Grep':
                                    brief = inp.get('pattern', '')[:40]
                                elif tool == 'Glob':
                                    brief = inp.get('pattern', '')[:40]
                                elif tool == 'Bash':
                                    brief = inp.get('command', '')[:50]
                                elif tool == 'Agent':
                                    brief = inp.get('description', '')[:40]
                                else:
                                    brief = json.dumps(inp)[:40]
                                add_line(f'{icon} {tool}: {brief}')
                except (json.JSONDecodeError, KeyError):
                    pass
                render()
            else:
                render()
                time.sleep(0.3)

if __name__ == '__main__':
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        sys.stdout.write('\033[?25h')
