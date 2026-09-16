"""Read-only KenshiLib export/RVA disassembly for the installed loading path."""
import argparse
import hashlib
import struct
from pathlib import Path

import capstone
import pefile


class Engine:
    def __init__(self, game):
        self.game = Path(game)
        self.lib = pefile.PE(str(self.game / 'KenshiLib.dll'), max_symbol_exports=20000)
        self.path = self.game / 'RE_Kenshi/kenshi_x64.exe'
        self.pe = pefile.PE(str(self.path), fast_load=True)
        self.symbols = {s.name.decode(): s.address for s in self.lib.DIRECTORY_ENTRY_EXPORT.symbols if s.name}
        slots = [self.slot(a) for a in self.symbols.values() if self.lib.get_data(a, 2) == b'\xff\x25']
        self.slot_base = min(slots)
        self.rvas = (self.game / 'RE_Kenshi/RVAs/Steam_1.0.65.br').read_bytes()
        self.dis = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        self.dis.detail = True
        self.names = {}
        for name, address in self.symbols.items():
            if self.lib.get_data(address, 2) == b'\xff\x25':
                self.names.setdefault(self.mapped(name), []).append(name)

    def slot(self, address):
        return address + 6 + struct.unpack('<i', self.lib.get_data(address + 2, 4))[0]

    def mapped(self, name):
        return struct.unpack_from('<I', self.rvas, (self.slot(self.symbols[name]) - self.slot_base) // 8 * 4)[0]

    def address(self, part):
        found = [n for n in self.symbols if part in n and not n.startswith('??')]
        if len(found) != 1:
            raise ValueError((part, found))
        return self.mapped(found[0])

    def code(self, address, size):
        return list(self.dis.disasm(self.pe.get_data(address, size), address))

    def follow(self, address):
        for _ in range(16):
            if self.pe.get_data(address, 1) != b'\xe9':
                return address
            address += 5 + struct.unpack('<i', self.pe.get_data(address + 1, 4))[0]
        raise ValueError('Jump chain too long')

    def dump(self, part, size):
        address = int(part, 16) if part.startswith('0x') else self.address(part)
        print('\n', part, hex(address))
        for ins in self.code(address, size):
            note = ''
            if ins.mnemonic in ('call', 'jmp') and ins.operands[0].type == capstone.x86.X86_OP_IMM:
                note = ' | ' + ', '.join(self.names.get(self.follow(ins.operands[0].imm), []))
            if ins.mnemonic in ('movss', 'comiss', 'mulss', 'divss'):
                for op in ins.operands:
                    if op.type == capstone.x86.X86_OP_MEM and op.mem.base == capstone.x86.X86_REG_RIP:
                        note += ' float=' + str(struct.unpack('<f', self.pe.get_data(ins.address + ins.size + op.mem.disp, 4))[0])
            print(f'{ins.address:08x} {ins.mnemonic:9} {ins.op_str}{note}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('symbols', nargs='+')
    parser.add_argument('--game', default=r'E:\SteamLibrary\steamapps\common\Kenshi')
    parser.add_argument('--size', type=lambda s: int(s, 0), default=0x180)
    args = parser.parse_args()
    engine = Engine(args.game)
    print('Engine SHA256:', hashlib.sha256(engine.path.read_bytes()).hexdigest())
    for symbol in args.symbols:
        engine.dump(symbol, args.size)
