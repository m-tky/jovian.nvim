import sys
import json
import shell
import handlers

def main():
    kernel = shell.JovianShell()
    while True:
        try:
            line = sys.stdin.readline()
            if not line: break
            cmd = json.loads(line)
            if cmd.get('command') == 'execute':
                kernel.run_code(cmd['code'], cmd['cell_id'], cmd.get('filename', 'scratchpad'))
            elif cmd.get('command') == 'profile':
                kernel.run_profile(cmd['code'], cmd['cell_id'])
            elif cmd.get('command') == 'copy_to_clipboard':
                handlers.copy_to_clipboard(kernel.shell, cmd.get('name'))
            elif cmd.get('command') == 'save_session':
                handlers.save_session(kernel.shell, cmd.get('filename'))
            elif cmd.get('command') == 'load_session':
                handlers.load_session(kernel.shell, cmd.get('filename'))
            elif cmd.get('command') == 'clean_cache':
                handlers.purge_cache(cmd.get('valid_ids', []), cmd.get('filename', 'scratchpad'))
            elif cmd.get('command') == 'get_variables':
                handlers.get_variables(kernel.shell)
            elif cmd.get('command') == 'view_dataframe':
                handlers.get_dataframe_data(kernel.shell, cmd.get('name'))
            elif cmd.get('command') == 'inspect':
                handlers.inspect_object(kernel.shell, cmd['name'])
            elif cmd.get('command') == 'peek':
                handlers.peek_object(kernel.shell, cmd['name'])
            elif cmd.get('command') == 'input_reply': pass
        except (json.JSONDecodeError, KeyboardInterrupt): pass

if __name__ == "__main__":
    main()
