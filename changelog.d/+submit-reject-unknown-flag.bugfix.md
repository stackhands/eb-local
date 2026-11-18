`eb-local submit` now rejects unknown flags before the recipe name with exit code 2 instead of forwarding them as the recipe name, while still passing flags after the recipe to `eb`.
