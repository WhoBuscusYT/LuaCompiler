"""Windows UI/Vulkan standalone integration. Python is a development tool only.

Usage: python tests/desktop.py ROOT NEW_SCRATCH [--lua PATH]
Runs real Vulkan frames; failures are reported, never converted to passing skips.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import traceback

from standalone import decode_overlay, decode_bundle, lua_literal, pe_imports


def subsystem(data):
    return struct.unpack_from('<H', data, struct.unpack_from('<I', data, 60)[0] + 92)[0]


class DesktopTests:
    def __init__(self, root, scratch, lua):
        self.root, self.scratch, self.lua = root, scratch, lua
        self.checks, self.commands = [], []
        self.isolated = scratch / 'standalone apps with spaces'
        self.isolated.mkdir()
        self.env = os.environ.copy()
        self.env['PATH'] = str(Path(os.environ['SystemRoot']) / 'System32')
        self.env.pop('LUA_PATH', None)
        self.env.pop('LUA_CPATH', None)
        self.driver = scratch / 'build-desktop.lua'
        self.driver.write_text('local C=assert(loadfile(' + lua_literal(root / 'Compiler.lua') + '))()\n'
                              'local R=C.Build(arg[1],{ExeName=arg[2],Mode=arg[3],Console=arg[4]=="yes"})\n'
                              'assert(R.Ready and R.Mode==arg[3]); print("DESKTOP_BUILD_READY")\n', encoding='utf-8')

    def check(self, value, message):
        assert value, message
        self.checks.append(message)
        print('PASS: ' + message, flush=True)

    def run(self, args, runtime=False, timeout=120):
        result = subprocess.run([str(v) for v in args], cwd=self.isolated if runtime else self.scratch,
                                env=self.env if runtime else None, input=b'', capture_output=True, timeout=timeout)
        self.commands.append({'command': [str(v) for v in args], 'exit': result.returncode,
                              'stdout': result.stdout.decode('utf-8', 'replace')[-10000:],
                              'stderr': result.stderr.decode('utf-8', 'replace')[-10000:]})
        return result

    def build(self, project, name, mode, console=False, success=True):
        result = self.run([self.lua, self.driver, project, name, mode, 'yes' if console else 'no'])
        self.check((result.returncode == 0) == success,
                   ('built ' if success else 'rejected ') + mode + ' ' + name +
                   ('' if not success else ': ' + result.stderr.decode('utf-8', 'replace')))
        if not success:
            return result
        output = project / 'build' / (name + '.exe')
        self.check(b'DESKTOP_BUILD_READY' in result.stdout and output.is_file(), 'ready result agrees with generated EXE')
        return output

    def copy_example(self, name):
        target = self.scratch / name
        shutil.copytree(self.root / 'examples' / name, target, ignore=shutil.ignore_patterns('build'))
        return target

    def alone(self, exe):
        target = self.isolated / exe.name
        shutil.copyfile(exe, target)
        return target

    def execute(self):
        archive = (self.root / 'Runtime.lcb').read_bytes()
        self.check(hashlib.sha256(archive).hexdigest() == (self.root / 'Runtime.lcb.sha256').read_text().strip(),
                   'runtime distribution checksum')
        runtime = dict(decode_bundle(archive))
        for name in (b'lc/ui.lua', b'lc/game.lua', b'lc/scene.lua', b'lc/backends/vulkan.lua'):
            self.check(name in runtime, 'runtime contains ' + name.decode())
        self.check(any(name.endswith(b'.spv') for name in runtime), 'SPIR-V shaders embedded in runtime archive')
        imports = pe_imports((self.root / 'Launcher.exe').read_bytes())
        self.check(not any(any(x in name.lower() for x in ('lua', 'sdl', 'moonvulkan', 'vcruntime', 'msvcp', 'vulkan-1'))
                           for name in imports), 'native libraries static; Vulkan driver loaded only when required')

        project = self.copy_example('NativeUI')
        gui = self.build(project, 'NativeUI', 'gui')
        self.check(subsystem(gui.read_bytes()) == 2, 'GUI executable has Windows GUI subsystem')
        _, bundle, _, _ = decode_overlay(gui.read_bytes())
        contents = dict(decode_bundle(bundle))
        for name, content in runtime.items():
            self.check(contents.get(name) == content, 'embedded framework bytes match: ' + name.decode())
        isolated = self.alone(gui)
        result = self.run([isolated, '--luacompiler-validate'], runtime=True)
        self.check(result.returncode == 0 and b'LuaCompiler executable valid' in result.stdout, 'GUI executable validation')
        result = self.run([isolated, '--luacompiler-capabilities'], runtime=True)
        self.check(result.returncode == 1 and b'unbundled template' in result.stderr,
                   'reserved capabilities probe does not execute bundled GUI code')
        result = self.run([isolated, '--self-test'], runtime=True, timeout=30)
        self.check(result.returncode == 0 and b'NATIVE_UI_SELF_TEST_OK' in result.stdout,
                   'standalone native UI controls, UTF-8, callbacks and shutdown: ' + result.stderr.decode('utf-8','replace'))
        debug = self.build(project, 'NativeUIDebug', 'gui', console=True)
        self.check(subsystem(debug.read_bytes()) == 3, 'optional console for GUI debugging')
        original = gui.read_bytes()
        self.build(project, 'NativeUI', 'unknown', success=False)
        self.check(gui.read_bytes() == original, 'invalid mode preserves working GUI EXE')
        (project / 'lc').mkdir()
        (project / 'lc' / 'ui.lua').write_text('error("shadow framework")', encoding='utf-8')
        self.build(project, 'NativeUI', 'gui', success=False)
        self.check(gui.read_bytes() == original, 'framework path conflict preserves working GUI EXE')

        for example, mode in [('Vulkan2D', 'vulkan2d'), ('Vulkan3D', 'vulkan3d')]:
            project = self.copy_example(example)
            gui = self.build(project, example, mode)
            self.check(subsystem(gui.read_bytes()) == 2, example + ' defaults to GUI subsystem')
            _, bundle, _, _ = decode_overlay(gui.read_bytes())
            contents = dict(decode_bundle(bundle))
            self.check(contents[b'Main.lua'] == (project / 'Main.lua').read_bytes(), example + ' embeds exact entry')
            for source in project.rglob('*'):
                if source.is_file() and 'build' not in source.relative_to(project).parts:
                    key = source.relative_to(project).as_posix().encode('utf-8')
                    self.check(contents.get(key) == source.read_bytes(), example + ' exact project asset ' + key.decode())
            # Keep stderr available for GPU/driver failures; this is the same
            # static launcher and LCB with only the PE subsystem set to console.
            debug = self.build(project, example + 'Test', mode, console=True)
            isolated = self.alone(debug)
            capture = self.scratch / (example + '.bmp')
            result = self.run([isolated, '--frames', '8', '--self-test', '--capture', capture], runtime=True, timeout=60)
            self.check(result.returncode == 0, example + ' rendered eight real Vulkan frames in isolation: '
                       + result.stderr.decode('utf-8', 'replace'))
            self.check((example.upper() + '_OK').encode() in result.stdout,
                       example + ' confirms scene geometry and resize smoke path')
            pixels = capture.read_bytes()
            self.check(pixels[:2] == b'BM' and len(pixels)>10000, example + ' captured an actual GPU frame')
            start = struct.unpack_from('<I',pixels,10)[0]
            bits = struct.unpack_from('<H',pixels,28)[0]
            self.check(bits in (24,32) and len(set(pixels[i:i+bits//8] for i in range(start,len(pixels),bits//8)))>5,
                       example + ' capture contains visible geometry and texture/lighting colors')
        self.check(all(path.suffix.lower() == '.exe' for path in self.isolated.iterdir()),
                   'runtime folder contains only single-file apps, no Lua/scripts/shaders/DLL sidecars')

    def report(self, error):
        data = {'passed_checks': len(self.checks), 'checks': self.checks, 'commands': self.commands, 'error': error,
                'limitations': ['Tests use this machine and its graphics drivers, not a clean VM.',
                                'No live release update or publishing is performed.']}
        (self.scratch / 'desktop-results.json').write_text(json.dumps(data, indent=2), encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('scratch', type=Path)
    parser.add_argument('--lua', default=shutil.which('lua'))
    args = parser.parse_args()
    assert args.lua, 'Lua 5.4 is required to run development tests'
    args.scratch.mkdir(parents=True, exist_ok=False)
    suite = DesktopTests(args.root.resolve(), args.scratch.resolve(), args.lua)
    failure = None
    try:
        suite.execute()
    except Exception:
        failure = traceback.format_exc()
        print(failure, flush=True)
    finally:
        suite.report(failure)
    print(f'{len(suite.checks)} desktop checks passed; failures: {bool(failure)}', flush=True)
    raise SystemExit(1 if failure else 0)
