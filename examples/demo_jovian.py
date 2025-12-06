# %% [markdown]
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

# %% [markdown]
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

# %% [markdown]
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

# %% [markdown]
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

# %% [markdown]
# ## 4. Magic Commands
# 
# IPython magic commands are supported.

# %% id="yzQIP21QQfB2"
# Time the execution of a list comprehension
%timeit [i**2 for i in range(1000)]

# %% id="EAhY9ljLcp88"
# Run a shell command
!echo "Current Directory:"
!pip install pyqt5
!pwd

# %% [markdown]
# ## 5. Progress & Interactivity
# 
# Long-running cells show "Running..." status.

# %% id="ZiL5ICSQW54J"
from tqdm import tqdm
print("Starting long task with tqdm...")
for i in tqdm(range(20)):
    time.sleep(0.1)
print("Done!")

# %% [markdown]
# ## 6. Error Handling
# 
# Errors are captured and displayed nicely in the preview.

# %% id="lXBTaWpt_3G8"
# This will raise an error
def cause_error():
    return 1 / 0

try:
    cause_error()
except ZeroDivisionError as e:
    print("Caught an error, but here is what happens if we don't catch it:")
    raise e
