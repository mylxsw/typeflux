These are synthetic 2× renders of the live recording indicator, not exported video frames. The captured area is the inner 320 × 200 pixels, inset 12 pixels from each image edge. Every pixel in that area is transparent in both renders; the red/orange strokes and thicker corner brackets stay outside it.

![Live recording indicator](live.png)

![Paused recording indicator](paused.png)

`ScreenRecordingBorderTests` checks every captured pixel at 1× and 2×. Its opt-in native test deliberately removes the border's exclusion identifier, records a synthetic green region while changing the border from red to orange, and checks the edge pixels of every source and exported MP4 frame. This verifies the boundary independently of capture-window filtering.
