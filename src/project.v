/*
 * Arkanoid for VGA: break all the bricks.
 *
 * To play, open Inspect > VGA output and press Run. Use the switches under the
 * picture, or the keyboard:
 *   ui_in[0]  paddle left    (Left arrow, A or 1)
 *   ui_in[1]  paddle right   (Right arrow, D or 2)
 *
 * Forty bricks (10 across, 4 rows) hang at the top. The ball breaks a brick
 * when it hits it, and the green bar grows with every brick. The ball speeds
 * up as the bar grows. Where the ball lands on the paddle decides which way it
 * leaves. You have three lives (the pink squares, top right). Miss the ball and
 * the screen flashes red; lose all three and a new game starts. Clear every
 * brick and the wall rebuilds.
 *
 * How this file is laid out:
 *   1. SETTINGS   Colours, sizes and speeds. Change anything here and press Run.
 *   2. WIRING     The pins and the sync generator. Leave this as it is.
 *   3. THE GAME   The rules: the paddle, the bounces, bricks, catches and misses.
 *   4. DRAWING    The colour of every pixel, from where things are.
 */

`default_nettype none

module tt_um_sintijatretjaka_vga_paddle_ball (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ========================================================================
    // 1. SETTINGS
    //    Change these freely. Nothing below needs editing when you do.
    // ========================================================================

    // Colours. Six bits: two for red, two for green, two for blue (6'bRRGGBB).
    localparam [5:0] BALL_COLOUR       = 6'b111111;   // white
    localparam [5:0] PADDLE_COLOUR     = 6'b001111;   // cyan
    localparam [5:0] WALL_COLOUR       = 6'b101010;   // grey
    localparam [5:0] GRID_COLOUR       = 6'b000101;   // the faint lines behind the game
    localparam [5:0] BACKGROUND_COLOUR = 6'b000001;   // deep blue
    localparam [5:0] SCORE_COLOUR      = 6'b001100;   // green
    localparam [5:0] LIVES_COLOUR      = 6'b110011;   // pink
    localparam [5:0] BRICK_ROW0_COLOUR = 6'b110000;   // red     (top row)
    localparam [5:0] BRICK_ROW1_COLOUR = 6'b110100;   // orange
    localparam [5:0] BRICK_ROW2_COLOUR = 6'b111100;   // yellow
    localparam [5:0] BRICK_ROW3_COLOUR = 6'b011011;   // teal    (bottom row)

    // Sizes, in pixels. The screen is 640 wide and 480 tall.
    localparam [9:0] BALL_SIZE = 10'd12;   // the ball is a square this big
    localparam [9:0] PADDLE_W  = 10'd96;   // a wider paddle is easier
    localparam [9:0] PADDLE_H  = 10'd10;

    // Speeds, in pixels per frame. There are 60 frames every second.
    localparam [9:0] PADDLE_STEP = 10'd6;  // how far the paddle moves sideways
    localparam [3:0] START_SPEED = 4'd3;   // how fast the ball moves at the start: 12 at most

    // The ball gets one pixel per frame faster each time the score reaches one of these.
    localparam [5:0] FASTER_AT_1 = 6'd8;
    localparam [5:0] FASTER_AT_2 = 6'd16;
    localparam [5:0] FASTER_AT_3 = 6'd24;

    // How long the red flash lasts after a miss, in frames. 63 at most.
    localparam [5:0] MISS_FRAMES = 6'd40;

    // The court. These numbers fit together, so change them as a set.
    localparam [9:0] SCREEN_W     = 10'd640;
    localparam [9:0] SCREEN_H     = 10'd480;
    localparam [9:0] CEILING      = 10'd24;    // the ball turns back here
    localparam [9:0] PADDLE_Y     = 10'd444;   // how far down the screen the paddle sits
    localparam [9:0] BALL_START_Y = 10'd120;   // how far down the ball starts each game

    // The brick wall: 10 columns of 64 pixels, 4 rows of 16 pixels.
    // The rows must start on a multiple of 16 (48 = 3 * 16) so the maths stays tiny.
    localparam [9:0] BRICK_TOP    = 10'd48;
    localparam [9:0] BRICK_BOTTOM = 10'd112;   // BRICK_TOP + 4 rows * 16

    // ========================================================================
    // 2. WIRING
    //    The pins and the monitor's timing. Leave this section as it is.
    // ========================================================================

    wire       hsync;
    wire       vsync;
    wire       video_active;
    wire [9:0] pix_x;          // the pixel being drawn now: 0 to 639 across
    wire [9:0] pix_y;          // and 0 to 479 down

    hvsync_generator hvsync_gen (
        .clk(clk),
        .reset(~rst_n),
        .hsync(hsync),
        .vsync(vsync),
        .display_on(video_active),
        .hpos(pix_x),
        .vpos(pix_y)
    );

    wire move_left  = ui_in[0] & ~ui_in[1];
    wire move_right = ui_in[1] & ~ui_in[0];

    // High for one clock as each frame ends. The game moves on once per frame.
    reg  vsync_q;
    wire new_frame = vsync_q & ~vsync;

    // ========================================================================
    // 3. THE GAME
    //    A few registers hold where everything is. They change once per frame.
    // ========================================================================

    reg [9:0]  ball_x;         // top left corner of the ball
    reg [9:0]  ball_y;
    reg        going_right;    // which way the ball is moving, sideways ...
    reg        going_down;     // ... and up or down
    reg [9:0]  paddle_x;       // left edge of the paddle
    reg [5:0]  score;          // bricks broken, up to 63
    reg [1:0]  lives;          // balls left: 3 at the start
    reg [5:0]  miss_timer;     // frames of flash left after a miss, 0 while playing
    reg [39:0] bricks;         // one bit per brick: 1 = still there. Bit = row * 10 + column
    reg [15:0] random;         // shifts every clock, so its value looks random

    // Worked out from the settings, so they stay right when you change a size.
    localparam [9:0] PADDLE_MAX   = SCREEN_W - PADDLE_W;           // as far right as the paddle goes
    localparam [9:0] PADDLE_START = (SCREEN_W - PADDLE_W) >> 1;    // the paddle starts in the middle
    localparam [9:0] BALL_START_X = (SCREEN_W - BALL_SIZE) >> 1;   // and so does the ball
    localparam [9:0] BALL_HALF    = BALL_SIZE >> 1;
    localparam [9:0] PADDLE_HALF  = PADDLE_W >> 1;

    // How far the ball moves this frame: faster as the score grows.
    wire [3:0] speed = (score >= FASTER_AT_3) ? START_SPEED + 4'd3 :
                       (score >= FASTER_AT_2) ? START_SPEED + 4'd2 :
                       (score >= FASTER_AT_1) ? START_SPEED + 4'd1 : START_SPEED;
    wire [9:0] step = {6'd0, speed};

    // ---- the paddle: does the ball land on it this frame, or go past it?
    wire [9:0] ball_bottom  = ball_y + BALL_SIZE;
    wire       over_paddle  = (ball_x + BALL_SIZE > paddle_x) && (ball_x < paddle_x + PADDLE_W);
    wire       reaches_line = (ball_bottom + step >= PADDLE_Y) && (ball_bottom <= PADDLE_Y + PADDLE_H);
    wire       hit_paddle   = going_down && over_paddle && reaches_line;
    wire       falls_out    = going_down && !hit_paddle && (ball_bottom + step >= SCREEN_H);

    // A catch left of the paddle's middle sends the ball left, and right of it, right.
    wire       right_half   = (ball_x + BALL_HALF >= paddle_x + PADDLE_HALF);

    // ---- where the ball will be next frame (before any brick is considered)
    wire hit_right_wall = going_right  && (ball_x + BALL_SIZE + step >= SCREEN_W);
    wire hit_left_wall  = !going_right && (ball_x <= step);
    wire hit_ceiling    = !going_down  && (ball_y <= CEILING + step);

    wire [9:0] next_x = hit_right_wall ? SCREEN_W - BALL_SIZE :
                        hit_left_wall  ? 10'd0 :
                        going_right    ? ball_x + step : ball_x - step;
    wire [9:0] next_y = hit_paddle     ? PADDLE_Y - BALL_SIZE :
                        hit_ceiling    ? CEILING :
                        going_down     ? ball_y + step : ball_y - step;

    // The direction after walls, ceiling and paddle have had their say.
    wire right_after = hit_paddle ? right_half :
                       hit_right_wall ? 1'b0 :
                       hit_left_wall  ? 1'b1 : going_right;
    wire down_after  = hit_paddle ? 1'b0 :
                       hit_ceiling ? 1'b1 : going_down;

    // ---- the bricks: look at the brick under the middle of the ball's next position
    wire [9:0] new_cx = next_x + BALL_HALF;
    wire [9:0] new_cy = next_y + BALL_HALF;
    wire [9:0] old_cx = ball_x + BALL_HALF;
    wire [9:0] old_cy = ball_y + BALL_HALF;

    wire       new_in_wall = (new_cy >= BRICK_TOP) && (new_cy < BRICK_BOTTOM);
    wire [2:0] new_row     = new_cy[6:4] - 3'd3;     // 0 to 3 inside the wall
    wire [3:0] new_col     = new_cx[9:6];            // 0 to 9
    wire [5:0] new_idx     = {new_row, 3'b000} + {2'b00, new_row, 1'b0} + {2'b00, new_col};  // row * 10 + col

    wire brick_here = new_in_wall && bricks[new_idx];
    wire brick_hit  = brick_here && !hit_paddle && !falls_out;

    // Which way to bounce: if the ball crossed into a new row, turn it up/down;
    // if it only crossed into a new column, turn it left/right.
    wire row_changed = (new_cy[9:4] != old_cy[9:4]);
    wire col_changed = (new_cx[9:6] != old_cx[9:6]);
    wire flip_y      = row_changed || !col_changed;
    wire flip_x      = col_changed && !row_changed;

    always @(posedge clk) begin
        random  <= {random[14:0], random[15] ^ random[13] ^ random[12] ^ random[10]};
        vsync_q <= vsync;

        if (~rst_n) begin
            ball_x      <= BALL_START_X;
            ball_y      <= BALL_START_Y;
            going_right <= 1'b1;
            going_down  <= 1'b1;
            paddle_x    <= PADDLE_START;
            score       <= 6'd0;
            lives       <= 2'd3;
            miss_timer  <= 6'd0;
            bricks      <= {40{1'b1}};
            random      <= 16'hACE1;
        end else if (new_frame) begin
            if (miss_timer != 6'd0) begin
                // ---- after a miss: count the flash down, then serve again
                miss_timer <= miss_timer - 6'd1;
                if (miss_timer == 6'd1) begin
                    ball_x      <= BALL_START_X;
                    ball_y      <= BALL_START_Y;
                    going_right <= random[0];
                    going_down  <= 1'b1;
                    if (lives == 2'd0) begin
                        // out of lives: a brand new game
                        score  <= 6'd0;
                        lives  <= 2'd3;
                        bricks <= {40{1'b1}};
                    end
                end
            end else if (bricks == 40'd0) begin
                // ---- wall cleared: build it again and serve
                bricks      <= {40{1'b1}};
                ball_x      <= BALL_START_X;
                ball_y      <= BALL_START_Y;
                going_right <= random[0];
                going_down  <= 1'b1;
            end else begin
                // ---- the paddle: move sideways, and stop at the edge of the screen
                if (move_left)  paddle_x <= (paddle_x > PADDLE_STEP) ? paddle_x - PADDLE_STEP : 10'd0;
                if (move_right) paddle_x <= (paddle_x < PADDLE_MAX - PADDLE_STEP) ? paddle_x + PADDLE_STEP : PADDLE_MAX;

                // ---- the ball: move, with a brick hit turning it on top of any wall bounce
                ball_x      <= next_x;
                going_right <= right_after ^ (brick_hit & flip_x);
                going_down  <= down_after  ^ (brick_hit & flip_y);

                if (falls_out) begin
                    // missed: lose a life, freeze the ball and flash
                    miss_timer <= MISS_FRAMES;
                    lives      <= lives - 2'd1;
                end else begin
                    ball_y <= next_y;
                end

                if (brick_hit) begin
                    bricks[new_idx] <= 1'b0;
                    if (score != 6'd63) score <= score + 6'd1;
                end
            end
        end
    end

    // ========================================================================
    // 4. DRAWING
    //    One question for each thing on screen: is this pixel inside it?
    // ========================================================================

    wire in_ball   = (pix_x >= ball_x)   && (pix_x < ball_x + BALL_SIZE) &&
                     (pix_y >= ball_y)   && (pix_y < ball_y + BALL_SIZE);
    wire in_paddle = (pix_x >= paddle_x) && (pix_x < paddle_x + PADDLE_W) &&
                     (pix_y >= PADDLE_Y) && (pix_y < PADDLE_Y + PADDLE_H);

    // The two side walls, and the ceiling line the ball turns back at.
    wire in_wall   = (pix_x < 10'd4) || (pix_x >= SCREEN_W - 10'd4) ||
                     ((pix_y >= CEILING - 10'd4) && (pix_y < CEILING));

    // The score bar: eight pixels longer for every brick.
    wire in_score  = (pix_y >= 10'd8) && (pix_y < 10'd16) &&
                     (pix_x >= 10'd8) && (pix_x < 10'd8 + {1'b0, score, 3'b000});

    // The lives: a 12 pixel square for each ball left, in the top right corner.
    wire [5:0] life_slot = pix_x[9:4] - 6'd36;
    wire in_lives  = (pix_y >= 10'd8) && (pix_y < 10'd16) &&
                     (pix_x[9:4] >= 6'd36) && (life_slot < {4'd0, lives}) &&
                     (pix_x[3:0] < 4'd12);

    // The bricks: the wall is 64 pixels per brick across, 16 down. The last
    // couple of pixels of each brick are left empty so you can see the edges.
    wire       px_in_wall = (pix_y >= BRICK_TOP) && (pix_y < BRICK_BOTTOM);
    wire [2:0] px_row     = pix_y[6:4] - 3'd3;
    wire [3:0] px_col     = pix_x[9:6];
    wire [5:0] px_idx     = {px_row, 3'b000} + {2'b00, px_row, 1'b0} + {2'b00, px_col};
    wire in_brick  = px_in_wall && bricks[px_idx] &&
                     (pix_x[5:0] < 6'd62) && (pix_y[3:0] < 4'd14);

    reg [5:0] brick_colour;
    always @(*) begin
        case (px_row[1:0])
            2'd0:    brick_colour = BRICK_ROW0_COLOUR;
            2'd1:    brick_colour = BRICK_ROW1_COLOUR;
            2'd2:    brick_colour = BRICK_ROW2_COLOUR;
            default: brick_colour = BRICK_ROW3_COLOUR;
        endcase
    end

    // A line every 64 pixels, across and down.
    wire in_grid   = (pix_x[5:0] == 6'd0) || (pix_y[5:0] == 6'd0);

    // The first line that matches wins, so anything higher up is drawn on top
    // of anything lower down. Move a line to change what covers what.
    reg [5:0] colour;
    always @(*) begin
        if (~video_active)  colour = 6'b000000;
        else if (in_score)  colour = SCORE_COLOUR;
        else if (in_lives)  colour = LIVES_COLOUR;
        else if (in_ball)   colour = BALL_COLOUR;
        else if (in_paddle) colour = PADDLE_COLOUR;
        else if (in_brick)  colour = brick_colour;
        else if (in_wall)   colour = WALL_COLOUR;
        else if (in_grid)   colour = GRID_COLOUR;
        else                colour = BACKGROUND_COLOUR;
    end

    // The miss flash: for four frames in every eight, full red with green and blue dimmed.
    wire       flash = (miss_timer != 6'd0) && miss_timer[2];
    wire [5:0] shown = flash ? {2'b11, 1'b0, colour[3], 1'b0, colour[1]} : colour;

    // ---- to the pins, in the order the TinyVGA adapter expects. Leave as it is.
    wire [1:0] R = shown[5:4];
    wire [1:0] G = shown[3:2];
    wire [1:0] B = shown[1:0];

    assign uo_out  = {hsync, B[0], G[0], R[0], vsync, B[1], G[1], R[1]};
    assign uio_out = 8'h00;
    assign uio_oe  = 8'h00;

    wire _unused_ok = &{ena, uio_in, ui_in[7:2]};

endmodule
