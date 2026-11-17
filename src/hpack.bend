import Base
import ./http.bend as H

# HPACK
# =====
#
# HTTP/2's header compression (RFC 7541): the header block a HEADERS frame
# carries, decoded into headers and encoded from them. Each side of a
# connection keeps a dynamic table of recent headers, which index the
# static table's 61 entries and then its own; both ends evict the oldest
# entries the same way, so the tables stay in step.
#
# A header's name and value are octets: a String whose every Char is a
# byte, Chr{0} to Chr{255}. gRPC sends ASCII; a -bin header's value is
# base64 on the wire.
#
# The decoder reads a byte at a time and refuses a header block that ends
# inside a field, an index with no entry, a table size update past the
# limit or after a header, an integer past 2^28, bad Huffman padding or
# EOS inside a string, and a header list past its cap (each header counts
# its name and value plus 32, as SETTINGS_MAX_HEADER_LIST_SIZE does), so a
# few indexed bytes cannot expand into an unbounded list.
#
# The encoder sends a header found whole in a table as its index, and
# anything else as a literal added to the table, its name indexed when a
# table has it; with huff on, a string goes Huffman-coded unless that is
# longer. That is the choice RFC 7541's Appendix C makes, so its encoder
# examples come out byte for byte.

type HCode is Data:
  HCode{code: U32, len: U32}

type HLen is Data:
  HLen{first: U32, count: U32, offset: U32}

# Tables
# ------
#
# Generated from RFC 7541 by tools/hpack_tables.py: do not edit by hand.

# The static table (Appendix A), index 1 first.
def Hp.statics() -> List<&2, H.Header>:
  [H.Header{":authority", ""},
    H.Header{":method", "GET"},
    H.Header{":method", "POST"},
    H.Header{":path", "/"},
    H.Header{":path", "/index.html"},
    H.Header{":scheme", "http"},
    H.Header{":scheme", "https"},
    H.Header{":status", "200"},
    H.Header{":status", "204"},
    H.Header{":status", "206"},
    H.Header{":status", "304"},
    H.Header{":status", "400"},
    H.Header{":status", "404"},
    H.Header{":status", "500"},
    H.Header{"accept-charset", ""},
    H.Header{"accept-encoding", "gzip, deflate"},
    H.Header{"accept-language", ""},
    H.Header{"accept-ranges", ""},
    H.Header{"accept", ""},
    H.Header{"access-control-allow-origin", ""},
    H.Header{"age", ""},
    H.Header{"allow", ""},
    H.Header{"authorization", ""},
    H.Header{"cache-control", ""},
    H.Header{"content-disposition", ""},
    H.Header{"content-encoding", ""},
    H.Header{"content-language", ""},
    H.Header{"content-length", ""},
    H.Header{"content-location", ""},
    H.Header{"content-range", ""},
    H.Header{"content-type", ""},
    H.Header{"cookie", ""},
    H.Header{"date", ""},
    H.Header{"etag", ""},
    H.Header{"expect", ""},
    H.Header{"expires", ""},
    H.Header{"from", ""},
    H.Header{"host", ""},
    H.Header{"if-match", ""},
    H.Header{"if-modified-since", ""},
    H.Header{"if-none-match", ""},
    H.Header{"if-range", ""},
    H.Header{"if-unmodified-since", ""},
    H.Header{"last-modified", ""},
    H.Header{"link", ""},
    H.Header{"location", ""},
    H.Header{"max-forwards", ""},
    H.Header{"proxy-authenticate", ""},
    H.Header{"proxy-authorization", ""},
    H.Header{"range", ""},
    H.Header{"referer", ""},
    H.Header{"refresh", ""},
    H.Header{"retry-after", ""},
    H.Header{"server", ""},
    H.Header{"set-cookie", ""},
    H.Header{"strict-transport-security", ""},
    H.Header{"transfer-encoding", ""},
    H.Header{"user-agent", ""},
    H.Header{"vary", ""},
    H.Header{"via", ""},
    H.Header{"www-authenticate", ""}]

# Each symbol's Huffman code and its length in bits (Appendix B).
def Hp.code(s: U32) -> HCode:
  match s:
    case 0:
      HCode{8184, 13}
    case 1:
      HCode{8388568, 23}
    case 2:
      HCode{268435426, 28}
    case 3:
      HCode{268435427, 28}
    case 4:
      HCode{268435428, 28}
    case 5:
      HCode{268435429, 28}
    case 6:
      HCode{268435430, 28}
    case 7:
      HCode{268435431, 28}
    case 8:
      HCode{268435432, 28}
    case 9:
      HCode{16777194, 24}
    case 10:
      HCode{1073741820, 30}
    case 11:
      HCode{268435433, 28}
    case 12:
      HCode{268435434, 28}
    case 13:
      HCode{1073741821, 30}
    case 14:
      HCode{268435435, 28}
    case 15:
      HCode{268435436, 28}
    case 16:
      HCode{268435437, 28}
    case 17:
      HCode{268435438, 28}
    case 18:
      HCode{268435439, 28}
    case 19:
      HCode{268435440, 28}
    case 20:
      HCode{268435441, 28}
    case 21:
      HCode{268435442, 28}
    case 22:
      HCode{1073741822, 30}
    case 23:
      HCode{268435443, 28}
    case 24:
      HCode{268435444, 28}
    case 25:
      HCode{268435445, 28}
    case 26:
      HCode{268435446, 28}
    case 27:
      HCode{268435447, 28}
    case 28:
      HCode{268435448, 28}
    case 29:
      HCode{268435449, 28}
    case 30:
      HCode{268435450, 28}
    case 31:
      HCode{268435451, 28}
    case 32:
      HCode{20, 6}
    case 33:
      HCode{1016, 10}
    case 34:
      HCode{1017, 10}
    case 35:
      HCode{4090, 12}
    case 36:
      HCode{8185, 13}
    case 37:
      HCode{21, 6}
    case 38:
      HCode{248, 8}
    case 39:
      HCode{2042, 11}
    case 40:
      HCode{1018, 10}
    case 41:
      HCode{1019, 10}
    case 42:
      HCode{249, 8}
    case 43:
      HCode{2043, 11}
    case 44:
      HCode{250, 8}
    case 45:
      HCode{22, 6}
    case 46:
      HCode{23, 6}
    case 47:
      HCode{24, 6}
    case 48:
      HCode{0, 5}
    case 49:
      HCode{1, 5}
    case 50:
      HCode{2, 5}
    case 51:
      HCode{25, 6}
    case 52:
      HCode{26, 6}
    case 53:
      HCode{27, 6}
    case 54:
      HCode{28, 6}
    case 55:
      HCode{29, 6}
    case 56:
      HCode{30, 6}
    case 57:
      HCode{31, 6}
    case 58:
      HCode{92, 7}
    case 59:
      HCode{251, 8}
    case 60:
      HCode{32764, 15}
    case 61:
      HCode{32, 6}
    case 62:
      HCode{4091, 12}
    case 63:
      HCode{1020, 10}
    case 64:
      HCode{8186, 13}
    case 65:
      HCode{33, 6}
    case 66:
      HCode{93, 7}
    case 67:
      HCode{94, 7}
    case 68:
      HCode{95, 7}
    case 69:
      HCode{96, 7}
    case 70:
      HCode{97, 7}
    case 71:
      HCode{98, 7}
    case 72:
      HCode{99, 7}
    case 73:
      HCode{100, 7}
    case 74:
      HCode{101, 7}
    case 75:
      HCode{102, 7}
    case 76:
      HCode{103, 7}
    case 77:
      HCode{104, 7}
    case 78:
      HCode{105, 7}
    case 79:
      HCode{106, 7}
    case 80:
      HCode{107, 7}
    case 81:
      HCode{108, 7}
    case 82:
      HCode{109, 7}
    case 83:
      HCode{110, 7}
    case 84:
      HCode{111, 7}
    case 85:
      HCode{112, 7}
    case 86:
      HCode{113, 7}
    case 87:
      HCode{114, 7}
    case 88:
      HCode{252, 8}
    case 89:
      HCode{115, 7}
    case 90:
      HCode{253, 8}
    case 91:
      HCode{8187, 13}
    case 92:
      HCode{524272, 19}
    case 93:
      HCode{8188, 13}
    case 94:
      HCode{16380, 14}
    case 95:
      HCode{34, 6}
    case 96:
      HCode{32765, 15}
    case 97:
      HCode{3, 5}
    case 98:
      HCode{35, 6}
    case 99:
      HCode{4, 5}
    case 100:
      HCode{36, 6}
    case 101:
      HCode{5, 5}
    case 102:
      HCode{37, 6}
    case 103:
      HCode{38, 6}
    case 104:
      HCode{39, 6}
    case 105:
      HCode{6, 5}
    case 106:
      HCode{116, 7}
    case 107:
      HCode{117, 7}
    case 108:
      HCode{40, 6}
    case 109:
      HCode{41, 6}
    case 110:
      HCode{42, 6}
    case 111:
      HCode{7, 5}
    case 112:
      HCode{43, 6}
    case 113:
      HCode{118, 7}
    case 114:
      HCode{44, 6}
    case 115:
      HCode{8, 5}
    case 116:
      HCode{9, 5}
    case 117:
      HCode{45, 6}
    case 118:
      HCode{119, 7}
    case 119:
      HCode{120, 7}
    case 120:
      HCode{121, 7}
    case 121:
      HCode{122, 7}
    case 122:
      HCode{123, 7}
    case 123:
      HCode{32766, 15}
    case 124:
      HCode{2044, 11}
    case 125:
      HCode{16381, 14}
    case 126:
      HCode{8189, 13}
    case 127:
      HCode{268435452, 28}
    case 128:
      HCode{1048550, 20}
    case 129:
      HCode{4194258, 22}
    case 130:
      HCode{1048551, 20}
    case 131:
      HCode{1048552, 20}
    case 132:
      HCode{4194259, 22}
    case 133:
      HCode{4194260, 22}
    case 134:
      HCode{4194261, 22}
    case 135:
      HCode{8388569, 23}
    case 136:
      HCode{4194262, 22}
    case 137:
      HCode{8388570, 23}
    case 138:
      HCode{8388571, 23}
    case 139:
      HCode{8388572, 23}
    case 140:
      HCode{8388573, 23}
    case 141:
      HCode{8388574, 23}
    case 142:
      HCode{16777195, 24}
    case 143:
      HCode{8388575, 23}
    case 144:
      HCode{16777196, 24}
    case 145:
      HCode{16777197, 24}
    case 146:
      HCode{4194263, 22}
    case 147:
      HCode{8388576, 23}
    case 148:
      HCode{16777198, 24}
    case 149:
      HCode{8388577, 23}
    case 150:
      HCode{8388578, 23}
    case 151:
      HCode{8388579, 23}
    case 152:
      HCode{8388580, 23}
    case 153:
      HCode{2097116, 21}
    case 154:
      HCode{4194264, 22}
    case 155:
      HCode{8388581, 23}
    case 156:
      HCode{4194265, 22}
    case 157:
      HCode{8388582, 23}
    case 158:
      HCode{8388583, 23}
    case 159:
      HCode{16777199, 24}
    case 160:
      HCode{4194266, 22}
    case 161:
      HCode{2097117, 21}
    case 162:
      HCode{1048553, 20}
    case 163:
      HCode{4194267, 22}
    case 164:
      HCode{4194268, 22}
    case 165:
      HCode{8388584, 23}
    case 166:
      HCode{8388585, 23}
    case 167:
      HCode{2097118, 21}
    case 168:
      HCode{8388586, 23}
    case 169:
      HCode{4194269, 22}
    case 170:
      HCode{4194270, 22}
    case 171:
      HCode{16777200, 24}
    case 172:
      HCode{2097119, 21}
    case 173:
      HCode{4194271, 22}
    case 174:
      HCode{8388587, 23}
    case 175:
      HCode{8388588, 23}
    case 176:
      HCode{2097120, 21}
    case 177:
      HCode{2097121, 21}
    case 178:
      HCode{4194272, 22}
    case 179:
      HCode{2097122, 21}
    case 180:
      HCode{8388589, 23}
    case 181:
      HCode{4194273, 22}
    case 182:
      HCode{8388590, 23}
    case 183:
      HCode{8388591, 23}
    case 184:
      HCode{1048554, 20}
    case 185:
      HCode{4194274, 22}
    case 186:
      HCode{4194275, 22}
    case 187:
      HCode{4194276, 22}
    case 188:
      HCode{8388592, 23}
    case 189:
      HCode{4194277, 22}
    case 190:
      HCode{4194278, 22}
    case 191:
      HCode{8388593, 23}
    case 192:
      HCode{67108832, 26}
    case 193:
      HCode{67108833, 26}
    case 194:
      HCode{1048555, 20}
    case 195:
      HCode{524273, 19}
    case 196:
      HCode{4194279, 22}
    case 197:
      HCode{8388594, 23}
    case 198:
      HCode{4194280, 22}
    case 199:
      HCode{33554412, 25}
    case 200:
      HCode{67108834, 26}
    case 201:
      HCode{67108835, 26}
    case 202:
      HCode{67108836, 26}
    case 203:
      HCode{134217694, 27}
    case 204:
      HCode{134217695, 27}
    case 205:
      HCode{67108837, 26}
    case 206:
      HCode{16777201, 24}
    case 207:
      HCode{33554413, 25}
    case 208:
      HCode{524274, 19}
    case 209:
      HCode{2097123, 21}
    case 210:
      HCode{67108838, 26}
    case 211:
      HCode{134217696, 27}
    case 212:
      HCode{134217697, 27}
    case 213:
      HCode{67108839, 26}
    case 214:
      HCode{134217698, 27}
    case 215:
      HCode{16777202, 24}
    case 216:
      HCode{2097124, 21}
    case 217:
      HCode{2097125, 21}
    case 218:
      HCode{67108840, 26}
    case 219:
      HCode{67108841, 26}
    case 220:
      HCode{268435453, 28}
    case 221:
      HCode{134217699, 27}
    case 222:
      HCode{134217700, 27}
    case 223:
      HCode{134217701, 27}
    case 224:
      HCode{1048556, 20}
    case 225:
      HCode{16777203, 24}
    case 226:
      HCode{1048557, 20}
    case 227:
      HCode{2097126, 21}
    case 228:
      HCode{4194281, 22}
    case 229:
      HCode{2097127, 21}
    case 230:
      HCode{2097128, 21}
    case 231:
      HCode{8388595, 23}
    case 232:
      HCode{4194282, 22}
    case 233:
      HCode{4194283, 22}
    case 234:
      HCode{33554414, 25}
    case 235:
      HCode{33554415, 25}
    case 236:
      HCode{16777204, 24}
    case 237:
      HCode{16777205, 24}
    case 238:
      HCode{67108842, 26}
    case 239:
      HCode{8388596, 23}
    case 240:
      HCode{67108843, 26}
    case 241:
      HCode{134217702, 27}
    case 242:
      HCode{67108844, 26}
    case 243:
      HCode{67108845, 26}
    case 244:
      HCode{134217703, 27}
    case 245:
      HCode{134217704, 27}
    case 246:
      HCode{134217705, 27}
    case 247:
      HCode{134217706, 27}
    case 248:
      HCode{134217707, 27}
    case 249:
      HCode{268435454, 28}
    case 250:
      HCode{134217708, 27}
    case 251:
      HCode{134217709, 27}
    case 252:
      HCode{134217710, 27}
    case 253:
      HCode{134217711, 27}
    case 254:
      HCode{134217712, 27}
    case 255:
      HCode{67108846, 26}
    case _:
      HCode{1073741823, 30}

# The symbols in canonical order: by code length, then by symbol.
def Hp.sym(i: U32) -> U32:
  match i:
    case 0:
      48
    case 1:
      49
    case 2:
      50
    case 3:
      97
    case 4:
      99
    case 5:
      101
    case 6:
      105
    case 7:
      111
    case 8:
      115
    case 9:
      116
    case 10:
      32
    case 11:
      37
    case 12:
      45
    case 13:
      46
    case 14:
      47
    case 15:
      51
    case 16:
      52
    case 17:
      53
    case 18:
      54
    case 19:
      55
    case 20:
      56
    case 21:
      57
    case 22:
      61
    case 23:
      65
    case 24:
      95
    case 25:
      98
    case 26:
      100
    case 27:
      102
    case 28:
      103
    case 29:
      104
    case 30:
      108
    case 31:
      109
    case 32:
      110
    case 33:
      112
    case 34:
      114
    case 35:
      117
    case 36:
      58
    case 37:
      66
    case 38:
      67
    case 39:
      68
    case 40:
      69
    case 41:
      70
    case 42:
      71
    case 43:
      72
    case 44:
      73
    case 45:
      74
    case 46:
      75
    case 47:
      76
    case 48:
      77
    case 49:
      78
    case 50:
      79
    case 51:
      80
    case 52:
      81
    case 53:
      82
    case 54:
      83
    case 55:
      84
    case 56:
      85
    case 57:
      86
    case 58:
      87
    case 59:
      89
    case 60:
      106
    case 61:
      107
    case 62:
      113
    case 63:
      118
    case 64:
      119
    case 65:
      120
    case 66:
      121
    case 67:
      122
    case 68:
      38
    case 69:
      42
    case 70:
      44
    case 71:
      59
    case 72:
      88
    case 73:
      90
    case 74:
      33
    case 75:
      34
    case 76:
      40
    case 77:
      41
    case 78:
      63
    case 79:
      39
    case 80:
      43
    case 81:
      124
    case 82:
      35
    case 83:
      62
    case 84:
      0
    case 85:
      36
    case 86:
      64
    case 87:
      91
    case 88:
      93
    case 89:
      126
    case 90:
      94
    case 91:
      125
    case 92:
      60
    case 93:
      96
    case 94:
      123
    case 95:
      92
    case 96:
      195
    case 97:
      208
    case 98:
      128
    case 99:
      130
    case 100:
      131
    case 101:
      162
    case 102:
      184
    case 103:
      194
    case 104:
      224
    case 105:
      226
    case 106:
      153
    case 107:
      161
    case 108:
      167
    case 109:
      172
    case 110:
      176
    case 111:
      177
    case 112:
      179
    case 113:
      209
    case 114:
      216
    case 115:
      217
    case 116:
      227
    case 117:
      229
    case 118:
      230
    case 119:
      129
    case 120:
      132
    case 121:
      133
    case 122:
      134
    case 123:
      136
    case 124:
      146
    case 125:
      154
    case 126:
      156
    case 127:
      160
    case 128:
      163
    case 129:
      164
    case 130:
      169
    case 131:
      170
    case 132:
      173
    case 133:
      178
    case 134:
      181
    case 135:
      185
    case 136:
      186
    case 137:
      187
    case 138:
      189
    case 139:
      190
    case 140:
      196
    case 141:
      198
    case 142:
      228
    case 143:
      232
    case 144:
      233
    case 145:
      1
    case 146:
      135
    case 147:
      137
    case 148:
      138
    case 149:
      139
    case 150:
      140
    case 151:
      141
    case 152:
      143
    case 153:
      147
    case 154:
      149
    case 155:
      150
    case 156:
      151
    case 157:
      152
    case 158:
      155
    case 159:
      157
    case 160:
      158
    case 161:
      165
    case 162:
      166
    case 163:
      168
    case 164:
      174
    case 165:
      175
    case 166:
      180
    case 167:
      182
    case 168:
      183
    case 169:
      188
    case 170:
      191
    case 171:
      197
    case 172:
      231
    case 173:
      239
    case 174:
      9
    case 175:
      142
    case 176:
      144
    case 177:
      145
    case 178:
      148
    case 179:
      159
    case 180:
      171
    case 181:
      206
    case 182:
      215
    case 183:
      225
    case 184:
      236
    case 185:
      237
    case 186:
      199
    case 187:
      207
    case 188:
      234
    case 189:
      235
    case 190:
      192
    case 191:
      193
    case 192:
      200
    case 193:
      201
    case 194:
      202
    case 195:
      205
    case 196:
      210
    case 197:
      213
    case 198:
      218
    case 199:
      219
    case 200:
      238
    case 201:
      240
    case 202:
      242
    case 203:
      243
    case 204:
      255
    case 205:
      203
    case 206:
      204
    case 207:
      211
    case 208:
      212
    case 209:
      214
    case 210:
      221
    case 211:
      222
    case 212:
      223
    case 213:
      241
    case 214:
      244
    case 215:
      245
    case 216:
      246
    case 217:
      247
    case 218:
      248
    case 219:
      250
    case 220:
      251
    case 221:
      252
    case 222:
      253
    case 223:
      254
    case 224:
      2
    case 225:
      3
    case 226:
      4
    case 227:
      5
    case 228:
      6
    case 229:
      7
    case 230:
      8
    case 231:
      11
    case 232:
      12
    case 233:
      14
    case 234:
      15
    case 235:
      16
    case 236:
      17
    case 237:
      18
    case 238:
      19
    case 239:
      20
    case 240:
      21
    case 241:
      23
    case 242:
      24
    case 243:
      25
    case 244:
      26
    case 245:
      27
    case 246:
      28
    case 247:
      29
    case 248:
      30
    case 249:
      31
    case 250:
      127
    case 251:
      220
    case 252:
      249
    case 253:
      10
    case 254:
      13
    case 255:
      22
    case _:
      256

# For each code length: its first code, how many codes have it, and the
# first's place in Hp.sym's order.
def Hp.len(l: U32) -> HLen:
  match l:
    case 5:
      HLen{0, 10, 0}
    case 6:
      HLen{20, 26, 10}
    case 7:
      HLen{92, 32, 36}
    case 8:
      HLen{248, 6, 68}
    case 10:
      HLen{1016, 5, 74}
    case 11:
      HLen{2042, 3, 79}
    case 12:
      HLen{4090, 2, 82}
    case 13:
      HLen{8184, 6, 84}
    case 14:
      HLen{16380, 2, 90}
    case 15:
      HLen{32764, 3, 92}
    case 19:
      HLen{524272, 3, 95}
    case 20:
      HLen{1048550, 8, 98}
    case 21:
      HLen{2097116, 13, 106}
    case 22:
      HLen{4194258, 26, 119}
    case 23:
      HLen{8388568, 29, 145}
    case 24:
      HLen{16777194, 12, 174}
    case 25:
      HLen{33554412, 4, 186}
    case 26:
      HLen{67108832, 15, 190}
    case 27:
      HLen{134217694, 19, 205}
    case 28:
      HLen{268435426, 29, 224}
    case 30:
      HLen{1073741820, 4, 253}
    case _:
      HLen{0, 0, 0}

# Octets
# ------

def Hp.bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      Con{U32.and(c, 255), Hp.bytes(t)}

def Hp.text(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{b, t}:
      SCon{Chr{b}, Hp.text(t)}

def Hp.slen(s: String) -> U32:
  U32.from_nat(String.length(s))

# A header's size in a table or a header list: name, value and 32.
def Hp.esize(h: H.Header) -> U32:
  match h:
    case H.Header{n, v}:
      U32.add(U32.add(Hp.slen(n), Hp.slen(v)), 32)

# Integers (5.1)
# --------------

def Hp.int.rest(fuel: Nat, +v: U32, last: Bool) -> List<&2, U32>:
  match fuel last:
    case 0n l:
      Nil{}
    case 1n+f True{}:
      [v]
    case 1n+f False{}:
      Con{U32.or(128, U32.and(v, 127)), Hp.int.rest(f, U32.shrn(v, 7n), U32.is_lt(U32.shrn(v, 7n), 128))}

def Hp.int.go(+flags: U32, +full: U32, +v: U32, small: Bool) -> List<&2, U32>:
  match small:
    case True{}:
      [U32.or(flags, v)]
    case False{}:
      Con{U32.or(flags, full), Hp.int.rest(5n, U32.sub(v, full), U32.is_lt(U32.sub(v, full), 128))}

# v with an N-bit prefix, full = 2^N - 1, after the bits in flags.
def Hp.int(+flags: U32, +full: U32, +v: U32) -> List<&2, U32>:
  Hp.int.go(flags, full, v, U32.is_lt(v, full))

# Huffman (5.2)
# -------------

type HBits is Data:
  HBits{acc: U32, n: U32, out: List<&2, U32>}

def Hp.put1.go(+acc: U32, +n: U32, out: List<&2, U32>, full: Bool) -> HBits:
  match full:
    case True{}:
      HBits{0, 0, Con{acc, out}}
    case False{}:
      HBits{acc, n, out}

def Hp.put1(st: HBits, +bit: U32) -> HBits:
  match st:
    case HBits{acc, +n, out}:
      Hp.put1.go(U32.or(U32.shl(acc), bit), U32.add(n, 1), out, U32.is_eq(n, 7))

# The low i bits of code, high first.
def Hp.push(+i: Nat, +code: U32, st: HBits) -> HBits:
  match i:
    case 0n:
      st
    case 1n+p:
      Hp.push(p, code, Hp.put1(st, U32.and(U32.shrn(code, p), 1)))

def Hp.huff.one(c: HCode, st: HBits) -> HBits:
  match c:
    case HCode{+code, len}:
      Hp.push(U32.to_nat(len), code, st)

def Hp.huff.go(bs: List<&2, U32>, st: HBits) -> HBits:
  match bs:
    case Nil{}:
      st
    case Con{b, t}:
      Hp.huff.go(t, Hp.huff.one(Hp.code(b), st))

def Hp.huff.pad(+acc: U32, +n: U32, out: List<&2, U32>, whole: Bool) -> List<&2, U32>:
  match whole:
    case True{}:
      List.reverse(&2, U32, out)
    case False{}:
      List.reverse(&2, U32, Con{U32.or(U32.shln(acc, U32.to_nat(U32.sub(8, n))),
        U32.sub(U32.shln(1, U32.to_nat(U32.sub(8, n))), 1)), out})

def Hp.huff.fin(st: HBits) -> List<&2, U32>:
  match st:
    case HBits{+acc, +n, out}:
      Hp.huff.pad(acc, n, out, U32.is_zero(n))

# Huffman-codes bytes, the last padded with the top bits of EOS (all 1s).
def Hp.huff(bs: List<&2, U32>) -> List<&2, U32>:
  Hp.huff.fin(Hp.huff.go(bs, HBits{0, 0, Nil{}}))

def Hp.code_len(c: HCode) -> U32:
  match c:
    case HCode{code, len}:
      len

def Hp.huff_bits(bs: List<&2, U32>) -> U32:
  match bs:
    case Nil{}:
      0
    case Con{b, t}:
      U32.add(Hp.code_len(Hp.code(b)), Hp.huff_bits(t))

# How many bytes Hp.huff makes of bs.
def Hp.huff_len(bs: List<&2, U32>) -> U32:
  U32.div(U32.add(Hp.huff_bits(bs), 7), 8)

type HHuf is Data:
  HHuf{code: U32, len: U32, out: String}
  HHufBad{why: String}

def Hp.unhuff.sym(+sym: U32, out: String, eos: Bool) -> HHuf:
  match eos:
    case True{}:
      HHufBad{"EOS inside a Huffman string"}
    case False{}:
      HHuf{0, 0, SCon{Chr{sym}, out}}

def Hp.unhuff.hit(+c: U32, +l: U32, out: String, +sym: U32, hit: Bool, long: Bool) -> HHuf:
  match hit long:
    case True{} x:
      Hp.unhuff.sym(sym, out, U32.is_eq(sym, 256))
    case False{} True{}:
      HHufBad{"a Huffman code longer than 30 bits"}
    case False{} False{}:
      HHuf{c, l, out}

def Hp.unhuff.at(+c: U32, +l: U32, out: String, hl: HLen) -> HHuf:
  match hl:
    case HLen{+first, +count, +offset}:
      Hp.unhuff.hit(c, l, out, Hp.sym(U32.add(offset, U32.sub(c, first))),
        U32.is_lt(U32.sub(c, first), count), U32.is_ge(l, 30))

# One bit into the canonical decoder: a code of length l is the symbol
# when it falls among that length's codes.
def Hp.unhuff.bit(st: HHuf, +bit: U32) -> HHuf:
  match st:
    case HHuf{code, +len, out}:
      Hp.unhuff.at(U32.or(U32.shl(code), bit), U32.add(len, 1), out, Hp.len(U32.add(len, 1)))
    case HHufBad{why}:
      HHufBad{why}

def Hp.unhuff.byte(st: HHuf, +b: U32) -> HHuf:
  s1 = Hp.unhuff.bit(st, U32.and(U32.shrn(b, 7n), 1))
  s2 = Hp.unhuff.bit(s1, U32.and(U32.shrn(b, 6n), 1))
  s3 = Hp.unhuff.bit(s2, U32.and(U32.shrn(b, 5n), 1))
  s4 = Hp.unhuff.bit(s3, U32.and(U32.shrn(b, 4n), 1))
  s5 = Hp.unhuff.bit(s4, U32.and(U32.shrn(b, 3n), 1))
  s6 = Hp.unhuff.bit(s5, U32.and(U32.shrn(b, 2n), 1))
  s7 = Hp.unhuff.bit(s6, U32.and(U32.shr(b), 1))
  Hp.unhuff.bit(s7, U32.and(b, 1))

def Hp.unhuff.go(bs: List<&2, U32>, st: HHuf) -> HHuf:
  match bs:
    case Nil{}:
      st
    case Con{+b, t}:
      Hp.unhuff.go(t, Hp.unhuff.byte(st, b))

def Hp.unhuff.end(out: String, ok: Bool) -> Result<&2, &2, String, String>:
  match ok:
    case True{}:
      Done{String.reverse(out)}
    case False{}:
      Fail{"bad Huffman padding"}

def Hp.unhuff.fin(st: HHuf) -> Result<&2, &2, String, String>:
  match st:
    case HHuf{+code, +len, out}:
      Hp.unhuff.end(out, U32.is_le(len, 7) && U32.is_eq(code, U32.sub(U32.shln(1, U32.to_nat(len)), 1)))
    case HHufBad{why}:
      Fail{why}

# Decodes a Huffman string: padding must be under 8 bits, all 1s.
def Hp.unhuff(bs: List<&2, U32>) -> Result<&2, &2, String, String>:
  Hp.unhuff.fin(Hp.unhuff.go(bs, HHuf{0, 0, SNil{}}))

# Strings (5.2)
# -------------

def Hp.str.go(raw: List<&2, U32>, huff: Bool) -> List<&2, U32>:
  match huff:
    case True{}:
      +h = Hp.huff(raw)
      List.append(&2, U32, Hp.int(128, 127, U32.from_nat(List.length(&2, U32, h))), h)
    case False{}:
      +r = raw
      List.append(&2, U32, Hp.int(0, 127, U32.from_nat(List.length(&2, U32, r))), r)

# A string literal: Huffman-coded when huff is on and that is no longer
# (RFC 7541 C.6 Huffman-codes "307", 3 bytes either way).
def Hp.str(huff: Bool, s: String) -> List<&2, U32>:
  +raw = Hp.bytes(s)
  Hp.str.go(raw, huff && U32.is_le(Hp.huff_len(raw), U32.from_nat(List.length(&2, U32, raw))))

# Tables (2.3, 4)
# ---------------

type HTab is Data:
  HTab{table: List<&2, H.Header>, size: U32}

def Hp.trim.go(+h: H.Header, rest: List<&2, H.Header>, fits: Bool) -> List<&2, H.Header>:
  match fits:
    case True{}:
      Con{h, rest}
    case False{}:
      Nil{}

# The newest entries that fit in budget: eviction drops the oldest.
def Hp.trim(t: List<&2, H.Header>, +budget: U32) -> List<&2, H.Header>:
  match t:
    case Nil{}:
      Nil{}
    case Con{+h, rest}:
      Hp.trim.go(h, Hp.trim(rest, U32.sub(budget, Hp.esize(h))), U32.is_le(Hp.esize(h), budget))

def Hp.tsize(t: List<&2, H.Header>) -> U32:
  match t:
    case Nil{}:
      0
    case Con{h, rest}:
      U32.add(Hp.esize(h), Hp.tsize(rest))

def Hp.tab(t: List<&2, H.Header>) -> HTab:
  +t = t
  HTab{t, Hp.tsize(t)}

# Adds h, evicting to fit max; an entry larger than max empties the table.
def Hp.add(t: List<&2, H.Header>, h: H.Header, +max: U32) -> HTab:
  Hp.tab(Hp.trim(Con{h, t}, max))

# The entry at index i: the static table's 1 to 61, then the dynamic
# table's, newest first.
def Hp.at.go(t: List<&2, H.Header>, +i: U32, dynamic: Bool) -> Maybe<&2, H.Header>:
  match dynamic:
    case True{}:
      List.get(&2, H.Header, t, U32.to_nat(U32.sub(i, 62)))
    case False{}:
      List.get(&2, H.Header, Hp.statics(), U32.to_nat(U32.sub(i, 1)))

def Hp.at(t: List<&2, H.Header>, +i: U32) -> Maybe<&2, H.Header>:
  Hp.at.go(t, i, U32.is_ge(i, 62))

def Hp.same(+n: String, +v: String, +name: String, +value: String, exact: Bool) -> Bool:
  match exact:
    case True{}:
      String.eq(n, name) && String.eq(v, value)
    case False{}:
      String.eq(n, name)

def Hp.find.go(+i: U32, rest: U32, hit: Bool) -> U32:
  match hit:
    case True{}:
      i
    case False{}:
      rest

# The index of the first entry of xs, numbered from i, that matches the
# header (exact) or its name; 0 when none does.
def Hp.find(xs: List<&2, H.Header>, +name: String, +value: String, +i: U32, +exact: Bool) -> U32:
  match xs:
    case Nil{}:
      0
    case Con{H.Header{+n, +v}, t}:
      Hp.find.go(i, Hp.find(t, name, value, U32.add(i, 1), exact), Hp.same(n, v, name, value, exact))

def Hp.either.go(+a: U32, +b: U32, none: Bool) -> U32:
  match none:
    case True{}:
      b
    case False{}:
      a

def Hp.either(+a: U32, +b: U32) -> U32:
  Hp.either.go(a, b, U32.is_zero(a))

def Hp.lookup(t: List<&2, H.Header>, +name: String, +value: String, +exact: Bool) -> U32:
  Hp.either(Hp.find(Hp.statics(), name, value, 1, exact), Hp.find(t, name, value, 62, exact))

# Decoding (6)
# ------------

# What an integer is for, once whole.
#   KIdx: an indexed header field
#   KName: a literal's name index (0: the name follows); ix adds the
#          header to the table
#   KSize: a dynamic table size update
#   KLen: a string's length; name is None for the name string, else the
#         name the value goes with
type HK is Data:
  KIdx{}
  KName{ix: Bool}
  KSize{}
  KLen{ix: Bool, name: Maybe<&2, String>, huff: Bool}

# Where the decoder is.
#   HOp: before a field's first byte
#   HInt: inside an integer, acc so far, m the next 7 bits' shift
#   HLit: before a string's first byte (its H bit and length)
#   HStr: left bytes of a string to go, acc reversed
#   HBad: a block the decoder refuses; it stays here
type HSt is Data:
  HOp{}
  HInt{k: HK, acc: U32, m: U32}
  HLit{ix: Bool, name: Maybe<&2, String>}
  HStr{ix: Bool, name: Maybe<&2, String>, huff: Bool, left: U32, acc: List<&2, U32>}
  HBad{why: String}

# A decoder: the dynamic table and its size and maximum; limit, the most
# the encoder may raise the maximum to (our SETTINGS_HEADER_TABLE_SIZE);
# cap, the header list's limit; and the block so far: its list size, its
# headers reversed, and whether a header has come.
type HDec is Data:
  HDec{table: List<&2, H.Header>, size: U32, max: U32, limit: U32, cap: U32, used: U32, st: HSt,
    out: List<&2, H.Header>, began: Bool}

type HBlock is Data:
  HBlock{dec: HDec, headers: List<&2, H.Header>}

# A decoder whose table holds up to limit bytes, refusing a header list
# past cap.
def Hp.dec_new(+limit: U32, +cap: U32) -> HDec:
  HDec{Nil{}, 0, limit, limit, cap, 0, HOp{}, Nil{}, False{}}

def Hp.set(d: HDec, st: HSt) -> HDec:
  match d:
    case HDec{table, size, max, limit, cap, used, old, out, began}:
      HDec{table, size, max, limit, cap, used, st, out, began}

def Hp.bad(d: HDec, why: String) -> HDec:
  Hp.set(d, HBad{why})

def Hp.with_tab(t: HTab, d: HDec) -> HDec:
  match t d:
    case HTab{t2, s2} HDec{table, size, max, limit, cap, used, st, out, began}:
      HDec{t2, s2, max, limit, cap, used, st, out, began}

def Hp.emit.go(d: HDec, +h: H.Header, ix: Bool, +used: U32, over: Bool) -> HDec:
  match d ix over:
    case HDec{table, size, max, limit, cap, u, st, out, began} i True{}:
      HDec{table, size, max, limit, cap, used, HBad{"the header list is larger than its limit"}, out, began}
    case HDec{table, size, +max, limit, cap, u, st, out, began} True{} False{}:
      Hp.with_tab(Hp.add(table, h, max), HDec{Nil{}, 0, max, limit, cap, used, st, Con{h, out}, True{}})
    case HDec{table, size, max, limit, cap, u, st, out, began} False{} False{}:
      HDec{table, size, max, limit, cap, used, st, Con{h, out}, True{}}

# A header is whole: into the list, and into the table if ix.
def Hp.emit(d: HDec, +h: H.Header, ix: Bool) -> HDec:
  match d:
    case HDec{table, size, max, limit, +cap, +used, st, out, began}:
      Hp.emit.go(HDec{table, size, max, limit, cap, used, st, out, began}, h, ix,
        U32.add(used, Hp.esize(h)), U32.is_gt(U32.add(used, Hp.esize(h)), cap))

def Hp.indexed(d: HDec, m: Maybe<&2, H.Header>, +i: U32) -> HDec:
  match m:
    case None{}:
      Hp.bad(d, "no table entry at index " ++ U32.show(i))
    case Some{h}:
      Hp.emit(d, h, False{})

def Hp.named(d: HDec, ix: Bool, lit: Bool, m: Maybe<&2, H.Header>, +i: U32) -> HDec:
  match lit m:
    case True{} x:
      Hp.set(d, HLit{ix, None{}})
    case False{} None{}:
      Hp.bad(d, "no table entry at index " ++ U32.show(i))
    case False{} Some{H.Header{n, v}}:
      Hp.set(d, HLit{ix, Some{n}})

def Hp.resize.go(began: Bool, over: Bool, d: HDec, +v: U32) -> HDec:
  match began over:
    case True{} o:
      Hp.bad(d, "a table size update after a header")
    case False{} True{}:
      Hp.bad(d, "a table size update past the limit")
    case False{} False{}:
      match d:
        case HDec{table, size, max, limit, cap, used, st, out, began2}:
          Hp.with_tab(Hp.tab(Hp.trim(table, v)), HDec{Nil{}, 0, v, limit, cap, used, st, out, began2})

def Hp.resize(d: HDec, +v: U32) -> HDec:
  match d:
    case HDec{table, size, max, +limit, cap, used, st, out, +began}:
      Hp.resize.go(began, U32.is_gt(v, limit), HDec{table, size, max, limit, cap, used, st, out, began}, v)

def Hp.got(d: HDec, ix: Bool, name: Maybe<&2, String>, r: Result<&2, &2, String, String>) -> HDec:
  match name r:
    case n Fail{e}:
      Hp.bad(d, e)
    case None{} Done{s}:
      Hp.set(d, HLit{ix, Some{s}})
    case Some{n} Done{s}:
      Hp.emit(d, H.Header{n, s}, ix)

# A string is whole: the name, or the value that finishes a header.
def Hp.string(d: HDec, ix: Bool, name: Maybe<&2, String>, huff: Bool, bs: List<&2, U32>) -> HDec:
  match huff:
    case True{}:
      Hp.got(d, ix, name, Hp.unhuff(bs))
    case False{}:
      Hp.got(d, ix, name, Done{Hp.text(bs)})

def Hp.strlen(+d: HDec, ix: Bool, name: Maybe<&2, String>, huff: Bool, +v: U32, empty: Bool, long: Bool) -> HDec:
  match empty long:
    case True{} l:
      Hp.string(d, ix, name, huff, Nil{})
    case False{} True{}:
      Hp.bad(d, "a string of " ++ U32.show(v) ++ " bytes is longer than the header list's limit")
    case False{} False{}:
      Hp.set(d, HStr{ix, name, huff, v, Nil{}})

def Hp.cap(d: HDec) -> U32:
  match d:
    case HDec{table, size, max, limit, cap, used, st, out, began}:
      cap

def Hp.table(d: HDec) -> List<&2, H.Header>:
  match d:
    case HDec{table, size, max, limit, cap, used, st, out, began}:
      table

# An integer is whole.
def Hp.done(+d: HDec, k: HK, +v: U32) -> HDec:
  match k:
    case KIdx{}:
      Hp.indexed(d, Hp.at(Hp.table(d), v), v)
    case KName{ix}:
      Hp.named(d, ix, U32.is_zero(v), Hp.at(Hp.table(d), v), v)
    case KSize{}:
      Hp.resize(d, v)
    case KLen{ix, name, huff}:
      Hp.strlen(d, ix, name, huff, v, U32.is_zero(v), U32.is_gt(v, Hp.cap(d)))

def Hp.int1(d: HDec, k: HK, +v: U32, more: Bool) -> HDec:
  match more:
    case True{}:
      Hp.set(d, HInt{k, v, 0})
    case False{}:
      Hp.done(d, k, v)

def Hp.cont(d: HDec, k: HK, +acc: U32, +m: U32, big: Bool, last: Bool) -> HDec:
  match big last:
    case True{} l:
      Hp.bad(d, "an integer past 2^28")
    case False{} True{}:
      Hp.done(d, k, acc)
    case False{} False{}:
      Hp.set(d, HInt{k, acc, U32.add(m, 7)})

def Hp.op(d: HDec, +b: U32, a: Bool, c: Bool, e: Bool) -> HDec:
  match a c e:
    case True{} x y:
      Hp.int1(d, KIdx{}, U32.and(b, 127), U32.is_eq(U32.and(b, 127), 127))
    case False{} True{} y:
      Hp.int1(d, KName{True{}}, U32.and(b, 63), U32.is_eq(U32.and(b, 63), 63))
    case False{} False{} True{}:
      Hp.int1(d, KSize{}, U32.and(b, 31), U32.is_eq(U32.and(b, 31), 31))
    case False{} False{} False{}:
      Hp.int1(d, KName{False{}}, U32.and(b, 15), U32.is_eq(U32.and(b, 15), 15))

def Hp.chars(d: HDec, ix: Bool, name: Maybe<&2, String>, huff: Bool, +left: U32, acc: List<&2, U32>, last: Bool) -> HDec:
  match last:
    case True{}:
      Hp.string(d, ix, name, huff, List.reverse(&2, U32, acc))
    case False{}:
      Hp.set(d, HStr{ix, name, huff, U32.sub(left, 1), acc})

def Hp.step.st(st: HSt, +b: U32, d: HDec) -> HDec:
  match st:
    case HOp{}:
      Hp.op(d, b, U32.is_ge(b, 128), U32.is_ge(b, 64), U32.is_ge(b, 32))
    case HInt{k, +acc, +m}:
      Hp.cont(d, k, U32.add(acc, U32.shln(U32.and(b, 127), U32.to_nat(m))), m, U32.is_ge(m, 28),
        U32.is_lt(b, 128))
    case HLit{ix, name}:
      Hp.int1(d, KLen{ix, name, U32.is_ge(b, 128)}, U32.and(b, 127), U32.is_eq(U32.and(b, 127), 127))
    case HStr{ix, name, huff, +left, acc}:
      Hp.chars(d, ix, name, huff, left, Con{b, acc}, U32.is_eq(left, 1))
    case HBad{why}:
      Hp.set(d, HBad{why})

# One byte into the decoder.
def Hp.step(d: HDec, +b: U32) -> HDec:
  match d:
    case HDec{table, size, max, limit, cap, used, st, out, began}:
      Hp.step.st(st, b, HDec{table, size, max, limit, cap, used, HOp{}, out, began})

def Hp.feed(bs: List<&2, U32>, d: HDec) -> HDec:
  match bs:
    case Nil{}:
      d
    case Con{+b, t}:
      Hp.feed(t, Hp.step(d, b))

def Hp.decode.fin(d: HDec) -> Result<&2, &2, String, HBlock>:
  match d:
    case HDec{table, size, max, limit, cap, used, HOp{}, out, began}:
      Done{HBlock{HDec{table, size, max, limit, cap, 0, HOp{}, Nil{}, False{}}, List.reverse(&2, H.Header, out)}}
    case HDec{table, size, max, limit, cap, used, HBad{why}, out, began}:
      Fail{why}
    case _:
      Fail{"the header block ends inside a field"}

# Decodes a whole header block (HEADERS and its CONTINUATIONs, joined):
# the decoder for the next block, and the headers in order.
def Hp.decode(d: HDec, bs: List<&2, U32>) -> Result<&2, &2, String, HBlock>:
  Hp.decode.fin(Hp.feed(bs, d))

# Encoding (6)
# ------------

# An encoder: its table, the table's size and maximum, the smallest
# maximum since the last block if the peer changed it, and whether to
# Huffman-code strings.
type HEnc is Data:
  HEnc{table: List<&2, H.Header>, size: U32, max: U32, low: Maybe<&2, U32>, huff: Bool}

type HEBlock is Data:
  HEBlock{enc: HEnc, bytes: List<&2, U32>}

def Hp.enc_new(+max: U32, huff: Bool) -> HEnc:
  HEnc{Nil{}, 0, max, None{}, huff}

def Hp.enc_low(m: Maybe<&2, U32>, +n: U32) -> U32:
  match m:
    case None{}:
      n
    case Some{l}:
      U32.min(l, n)

# The peer's SETTINGS_HEADER_TABLE_SIZE is now n: the table shrinks to it
# at once, and the next block says so.
def Hp.enc_tab(t: HTab, +max: U32, low: Maybe<&2, U32>, huff: Bool) -> HEnc:
  match t:
    case HTab{t2, s2}:
      HEnc{t2, s2, max, low, huff}

def Hp.enc_resize(e: HEnc, +n: U32) -> HEnc:
  match e:
    case HEnc{table, size, max, low, huff}:
      Hp.enc_tab(Hp.tab(Hp.trim(table, n)), n, Some{Hp.enc_low(low, n)}, huff)

def Hp.enc_lit(+huff: Bool, +name: String, +value: String, +ni: U32, lit: Bool) -> List<&2, U32>:
  match lit:
    case True{}:
      List.concat(&2, U32, [[64], Hp.str(huff, name), Hp.str(huff, value)])
    case False{}:
      List.append(&2, U32, Hp.int(64, 63, ni), Hp.str(huff, value))

def Hp.enc_table(e: HEnc) -> List<&2, H.Header>:
  match e:
    case HEnc{table, size, max, low, huff}:
      table

def Hp.enc_one.go(e: HEnc, h: H.Header, out: List<&2, U32>, +x: U32, found: Bool) -> HEBlock:
  match e h found:
    case HEnc{table, size, max, low, huff} h2 True{}:
      HEBlock{HEnc{table, size, max, low, huff}, List.append(&2, U32, out, Hp.int(128, 127, x))}
    case HEnc{+table, size, +max, low, +huff} H.Header{+n, +v} False{}:
      HEBlock{Hp.enc_tab(Hp.add(table, H.Header{n, v}, max), max, low, huff),
        List.append(&2, U32, out, Hp.enc_lit(huff, n, v, Hp.lookup(table, n, v, False{}),
          U32.is_zero(Hp.lookup(table, n, v, False{}))))}

def Hp.enc_one(+e: HEnc, +h: H.Header, out: List<&2, U32>) -> HEBlock:
  match h:
    case H.Header{+n, +v}:
      Hp.enc_one.go(e, h, out, Hp.lookup(Hp.enc_table(e), n, v, True{}),
        Bool.not(U32.is_zero(Hp.lookup(Hp.enc_table(e), n, v, True{}))))

def Hp.encode.go(hs: List<&2, H.Header>, ev: HEBlock) -> HEBlock:
  match hs ev:
    case Nil{} b:
      b
    case Con{h, t} HEBlock{e, out}:
      Hp.encode.go(t, Hp.enc_one(e, h, out))

def Hp.encode.sizes(+l: U32, +max: U32, same: Bool) -> List<&2, U32>:
  match same:
    case True{}:
      Hp.int(32, 31, max)
    case False{}:
      List.append(&2, U32, Hp.int(32, 31, l), Hp.int(32, 31, max))

def Hp.encode.start(e: HEnc) -> HEBlock:
  match e:
    case HEnc{table, size, +max, low, huff}:
      match low:
        case None{}:
          HEBlock{HEnc{table, size, max, None{}, huff}, Nil{}}
        case Some{+l}:
          HEBlock{HEnc{table, size, max, None{}, huff}, Hp.encode.sizes(l, max, U32.is_eq(l, max))}

# Encodes a header block: the encoder for the next block, and the bytes.
def Hp.encode(e: HEnc, hs: List<&2, H.Header>) -> HEBlock:
  Hp.encode.go(hs, Hp.encode.start(e))

# Sequences, for tests and laws
# -----------------------------

type HSeq is Data:
  HSeq{blocks: List<&2, List<&2, H.Header>>, table: List<&2, H.Header>, size: U32}

def Hp.decode_seq.go(bss: List<&2, List<&2, U32>>, r: Result<&2, &2, String, HBlock>, acc: List<&2, List<&2, H.Header>>) ->
  Result<&2, &2, String, HSeq>:
  match bss r:
    case b Fail{e}:
      Fail{e}
    case Nil{} Done{HBlock{HDec{table, size, max, limit, cap, used, st, out, began}, hs}}:
      Done{HSeq{List.reverse(&2, List<&2, H.Header>, Con{hs, acc}), table, size}}
    case Con{bs, t} Done{HBlock{d, hs}}:
      Hp.decode_seq.go(t, Hp.decode(d, bs), Con{hs, acc})

# Decodes blocks one after another, as one connection's would be.
# (The first result is an empty block, dropped.)
def Hp.decode_seq.drop(r: Result<&2, &2, String, HSeq>) -> Result<&2, &2, String, HSeq>:
  match r:
    case Done{HSeq{Con{x, bs}, t, s}}:
      Done{HSeq{bs, t, s}}
    case _:
      r

def Hp.decode_seq(d: HDec, bss: List<&2, List<&2, U32>>) -> Result<&2, &2, String, HSeq>:
  Hp.decode_seq.drop(Hp.decode_seq.go(bss, Done{HBlock{d, Nil{}}}, Nil{}))

def Hp.encode_seq.go(hss: List<&2, List<&2, H.Header>>, b: HEBlock, acc: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match hss b:
    case Nil{} HEBlock{e, bs}:
      List.reverse(&2, List<&2, U32>, Con{bs, acc})
    case Con{hs, t} HEBlock{e, bs}:
      Hp.encode_seq.go(t, Hp.encode(e, hs), Con{bs, acc})

def Hp.encode_seq(e: HEnc, hss: List<&2, List<&2, H.Header>>) -> List<&2, List<&2, U32>>:
  List.tail(&2, List<&2, U32>, Hp.encode_seq.go(hss, HEBlock{e, Nil{}}, Nil{}))
