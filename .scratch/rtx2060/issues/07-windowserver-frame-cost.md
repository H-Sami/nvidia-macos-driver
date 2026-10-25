# WindowServer's frame cost while compositing

Type: research
Status: open
Blocked by:

## Question

Why does WindowServer spend about 20 ms of CPU per frame while a window moves, whatever the window size and refresh
rate (upstream #356)? Which parts of the plugin's path for WindowServer put that time on its thread: command buffer
encoding, submission, the completion wait before `commitAndWaitUntilSubmitted` returns, event waits versus polling,
dirty-only bindings, surface publication, the flip latch?

At 180 Hz a frame has 5.5 ms. The answer should name the candidates in code, say what the NvGfx fork changed to reach
about 145 flips/s, and say what can only be settled by profiling on Tahoe.
