import types
import json
import traceback
import os
import sys
import protocol
import utils

# Optional libraries
try: import dill
except ImportError: dill = None

def get_variables(shell):
    var_list = []
    for name, value in list(shell.user_ns.items()):
        if name.startswith("_") or isinstance(value, (types.ModuleType, types.FunctionType, type)): continue
        if name in ['In', 'Out', 'exit', 'quit', 'get_ipython']: continue
        
        type_name = type(value).__name__
        info = str(value)
        info = info.replace("\n", " ")
        if len(info) > 200: info = info[:197] + "..."

        if hasattr(value, 'shape'):
            shape_str = str(value.shape).replace(" ", "")
            if hasattr(value, 'dtype'):
                info = f"{shape_str} | {value.dtype}"
            else:
                info = f"{shape_str} | {type_name}"
        elif isinstance(value, (list, dict, set, tuple)):
            info = f"len: {len(value)}"
        var_list.append({"name": name, "type": type_name, "info": info})
        
    var_list.sort(key=lambda x: x['name'])
    protocol.send_json({"type": "variable_list", "variables": var_list})

def get_dataframe_data(shell, var_name):
    if var_name not in shell.user_ns: return
    val = shell.user_ns[var_name]
    try:
        import pandas as pd
        import numpy as np
        df = None
        if isinstance(val, pd.DataFrame): df = val
        elif isinstance(val, pd.Series): df = val.to_frame()
        elif isinstance(val, np.ndarray):
            if val.ndim > 2: return
            df = pd.DataFrame(val)
        else: return 

        df_view = df.head(100)
        data_json = df_view.to_json(orient='split', date_format='iso')
        parsed = json.loads(data_json)
        protocol.send_json({
            "type": "dataframe_data", "name": var_name,
            "columns": parsed.get('columns', []), "index": parsed.get('index', []), "data": parsed.get('data', [])
        })
    except: sys.stderr.write(traceback.format_exc())

def copy_to_clipboard(shell, var_name):
    if var_name not in shell.user_ns: return
    val = shell.user_ns[var_name]
    try:
        import pandas as pd
        import numpy as np
        text_data = ""
        if isinstance(val, (pd.DataFrame, pd.Series)):
            try: text_data = val.to_markdown()
            except ImportError: text_data = val.to_csv(sep='\t')
        elif isinstance(val, np.ndarray):
            text_data = np.array2string(val, separator=', ')
        else:
            text_data = str(val)
        protocol.send_json({
            "type": "clipboard_data", "content": text_data
        })
    except: sys.stderr.write(traceback.format_exc())

def save_session(shell, filename):
    if dill is None:
        sys.stderr.write("Error: 'dill' module not found.\n")
        return
    try:
        session_data = {}
        for k, v in shell.user_ns.items():
            if k.startswith('_') or k in ['In', 'Out', 'exit', 'quit', 'get_ipython']: continue
            if isinstance(v, (types.ModuleType, types.FunctionType, type)): continue
            try:
                dill.dumps(v)
                session_data[k] = v
            except: pass
        with open(filename, 'wb') as f: dill.dump(session_data, f)
        print(f"Session saved to {filename}")
    except: sys.stderr.write(traceback.format_exc())

def load_session(shell, filename):
    if dill is None:
        sys.stderr.write("Error: 'dill' module not found.\n")
        return
    try:
        if not os.path.exists(filename): return print(f"File not found: {filename}")
        with open(filename, 'rb') as f: session_data = dill.load(f)
        shell.user_ns.update(session_data)
        print(f"Session loaded from {filename}")
    except: sys.stderr.write(traceback.format_exc())

def inspect_object(shell, var_name):
    try:
        info = shell.object_inspect(var_name)
        result = {
            "name": info.get('name', var_name),
            "type": info.get('type_name') or 'unknown',
            "docstring": info.get('docstring') or 'No documentation found.',
            "file": info.get('file', ''),
            "definition": info.get('definition') or ''
        }
        protocol.send_json({"type": "inspection_data", "data": result})
    except: sys.stderr.write(traceback.format_exc())

def purge_cache(valid_ids, filename):
    save_dir = utils.get_save_dir(filename)
    if not os.path.exists(save_dir): return
    valid_set = set(valid_ids)
    for f in os.listdir(save_dir):
        parts = f.replace('.', '_').split('_')
        if parts[0] not in valid_set:
                try: os.remove(os.path.join(save_dir, f))
                except: pass
