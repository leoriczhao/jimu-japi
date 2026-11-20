"""Fixed terrain, navigation and Classic object data for Rift Walker."""
from struct import pack

NAME = 'Rift Walker'
AUTHOR = 'Rift Walker project'
TILES_X, TILES_Y = 96, 64
MIN_X, MIN_Y = -6144, -4096
ROOM_CENTERS = (-2200, 0, 2200)
MAP_MARGIN_X, MAP_MARGIN_Y = 14, 12
MINIMAP_SIZE = 256


def z(text: str) -> bytes:
    return text.encode('utf-8') + b'\0'


def within(x, y, left, bottom, right, top):
    return left <= x <= right and bottom <= y <= top


def walkable(x, y):
    """Explicit plot: three courts, two broad thresholds and fixed obstacles."""
    if within(x, y, -1450, -224, -750, 224) or within(x, y, 750, -224, 1450, 224):
        return True
    obstacles = (
        (-2470, 270, -2260, 460), (-1980, -440, -1780, -270),
        (-160, -192, 160, 192),
    )
    if any(within(x, y, *box) for box in obstacles):
        return False
    return any(within(x, y, center - 900, -800, center + 900, 800) for center in ROOM_CENTERS)


def tile_index(x, y):
    for center in ROOM_CENTERS:
        if abs(x - center) <= 170 and abs(y) <= 780 or abs(y) < 96 and abs(x - center) < 820:
            return 5   # light central axis
    if abs(y) <= 224 and (-1450 <= x <= -750 or 750 <= x <= 1450):
        return 5
    if x < -1300:
        return 1 if abs(y) > 480 else 0
    if x < 1300:
        return 3 if abs(x) <= 160 and abs(y) <= 192 else 2
    dx = x - 2200
    radius = (dx * dx + y * y) ** 0.5
    if 500 <= radius <= 660:
        return 5
    return 1 if radius <= 320 else 2


def terrain() -> bytes:
    ground = b'LdrtLdroLdrgLrokLgrsLgrd'
    cliffs = b'CLdiCLgr'
    header = pack('<4siBii', b'W3E!', 11, ord('L'), 1, len(ground) // 4)
    header += ground + pack('<i', len(cliffs) // 4) + cliffs
    header += pack('<iiff', TILES_X + 1, TILES_Y + 1, MIN_X, MIN_Y)
    tiles = bytearray()
    for iy in range(TILES_Y + 1):
        y = MIN_Y + iy * 128
        for ix in range(TILES_X + 1):
            x = MIN_X + ix * 128
            open_floor = walkable(x, y)
            height = 8192 if open_floor else 8336
            texture = tile_index(x, y) if open_floor else 3
            variation = ((ix * 7 + iy * 11) % 8) * 4
            tiles.extend(pack('<HHBBB', height, 8192, texture, variation, 0xF2))
    return header + tiles


def pathing() -> bytes:
    width, height = TILES_X * 4, TILES_Y * 4
    pixels = bytes(
        0x08 if walkable(MIN_X + x * 32 + 16, MIN_Y + y * 32 + 16) else 0x0E
        for y in range(height) for x in range(width)
    )
    return pack('<4siii', b'MP3W', 0, width, height) + pixels


def minimap() -> bytes:
    """Draw the W3I playable area as a Classic paletted BLP1 texture."""
    colors = [
        (29, 24, 43), (72, 54, 78), (110, 105, 145), (91, 88, 146),
        (120, 96, 148), (199, 173, 128),
    ]
    size = MINIMAP_SIZE
    left, bottom = MIN_X + MAP_MARGIN_X * 128, MIN_Y + MAP_MARGIN_Y * 128
    width, height = -2 * left, -2 * bottom
    pixels = bytearray()
    for py in range(size):
        y = -bottom - (py + 0.5) * height / size
        for px in range(size):
            x = left + (px + 0.5) * width / size
            if not walkable(x, y):
                edge = any(walkable(x + dx, y + dy) for dx, dy in ((42, 0), (-42, 0), (0, 42), (0, -42)))
                pixels.append(int(edge))
            elif (-1300 < x < -900 or 900 < x < 1300) and abs(y) < 224:
                pixels.append(5)
            elif x < -1300:
                pixels.append(2)
            elif x > 1300:
                pixels.append(4)
            else:
                pixels.append(3)
    palette = b''.join(pack('<4B', b, g, r, 0) for r, g, b in colors)
    palette = palette.ljust(256 * 4, b'\0')
    header = pack('<4s6I', b'BLP1', 1, 0, size, size, 5, 0)
    header += pack('<32I', 156 + len(palette), *([0] * 15), len(pixels), *([0] * 15))
    return header + palette + pixels


def map_info() -> bytes:
    data = pack('<iii', 25, 1, 6059)
    data += b''.join(map(z, (NAME, AUTHOR, 'Fight through the observatory and silence the seam.', '1 player')))
    data += pack('<8f', -3800, -1850, 3800, 1850, -3800, 1850, 3800, -1850)
    data += pack('<7ic', MAP_MARGIN_X, MAP_MARGIN_X, MAP_MARGIN_Y, MAP_MARGIN_Y,
                 TILES_X - 2 * MAP_MARGIN_X, TILES_Y - 2 * MAP_MARGIN_Y, 0x42, b'L')
    data += pack('<i', -1) + z('') + z('Three anchors. One blade.') + z(NAME) + z('The Observatory')
    data += pack('<i', 0) + z('') * 4
    data += pack('<ifff4B4sc', 0, 0.0, 0.0, 0.0, 76, 65, 96, 255, bytes(4), b'\0')
    data += b'L' + bytes((255, 255, 255, 255))
    data += pack('<5i', 1, 0, 1, 1, 1) + z('Rift Walker')
    data += pack('<ffII', -2950, 0, 0, 0)
    data += pack('<iii', 1, 0, 1) + z('The Walker')
    return data + pack('<4i', 0, 0, 0, 0)


def object_file(records, extended=False) -> bytes:
    data = bytearray(pack('<iii', 2, 0, len(records)))
    for parent, rawcode, fields in records:
        data.extend(pack('<4s4si', parent.encode('ascii'), rawcode.encode('ascii'), len(fields)))
        for name, value in sorted(fields.items()):
            level, column = 0, 0
            if isinstance(value, tuple):
                level, column, value = value
            field_type = {int: 0, float: 2, str: 3}[type(value)]
            if name == 'usca':
                field_type = 1  # real, not unreal in UnitMetaData
            data.extend(pack('<4si', name.encode('ascii'), field_type))
            if extended:
                data.extend(pack('<ii', level, column))
            if field_type == 3:
                data.extend(z(value))
            elif field_type in (1, 2):
                data.extend(pack('<f', value))
            else:
                data.extend(pack('<i', value))
            data.extend(bytes(4))
    return bytes(data)


def unit(name, health, speed, damage, period, reach, *, ranged=False, scale=1.0):
    fields = {
        'unam': name, 'uhpm': health, 'uhpr': 0.0, 'umvs': speed,
        'umpm': 0, 'umpi': 0, 'umpr': 0.0, 'ucol': 24.0,
        'udef': 0, 'udup': 0, 'udty': 'normal', 'uabi': '', 'uhab': '',
        'usca': scale, 'uaen': int(damage > 0), 'ua1b': damage - 1 if damage else 0,
        'ua1d': 1, 'ua1s': 1, 'ua1c': period, 'ua1r': reach, 'udp1': 0.30,
        'ubs1': 0.40, 'ua1t': 'normal', 'ua1w': 'missile' if ranged else 'normal',
        'ua1g': 'ground,enemy', 'ua1f': 0, 'ua1h': 0, 'ua1q': 0,
        'uacq': float(reach), 'ubba': 0, 'ubdi': 0, 'ubsi': 0,
    }
    if not ranged:
        fields.update(ua1m='', ua1z=0)
    return fields


def units() -> bytes:
    hero = unit('Eli the Versebreaker', 900, 310, 42, 0.85, 125)
    hero.update(ustr=0, uagi=0, uint=0, ustp=0.0, uagp=0.0, uinp=0.0,
                upro='Eli', uabi='ArwQ,ArwW,ArwE', uacq=420.0)
    return object_file([
        ('Obla', 'Hrw0', hero),
        ('hfoo', 'urw1', unit('Scar Attendant', 250, 270, 18, 1.2, 100)),
        ('earc', 'urw2', unit('Needle Archer', 210, 235, 16, 1.6, 550, ranged=True)),
        ('uabo', 'urw3', unit('Anchor Guard', 650, 215, 32, 1.8, 125, scale=0.87)),
        ('hmpr', 'urw4', unit('Seam Mender', 340, 225, 0, 1.6, 0)),
        ('ogru', 'urw5', unit('Seam Warden', 7200, 220, 36, 1.6, 150, scale=1.75)),
    ])


def channel(name, hotkey, position, target_type, order, text, icon):
    return {
        'anam': name, 'ahky': hotkey, 'aart': 'ReplaceableTextures\\CommandButtons\\BTN' + icon + '.blp',
        'abpx': position, 'abpy': 2, 'aher': 0, 'aite': 0, 'alev': 1, 'achd': 0,
        'aani': 'spell', 'acat': '', 'aeat': '', 'atat': '', 'asat': '', 'aord': order,
        'atp1': (1, 0, name + ' (|cffffcc00' + hotkey + '|r)'), 'aub1': (1, 0, text),
        'acdn': (1, 0, 0.0), 'amcs': (1, 0, 0), 'acas': (1, 0, 0.0),
        'aare': (1, 0, 0.0), 'adur': (1, 0, 0.0), 'ahdu': (1, 0, 0.0),
        'atar': (1, 0, ''), 'abuf': (1, 0, ''), 'aeff': (1, 0, ''),
        'aran': (1, 0, 9999.0),
        'Ncl1': (1, 1, 0.0), 'Ncl2': (1, 2, target_type), 'Ncl3': (1, 3, 1),
        'Ncl4': (1, 4, 0.0), 'Ncl5': (1, 5, 0), 'Ncl6': (1, 6, order),
    }


def abilities() -> bytes:
    return object_file([
        ('ANcl', 'ArwQ', channel('Rift Slash', 'Q', 0, 2, 'carrionswarm',
                                'Target a direction. Strike a line after 0.25 seconds and apply two Scars.', 'CarrionSwarm')),
        ('ANcl', 'ArwW', channel('Slipstep', 'W', 1, 2, 'blink',
                                'Target a direction. Blink up to 360 along a clear path. Grants no invulnerability.', 'Blink')),
        ('ANcl', 'ArwE', channel('Convergence', 'E', 2, 0, 'thunderclap',
                                'Consume nearby Scars after a short windup. Each target echoes damage once.', 'ThunderClap')),
    ], extended=True)


def make_members() -> dict[str, bytes]:
    return {
        'war3map.w3i': map_info(),
        'war3map.w3e': terrain(),
        'war3map.wpm': pathing(),
        'war3mapMap.blp': minimap(),
        'war3map.shd': bytes(TILES_X * TILES_Y * 16),
        'war3map.doo': pack('<4s5i', b'W3do', 8, 11, 0, 0, 0),
        'war3mapUnits.doo': pack('<4s3i', b'W3do', 8, 11, 0),
        'war3map.w3u': units(),
        'war3map.w3a': abilities(),
    }
