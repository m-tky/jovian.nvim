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

# %% [markdown]
# ## Inline images
#
# Markdown cells can embed images. With `markdown_cell_style` on (and a
# Kitty-graphics terminal such as Kitty / Ghostty / WezTerm), jovian
# renders them inline below the line.
#
# A **data-URI** image — e.g. a screenshot pasted into a notebook and
# exported with jupytext. The long base64 is hidden, not shown as raw text:
#
# ![data-uri demo](data:image/png;base64,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)
#
# A **local file-path** image (resolved next to this file):
#
# ![file demo](assets/demo_inline.png)

# %% [markdown]
# ## Math (LaTeX)
#
# With `markdown_cell_style` on, `$…$` and `$$…$$` render as Unicode.
#
# Inline: mass-energy $E = mc^2$, Pythagoras $a^2 + b^2 = c^2$, and Greek
# such as $\alpha + \beta = \gamma$, with $\theta \leq \frac{\pi}{2}$.
#
# Block math renders on its own line:
#
# $$
# \sum_{i=1}^{n} i = \frac{n(n+1)}{2}
# $$
#
# $$ \int_0^\infty e^{-x^2}\, dx = \frac{\sqrt{\pi}}{2} $$

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
# | Name  | Age|
# | --- | --- |
# | Alice | 30|
# | test | 30|

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
