%%% -*- erlang -*-
%%%
%%% This file is part of erlang_qpack released under the Apache 2 license.
%%% See the NOTICE for more information.
%%%
%%% Copyright (c) 2024-2026 Benoit Chesneau
%%%
%%% @doc Huffman encoding lookup table for QPACK (RFC 9204).
%%%
%%% RFC 7541 Appendix B defines the Huffman code table used by both
%%% HPACK (HTTP/2) and QPACK (HTTP/3). This file provides pre-computed
%%% lookup for fast encoding.
%%% @end

%% Huffman encoding table: {Code, BitLength}
%% Each entry is {huffman code bits, number of bits}
%% The codes are stored MSB-first as integers.

-define(HUFFMAN_ENCODE_TABLE, {
    %% 0-15 (control characters)

    %% 0
    {16#1ff8, 13},
    %% 1
    {16#7fffd8, 23},
    %% 2
    {16#fffffe2, 28},
    %% 3
    {16#fffffe3, 28},
    %% 4
    {16#fffffe4, 28},
    %% 5
    {16#fffffe5, 28},
    %% 6
    {16#fffffe6, 28},
    %% 7
    {16#fffffe7, 28},
    %% 8
    {16#fffffe8, 28},
    %% 9 (TAB)
    {16#ffffea, 24},
    %% 10 (LF)
    {16#3ffffffc, 30},
    %% 11
    {16#fffffe9, 28},
    %% 12
    {16#fffffea, 28},
    %% 13 (CR)
    {16#3ffffffd, 30},
    %% 14
    {16#fffffeb, 28},
    %% 15
    {16#fffffec, 28},

    %% 16-31 (more control characters)

    %% 16
    {16#fffffed, 28},
    %% 17
    {16#fffffee, 28},
    %% 18
    {16#fffffef, 28},
    %% 19
    {16#ffffff0, 28},
    %% 20
    {16#ffffff1, 28},
    %% 21
    {16#ffffff2, 28},
    %% 22
    {16#3ffffffe, 30},
    %% 23
    {16#ffffff3, 28},
    %% 24
    {16#ffffff4, 28},
    %% 25
    {16#ffffff5, 28},
    %% 26
    {16#ffffff6, 28},
    %% 27
    {16#ffffff7, 28},
    %% 28
    {16#ffffff8, 28},
    %% 29
    {16#ffffff9, 28},
    %% 30
    {16#ffffffa, 28},
    %% 31
    {16#ffffffb, 28},

    %% 32-47 (printable ASCII start)

    %% 32 ' '
    {16#14, 6},
    %% 33 '!'
    {16#3f8, 10},
    %% 34 '"'
    {16#3f9, 10},
    %% 35 '#'
    {16#ffa, 12},
    %% 36 '$'
    {16#1ff9, 13},
    %% 37 '%'
    {16#15, 6},
    %% 38 '&'
    {16#f8, 8},
    %% 39 '''
    {16#7fa, 11},
    %% 40 '('
    {16#3fa, 10},
    %% 41 ')'
    {16#3fb, 10},
    %% 42 '*'
    {16#f9, 8},
    %% 43 '+'
    {16#7fb, 11},
    %% 44 ','
    {16#fa, 8},
    %% 45 '-'
    {16#16, 6},
    %% 46 '.'
    {16#17, 6},
    %% 47 '/'
    {16#18, 6},

    %% 48-63 (digits and some symbols)

    %% 48 '0'
    {16#0, 5},
    %% 49 '1'
    {16#1, 5},
    %% 50 '2'
    {16#2, 5},
    %% 51 '3'
    {16#19, 6},
    %% 52 '4'
    {16#1a, 6},
    %% 53 '5'
    {16#1b, 6},
    %% 54 '6'
    {16#1c, 6},
    %% 55 '7'
    {16#1d, 6},
    %% 56 '8'
    {16#1e, 6},
    %% 57 '9'
    {16#1f, 6},
    %% 58 ':'
    {16#5c, 7},
    %% 59 ';'
    {16#fb, 8},
    %% 60 '<'
    {16#7ffc, 15},
    %% 61 '='
    {16#20, 6},
    %% 62 '>'
    {16#ffb, 12},
    %% 63 '?'
    {16#3fc, 10},

    %% 64-79 (uppercase letters start)

    %% 64 '@'
    {16#1ffa, 13},
    %% 65 'A'
    {16#21, 6},
    %% 66 'B'
    {16#5d, 7},
    %% 67 'C'
    {16#5e, 7},
    %% 68 'D'
    {16#5f, 7},
    %% 69 'E'
    {16#60, 7},
    %% 70 'F'
    {16#61, 7},
    %% 71 'G'
    {16#62, 7},
    %% 72 'H'
    {16#63, 7},
    %% 73 'I'
    {16#64, 7},
    %% 74 'J'
    {16#65, 7},
    %% 75 'K'
    {16#66, 7},
    %% 76 'L'
    {16#67, 7},
    %% 77 'M'
    {16#68, 7},
    %% 78 'N'
    {16#69, 7},
    %% 79 'O'
    {16#6a, 7},

    %% 80-95 (uppercase letters continue)

    %% 80 'P'
    {16#6b, 7},
    %% 81 'Q'
    {16#6c, 7},
    %% 82 'R'
    {16#6d, 7},
    %% 83 'S'
    {16#6e, 7},
    %% 84 'T'
    {16#6f, 7},
    %% 85 'U'
    {16#70, 7},
    %% 86 'V'
    {16#71, 7},
    %% 87 'W'
    {16#72, 7},
    %% 88 'X'
    {16#fc, 8},
    %% 89 'Y'
    {16#73, 7},
    %% 90 'Z'
    {16#fd, 8},
    %% 91 '['
    {16#1ffb, 13},
    %% 92 '\'
    {16#7fff0, 19},
    %% 93 ']'
    {16#1ffc, 13},
    %% 94 '^'
    {16#3ffc, 14},
    %% 95 '_'
    {16#22, 6},

    %% 96-111 (lowercase letters start)

    %% 96 '`'
    {16#7ffd, 15},
    %% 97 'a'
    {16#3, 5},
    %% 98 'b'
    {16#23, 6},
    %% 99 'c'
    {16#4, 5},
    %% 100 'd'
    {16#24, 6},
    %% 101 'e'
    {16#5, 5},
    %% 102 'f'
    {16#25, 6},
    %% 103 'g'
    {16#26, 6},
    %% 104 'h'
    {16#27, 6},
    %% 105 'i'
    {16#6, 5},
    %% 106 'j'
    {16#74, 7},
    %% 107 'k'
    {16#75, 7},
    %% 108 'l'
    {16#28, 6},
    %% 109 'm'
    {16#29, 6},
    %% 110 'n'
    {16#2a, 6},
    %% 111 'o'
    {16#7, 5},

    %% 112-127 (lowercase letters continue)

    %% 112 'p'
    {16#2b, 6},
    %% 113 'q'
    {16#76, 7},
    %% 114 'r'
    {16#2c, 6},
    %% 115 's'
    {16#8, 5},
    %% 116 't'
    {16#9, 5},
    %% 117 'u'
    {16#2d, 6},
    %% 118 'v'
    {16#77, 7},
    %% 119 'w'
    {16#78, 7},
    %% 120 'x'
    {16#79, 7},
    %% 121 'y'
    {16#7a, 7},
    %% 122 'z'
    {16#7b, 7},
    %% 123 '{'
    {16#7ffe, 15},
    %% 124 '|'
    {16#7fc, 11},
    %% 125 '}'
    {16#3ffd, 14},
    %% 126 '~'
    {16#1ffd, 13},
    %% 127 (DEL)
    {16#ffffffc, 28},

    %% 128-143 (extended ASCII)

    %% 128
    {16#fffe6, 20},
    %% 129
    {16#3fffd2, 22},
    %% 130
    {16#fffe7, 20},
    %% 131
    {16#fffe8, 20},
    %% 132
    {16#3fffd3, 22},
    %% 133
    {16#3fffd4, 22},
    %% 134
    {16#3fffd5, 22},
    %% 135
    {16#7fffd9, 23},
    %% 136
    {16#3fffd6, 22},
    %% 137
    {16#7fffda, 23},
    %% 138
    {16#7fffdb, 23},
    %% 139
    {16#7fffdc, 23},
    %% 140
    {16#7fffdd, 23},
    %% 141
    {16#7fffde, 23},
    %% 142
    {16#ffffeb, 24},
    %% 143
    {16#7fffdf, 23},

    %% 144-159

    %% 144
    {16#ffffec, 24},
    %% 145
    {16#ffffed, 24},
    %% 146
    {16#3fffd7, 22},
    %% 147
    {16#7fffe0, 23},
    %% 148
    {16#ffffee, 24},
    %% 149
    {16#7fffe1, 23},
    %% 150
    {16#7fffe2, 23},
    %% 151
    {16#7fffe3, 23},
    %% 152
    {16#7fffe4, 23},
    %% 153
    {16#1fffdc, 21},
    %% 154
    {16#3fffd8, 22},
    %% 155
    {16#7fffe5, 23},
    %% 156
    {16#3fffd9, 22},
    %% 157
    {16#7fffe6, 23},
    %% 158
    {16#7fffe7, 23},
    %% 159
    {16#ffffef, 24},

    %% 160-175

    %% 160
    {16#3fffda, 22},
    %% 161
    {16#1fffdd, 21},
    %% 162
    {16#fffe9, 20},
    %% 163
    {16#3fffdb, 22},
    %% 164
    {16#3fffdc, 22},
    %% 165
    {16#7fffe8, 23},
    %% 166
    {16#7fffe9, 23},
    %% 167
    {16#1fffde, 21},
    %% 168
    {16#7fffea, 23},
    %% 169
    {16#3fffdd, 22},
    %% 170
    {16#3fffde, 22},
    %% 171
    {16#fffff0, 24},
    %% 172
    {16#1fffdf, 21},
    %% 173
    {16#3fffdf, 22},
    %% 174
    {16#7fffeb, 23},
    %% 175
    {16#7fffec, 23},

    %% 176-191

    %% 176
    {16#1fffe0, 21},
    %% 177
    {16#1fffe1, 21},
    %% 178
    {16#3fffe0, 22},
    %% 179
    {16#1fffe2, 21},
    %% 180
    {16#7fffed, 23},
    %% 181
    {16#3fffe1, 22},
    %% 182
    {16#7fffee, 23},
    %% 183
    {16#7fffef, 23},
    %% 184
    {16#fffea, 20},
    %% 185
    {16#3fffe2, 22},
    %% 186
    {16#3fffe3, 22},
    %% 187
    {16#3fffe4, 22},
    %% 188
    {16#7ffff0, 23},
    %% 189
    {16#3fffe5, 22},
    %% 190
    {16#3fffe6, 22},
    %% 191
    {16#7ffff1, 23},

    %% 192-207

    %% 192
    {16#3ffffe0, 26},
    %% 193
    {16#3ffffe1, 26},
    %% 194
    {16#fffeb, 20},
    %% 195
    {16#7fff1, 19},
    %% 196
    {16#3fffe7, 22},
    %% 197
    {16#7ffff2, 23},
    %% 198
    {16#3fffe8, 22},
    %% 199
    {16#1ffffec, 25},
    %% 200
    {16#3ffffe2, 26},
    %% 201
    {16#3ffffe3, 26},
    %% 202
    {16#3ffffe4, 26},
    %% 203
    {16#7ffffde, 27},
    %% 204
    {16#7ffffdf, 27},
    %% 205
    {16#3ffffe5, 26},
    %% 206
    {16#fffff1, 24},
    %% 207
    {16#1ffffed, 25},

    %% 208-223

    %% 208
    {16#7fff2, 19},
    %% 209
    {16#1fffe3, 21},
    %% 210
    {16#3ffffe6, 26},
    %% 211
    {16#7ffffe0, 27},
    %% 212
    {16#7ffffe1, 27},
    %% 213
    {16#3ffffe7, 26},
    %% 214
    {16#7ffffe2, 27},
    %% 215
    {16#fffff2, 24},
    %% 216
    {16#1fffe4, 21},
    %% 217
    {16#1fffe5, 21},
    %% 218
    {16#3ffffe8, 26},
    %% 219
    {16#3ffffe9, 26},
    %% 220
    {16#ffffffd, 28},
    %% 221
    {16#7ffffe3, 27},
    %% 222
    {16#7ffffe4, 27},
    %% 223
    {16#7ffffe5, 27},

    %% 224-239

    %% 224
    {16#fffec, 20},
    %% 225
    {16#fffff3, 24},
    %% 226
    {16#fffed, 20},
    %% 227
    {16#1fffe6, 21},
    %% 228
    {16#3fffe9, 22},
    %% 229
    {16#1fffe7, 21},
    %% 230
    {16#1fffe8, 21},
    %% 231
    {16#7ffff3, 23},
    %% 232
    {16#3fffea, 22},
    %% 233
    {16#3fffeb, 22},
    %% 234
    {16#1ffffee, 25},
    %% 235
    {16#1ffffef, 25},
    %% 236
    {16#fffff4, 24},
    %% 237
    {16#fffff5, 24},
    %% 238
    {16#3ffffea, 26},
    %% 239
    {16#7ffff4, 23},

    %% 240-255

    %% 240
    {16#3ffffeb, 26},
    %% 241
    {16#7ffffe6, 27},
    %% 242
    {16#3ffffec, 26},
    %% 243
    {16#3ffffed, 26},
    %% 244
    {16#7ffffe7, 27},
    %% 245
    {16#7ffffe8, 27},
    %% 246
    {16#7ffffe9, 27},
    %% 247
    {16#7ffffea, 27},
    %% 248
    {16#7ffffeb, 27},
    %% 249
    {16#ffffffe, 28},
    %% 250
    {16#7ffffec, 27},
    %% 251
    {16#7ffffed, 27},
    %% 252
    {16#7ffffee, 27},
    %% 253
    {16#7ffffef, 27},
    %% 254
    {16#7fffff0, 27},
    %% 255
    {16#3ffffee, 26}
}).

%% EOS symbol (256) used for padding: code = 0x3fffffff, len = 30
-define(HUFFMAN_EOS_CODE, 16#3fffffff).
-define(HUFFMAN_EOS_BITS, 30).

%% Pre-encoded common header values for O(1) access
%% These are the Huffman-encoded forms of common values

%% Common methods (pre-encoded with huffman)

%% "GET" huffman encoded
-define(HUFFMAN_GET, <<16#c1>>).
%% "POST" huffman encoded
-define(HUFFMAN_POST, <<16#e1, 16#bf>>).

%% Common status codes (pre-encoded with huffman)

%% "200" huffman encoded
-define(HUFFMAN_200, <<16#08>>).
%% "204" huffman encoded
-define(HUFFMAN_204, <<16#09, 16#a2>>).
%% "206" huffman encoded
-define(HUFFMAN_206, <<16#09, 16#c2>>).
%% "304" huffman encoded
-define(HUFFMAN_304, <<16#1a, 16#62>>).
%% "400" huffman encoded
-define(HUFFMAN_400, <<16#4c, 16#08>>).
%% "404" huffman encoded
-define(HUFFMAN_404, <<16#4c, 16#62>>).
%% "500" huffman encoded
-define(HUFFMAN_500, <<16#a2, 16#08>>).

%% Macro to get huffman code for a byte value (0-255)
%% Returns {Code, BitLength}
-define(HUFFMAN_CODE(Byte), element(Byte + 1, ?HUFFMAN_ENCODE_TABLE)).
