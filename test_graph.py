# %% id="step_test"
print("Loading data...")
import matplotlib.pyplot as plt
import numpy as np

x = np.linspace(0, 10, 100)
y = np.sin(x)

plt.plot(x, y)
print("Plotting sine wave...")
plt.show()

print("Calculation finished!")
