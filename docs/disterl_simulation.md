# DistErl Simulation

## Bare Metal Simulation

1. Start nodes with `morpheus_guest_helper:start_dist_raw(Node)`. Use the initial node name to initial itself.  
2. Spawn tasks in other nodes using `spawn(Node, M, F, A)` function.

## Full-fledged Simulation

This boots nodes with `kernel` and `stdlib` applications.

Start nodes with `morpheus_guest_helper:bootstrap_dist(Node)`. Use the initial node name to initial itself.
