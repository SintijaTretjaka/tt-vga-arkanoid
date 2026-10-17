## How it works

A sync generator counts through the 640 by 480 pixels of each frame at 60 Hz. The ball bounces off the walls and ceiling, and catching it on the paddle adds to the score bar and speeds the ball up. Where the ball lands on the paddle decides which way it leaves. Missing it flashes the screen red and starts a new game.

## How to test

Use a 25.175 MHz clock and hold rst_n low for a few cycles, then raise it. The game appears on a monitor connected through a TinyVGA PMOD. Hold ui[0] or ui[1] to move the paddle.

## External hardware

A TinyVGA PMOD, a VGA monitor, and two buttons or switches on ui[0] and ui[1].
