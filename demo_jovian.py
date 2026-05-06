# %% [markdown] id="yHsYAPQhwMhZ"
# # Jovian.nvim Demo
# 
# Welcome to the demo of **jovian.nvim**!
# This script demonstrates the key features of the plugin.
# 
# **Instructions:**
# 1. Place your cursor on a cell (lines starting with `# %%`).
# 2. Run the cell using `:JovianRun` (or your configured keybinding).
# 3. Observe the output in the REPL and Preview windows.
# 4. Try `:JovianRunAbove` to run all cells up to the current one.

# %% id="3HBWq2Im4lG4"
import time
import numpy as np
import matplotlib.pyplot as plt
import pandas as pd

print("Hello from Jovian.nvim!")
print("This is a standard print statement.")

# %% [markdown] id="3UafByxVensg"
# ## 1. Variables & Inspection
# 
# Define some variables. Open the Variables Pane (`:JovianToggleVars`) to see them.
# You can also use `:JovianPeek <var>` or `:JovianDoc <var>` to inspect them.

# %% id="GXgCRKCxI0Y5"
x = 42
y = 3.14159
name = "Jovian"
my_list = [1, 2, 3, 4, 5]
my_dict = {"a": 1, "b": 2, "c": 3}

print(f"Defined variables: x={x}, y={y}, name={name}")

# %% [markdown] id="Zf4GmouZYXNz"
# ## 2. Plotting
# 
# `jovian.nvim` supports inline plotting using `matplotlib`.
# The plots will appear in the Preview window (if `image.nvim` is set up).

# %% id="TlpGIK9UeSLf"
# Simple Sine Wave
t = np.linspace(0, 2*np.pi, 100)
s = np.sin(t)

plt.figure(figsize=(8, 4))
plt.plot(t, s, label="sin(t)", color="orange", linewidth=2)
plt.title("Sine Wave Example")
plt.xlabel("Time")
plt.ylabel("Amplitude")
plt.grid(True, linestyle="--", alpha=0.6)
plt.legend()
plt.show()

# %% [markdown] id="Wl8PoTgKyThx"
# ## 3. DataFrames
# 
# You can view pandas DataFrames.
# Use `:JovianView df` to see the dataframe in a floating window.

# %% id="GnX0A6OI-4C9"
# Create a sample DataFrame
data = {
    'Date': pd.date_range(start='2023-01-01', periods=5),
    'Value': np.random.randn(5),
    'Category': ['A', 'B', 'A', 'C', 'B']
}
df = pd.DataFrame(data)

print("DataFrame created:")
print(df)

# Try running :JovianView df

# %% [markdown] id="bjdGDpHA0bqh"
# ## 4. Magic Commands
# 
# IPython magic commands are supported.

# %% id="yzQIP21QQfB2"
# Time the execution of a list comprehension
%timeit [i**2 for i in range(1000)]

# %% id="EAhY9ljLcp88"
# Run a shell command
!echo "Current Directory:"
!pwd

# %% [markdown] id="OPQUwmI2LBEx"
# ## 5. Progress & Interactivity
# 
# Long-running cells show "Running..." status.

# %% id="ZiL5ICSQW54J"
from tqdm import tqdm
print("Starting long task with tqdm...")
for i in tqdm(range(10)):
    time.sleep(1)
print("Done!")

# %% [markdown] id="ux6cMwXWih5W"
# ## 7. Edge Cases & Stress Tests
# 
# ### 7.1 Multiple Plots in One Cell
# Each call to `plt.show()` should generate a separate entry in the preview.

# %% id="rLN5J1va8q97"
plt.figure(figsize=(5, 3))
plt.plot(np.random.randn(50).cumsum(), label="Random Walk 1")
plt.legend()
plt.show()

plt.figure(figsize=(5, 3))
plt.plot(np.random.randn(50).cumsum(), label="Random Walk 2", color="red")
plt.legend()
plt.show()

# ### 7.2 Mixed Output Streams
# Testing real-time interleaving of stdout and stderr.

# %% id="Jkbi9JrSjbMt"
import sys
import time

for i in range(3):
    print(f"Stdout message {i}")
    sys.stdout.flush()
    time.sleep(0.2)
    print(f"Stderr error message {i}", file=sys.stderr)
    sys.stderr.flush()
    time.sleep(0.2)

# ### 7.3 Large Volume Output
# Stress test for the REPL buffer handling.

# %% id="vpBdhEyDuTM0"
print("Generating 100 lines of output...")
for i in range(100):
    print(f"Line {i:03d}: " + "ABC " * 20)
print("Done!")

# ### 7.4 Unicode Support
# Ensuring characters from different languages and emojis render correctly.

# %% id="rf4Gn4mO9zqr"
print("Testing Unicode Rendering:")
print("Japanese: こんにちは")
print("Chinese:  你好")
print("Korean:   안녕하세요")
print("Arabic:   السلام عليكم")
print("Emoji:    🚀 🦀 🐍 ⚛️")
unicode_val = "乱 (Chaos)"

# %% [markdown] id="ashyfKSsZJfd"
# ### 7.6 Kernel Interruption
# **Manual Test:** Run the cell below and press `:JovianInterrupt` (or your shortcut).
# The status should change to "Interrupted".

# %% id="uvh0PSt47tkz"
print("This will run for 30 seconds unless interrupted...")
for i in range(30):
    time.sleep(1)
    print(f"Step {i+1}/30")
print("If you see this, it wasn't interrupted.")

# %% [markdown]

# ### 7.5 Syntax Error
# This should be caught by the kernel and reported as a specialized error.

# %% id="kD8c__InW8Vt"
def broken_function():
    if True
        print("Missing colon!")

