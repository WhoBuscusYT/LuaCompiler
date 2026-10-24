"""Independent Windows standalone integration tests (development only).

Usage: python tests/standalone.py ROOT NEW_SCRATCH [--lua PATH]
The published compiler and generated applications do not depend on Python.
All generated projects, malformed executables, and reports stay in NEW_SCRATCH.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import traceback


FOOTER = struct.Struct("<8sQQII32s")
MAGIC = b"LCBEXE1\0"


def lua_literal(value):
    value = str(value)
    marker = "="
    while "]" + marker + "]" in value:
        marker += "="
    return "[" + marker + "[" + value + "]" + marker + "]"


def decode_overlay(data):
    assert len(data) >= FOOTER.size, "missing executable footer"
    magic, offset, length, entry_size, codepage, digest = FOOTER.unpack(data[-64:])
    assert magic == MAGIC, "wrong executable footer magic"
    assert offset > 0 and offset + length + entry_size + 64 == len(data), "footer bounds"
    bundle = data[offset:offset + length]
    entry = data[offset + length:-64]
    assert hashlib.sha256(bundle + entry).digest() == digest, "overlay checksum"
    assert entry.decode("utf-8"), "empty entry"
    return data[:offset], bundle, entry, codepage


def decode_bundle(data):
    """Independent decoder; also verifies every byte against fixture sources."""
    assert len(data) >= 12 and data[:4] == b"LCB1", "LCB magic"
    version, count = struct.unpack_from("<II", data, 4)
    assert version == 1, "LCB version"
    position, files = 12, []
    for _ in range(count):
        assert len(data) - position >= 12, "LCB entry header"
        path_size, content_size = struct.unpack_from("<IQ", data, position)
        position += 12
        assert path_size and path_size <= len(data) - position, "LCB path bounds"
        path = data[position:position + path_size]
        position += path_size
        assert content_size <= len(data) - position, "LCB content bounds"
        content = data[position:position + content_size]
        position += content_size
        files.append((path, content))
    assert position == len(data), "LCB trailing bytes"
    return files


def pack_bundle(entries, version=1, count=None):
    output = bytearray(b"LCB1" + struct.pack("<II", version, len(entries) if count is None else count))
    for name, content in entries:
        output.extend(struct.pack("<IQ", len(name), len(content)))
        output.extend(name)
        output.extend(content)
    return bytes(output)


def pe_imports(data):
    """Read the PE import directory directly; no compiler utilities required."""
    assert data[:2] == b"MZ", "DOS executable header"
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    assert data[pe:pe + 4] == b"PE\0\0", "PE signature"
    machine, sections, _, _, _, optional_size, characteristics = struct.unpack_from("<HHIIIHH", data, pe + 4)
    assert machine == 0x8664 and characteristics & 2, "x64 PE executable"
    optional = pe + 24
    assert struct.unpack_from("<H", data, optional)[0] == 0x20B, "PE32+"
    assert struct.unpack_from("<H", data, optional + 68)[0] == 3, "console subsystem"
    imports_rva, imports_size = struct.unpack_from("<II", data, optional + 120)
    section_table = optional + optional_size
    mapping = []
    for index in range(sections):
        start = section_table + index * 40
        virtual_size, virtual_address, raw_size, raw_offset = struct.unpack_from("<IIII", data, start + 8)
        mapping.append((virtual_address, max(virtual_size, raw_size), raw_offset))

    def file_offset(rva):
        for address, size, raw in mapping:
            if address <= rva < address + size:
                return raw + rva - address
        raise AssertionError("PE RVA outside mapped sections")

    if not imports_rva:
        return []
    position, result = file_offset(imports_rva), []
    for _ in range(max(1, imports_size // 20)):
        descriptor = struct.unpack_from("<IIIII", data, position)
        if not any(descriptor):
            return result
        name = file_offset(descriptor[3])
        end = data.index(b"\0", name)
        result.append(data[name:end].decode("ascii"))
        position += 20
    raise AssertionError("unterminated PE import directory")


class Suite:
    def __init__(self, root, scratch, lua):
        self.root, self.scratch, self.lua = root, scratch, lua
        self.checks, self.skipped, self.commands = [], [], []
        self.runtime_directory = scratch / "isolated runtime with spaces"
        self.runtime_directory.mkdir()
        self.runtime_environment = os.environ.copy()
        self.runtime_environment["PATH"] = str(Path(os.environ["SystemRoot"]) / "System32")
        self.runtime_environment.pop("LUA_PATH", None)
        self.runtime_environment.pop("LUA_CPATH", None)
        self.driver = scratch / "build.lua"
        self.write_driver(root)

    def check(self, condition, message):
        if not condition:
            raise AssertionError(message)
        self.checks.append(message)
        print("PASS: " + message, flush=True)

    def run(self, command, *, cwd=None, input=b"", runtime=False, timeout=120):
        result = subprocess.run([str(item) for item in command], cwd=cwd or self.scratch,
                                env=self.runtime_environment if runtime else None,
                                input=input, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout)
        self.commands.append({"command": [str(item) for item in command],
                              "cwd": str(cwd or self.scratch), "exit": result.returncode,
                              "stdout": result.stdout.decode("utf-8", "replace")[-8000:],
                              "stderr": result.stderr.decode("utf-8", "replace")[-8000:]})
        return result

    def write_driver(self, root):
        source = "local C=assert(loadfile(" + lua_literal(root / "Compiler.lua") + "))()\n"
        source += "local R=C.Build(arg[1],{ExeName=arg[2],Entry=arg[3]})\n"
        source += "assert(R.Ready and R.Executable and R.Output==R.Executable,'Build did not return a ready executable')\n"
        source += "print('BUILD_READY')\n"
        self.driver.write_bytes(source.encode("mbcs"))

    def project(self, name, files):
        directory = self.scratch / name
        directory.mkdir()
        for relative, content in files.items():
            path = directory / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.encode("utf-8") if isinstance(content, str) else content)
        return directory

    def build(self, project, name="Game", entry="Main.lua", success=True):
        result = self.run([self.lua, self.driver, project, name, entry])
        self.check((result.returncode == 0) == success,
                   ("successful" if success else "rejected") + " build: " + project.name + "/" + name +
                   ("" if result.returncode == 0 or not success else "\n" + result.stderr.decode("utf-8", "replace")))
        if success:
            self.check(b"BUILD_READY" in result.stdout, "Builder returns a ready executable: " + name)
            output = project / "build" / (name + ".exe")
            self.check(output.is_file(), "output executable exists: " + name)
            return output
        return result

    def alone(self, executable, name=None):
        target = self.runtime_directory / (name or executable.name)
        shutil.copyfile(executable, target)
        return target

    def report(self, error=None):
        report = {"passed_checks": len(self.checks), "checks": self.checks, "skipped": self.skipped,
                  "error": error, "commands": self.commands,
                  "runtime_path": self.runtime_environment["PATH"],
                  "limitations": ["Windows runtime isolation removes Lua and compiler directories from PATH; this is not a separate clean Windows VM.",
                                  "No live GitHub update requests are made by these native integration tests."]}
        (self.scratch / "standalone-results.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    def execute(self):
        template = self.root / "Launcher.exe"
        probe = self.run([template, "--luacompiler-probe"], runtime=True)
        self.check(probe.returncode == 0 and probe.stdout.strip() == b"LuaCompiler launcher 1 Lua 5.4",
                   "native launcher probe")
        license_result = self.run([template, "--luacompiler-license"], runtime=True)
        self.check(license_result.returncode == 0 and b"Permission is hereby granted" in license_result.stdout,
                   "standalone launcher includes the Lua license")
        checksum = (self.root / "Launcher.exe.sha256").read_text("ascii").split()[0].lower()
        self.check(hashlib.sha256(template.read_bytes()).hexdigest() == checksum,
                   "distributed launcher checksum")
        imports = pe_imports(template.read_bytes())
        self.check(not any("lua" in name.lower() or name.lower().startswith(("vcruntime", "msvcp"))
                           for name in imports), "launcher has no Lua or Visual C++ runtime DLL imports")
        print("PE imports: " + ", ".join(imports), flush=True)

        binary = bytes(range(256)) * 1025 + b"\x00\xffEND"
        main = r'''io.stdout:setvbuf("no")
assert(require("lcb")==lcb and type(lcb.license)=="string")
assert(require("scripts.greet")=="hello module")
assert(require("package_dir").answer==42)
assert(lcb.exists("assets/binary data.bin"))
assert(lcb.read("assets/binary data.bin")==string.rep((string.char(table.unpack((function() local t={} for i=0,255 do t[#t+1]=i end return t end)()))),1025).."\0\255END")
assert(lcb.read("assets/empty")=="")
local missing,why=lcb.read("missing"); assert(missing==nil and type(why)=="string")
assert(not lcb.exists("../Main.lua"))
local unsafe,reason=lcb.read("../Main.lua"); assert(unsafe==nil and reason)
local names=lcb.files(); assert(type(names)=="table" and #names==7)
local seen={} for _,name in ipairs(names) do seen[name]=true end
assert(seen["Main.lua"] and seen["scripts/greet.lua"] and not seen["build/ignored.lua"])
assert(arg[1]=="hello world" and arg[2]=="second" and arg[3]=="snow \u{2744}")
local positional={...}; assert(#positional==3 and positional[1]==arg[1] and positional[3]==arg[3])
io.write("INPUT>"); assert(io.read("*l")=="typed data")
print("ENTRY_OK"); return 0
'''
        files = {"Main.lua": main, "scripts/greet.lua": 'return "hello module"',
                 "package_dir/init.lua": "return {answer=42}", "assets/binary data.bin": binary,
                 "assets/empty": b"", "unused.lua": 'error("UNSELECTED_SCRIPT_EXECUTED")',
                 "invalid-unselected.lua": "this is deliberately invalid Lua !!!"}
        project = self.project("project with spaces", files)
        for name in ("build/ignored.lua", ".git/config", "nested/build/ignored.lua", "old.EXE", "old.lcb"):
            path = project / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"excluded")
        executable = self.build(project)
        self.check((project / "build").is_dir(), "build output directory creation")
        first_executable = executable.read_bytes()
        stub, bundle, entry, codepage = decode_overlay(first_executable)
        self.check(entry == b"Main.lua", "default selected entry in footer")
        self.check(bundle == (project / "build/Game.lcb").read_bytes(), "embedded bundle matches standalone .lcb")
        extracted = dict(decode_bundle(bundle))
        self.check(len(extracted) == len(files), "recursive discovery and output/.git/executable exclusions")
        for name, content in files.items():
            content = content.encode("utf-8") if isinstance(content, str) else content
            self.check(extracted[name.encode("ascii")] == content, "embedded bytes match original: " + name)
            extracted_path = self.scratch / "independent extraction" / name
            extracted_path.parent.mkdir(parents=True, exist_ok=True)
            extracted_path.write_bytes(extracted[name.encode("ascii")])
            self.check(extracted_path.read_bytes() == (project / name).read_bytes(), "extracted bytes match original: " + name)
        moved = self.alone(executable)
        self.check(list(self.runtime_directory.iterdir()) == [moved], "application copied alone without Lua or project files")
        validated = self.run([moved, "--luacompiler-validate"], runtime=True, cwd=self.runtime_directory)
        self.check(validated.returncode == 0 and validated.stdout.strip() == b"LuaCompiler executable valid",
                   "standalone executable validation without executing entry")
        result = self.run([moved, "hello world", "second", "snow \u2744"], input=b"typed data\n", runtime=True, cwd=self.runtime_directory)
        self.check(result.returncode == 0 and b"INPUT>ENTRY_OK" in result.stdout,
                   "standalone modules, binary assets, console input/output and arguments")
        self.check(b"UNSELECTED_SCRIPT_EXECUTED" not in result.stdout + result.stderr,
                   "only selected entry executes; unselected invalid script is harmless")
        rebuilt = self.build(project).read_bytes()
        self.check(first_executable == rebuilt, "repeated build preserves deterministic executable bytes")

        old_bytes = executable.read_bytes()
        self.build(project, entry="Missing.lua", success=False)
        self.check(executable.read_bytes() == old_bytes, "missing entry build preserves previous executable")
        self.build(project, entry="../Main.lua", success=False)
        self.check(executable.read_bytes() == old_bytes, "unsafe entry build preserves previous executable")
        self.build(project, name="../escape", success=False)
        self.check(executable.read_bytes() == old_bytes, "invalid output name preserves previous executable")
        (project / "Main.lua").write_bytes(b"local = invalid entry syntax ???")
        self.build(project, success=False)
        self.check(executable.read_bytes() == old_bytes, "entry syntax error preserves previous executable")
        (project / "Main.lua").write_bytes(main.encode("utf-8"))
        failure_driver = self.scratch / "temporary-failure.lua"
        failure_source = "local Root=" + lua_literal(self.root) + "\n" + r'''
local RealLoad=loadfile
local Bundler=assert(RealLoad(Root..'/Bundler.lua'))()
local Windows=assert(RealLoad(Root..'/Windows.lua'))()
local OriginalTemporary=Windows.Temporary
local Calls=0
Windows.Temporary=function(Destination)
    Calls=Calls+1
    if Calls==2 then error('INJECTED_PAYLOAD_TEMPORARY_FAILURE') end
    return OriginalTemporary(Destination)
end
local Environment=setmetatable({loadfile=function(Path,Mode,Env)
    if Path:match('Windows%.lua$') then return function() return Windows end end
    return RealLoad(Path,Mode,Env or _G)
end},{__index=_G})
local Builder=assert(RealLoad(Root..'/Builder.lua','t',Environment))()
local Ok,Why=pcall(Builder.Build,arg[1],Bundler.GetFiles(arg[1]),{ExeName='Game',Entry='Main.lua'})
assert(not Ok and tostring(Why):find('INJECTED_PAYLOAD_TEMPORARY_FAILURE',1,true),tostring(Why))
assert(Calls==2,'Fault injection did not reach second Builder temporary creation')
print('TEMPORARY_FAILURE_OK')
'''
        failure_driver.write_bytes(failure_source.encode("mbcs"))
        result = self.run([self.lua, failure_driver, project])
        self.check(result.returncode == 0 and b"TEMPORARY_FAILURE_OK" in result.stdout,
                   "Builder reports a payload temporary-creation failure after reserving executable")
        self.check(executable.read_bytes() == old_bytes,
                   "temporary-creation failure preserves previous executable bytes")
        self.check(not list((project / "build").glob("*.pending*")),
                   "temporary-creation failure cleans reserved and pending executable names")

        alternate = self.project("custom entry", {"Main.lua": 'error("WRONG_DEFAULT_ENTRY")',
                                                 "scripts/start.lua": 'print("CUSTOM_ENTRY"); return 23'})
        custom = self.alone(self.build(alternate, name="Custom", entry="scripts/start.lua"))
        result = self.run([custom], runtime=True, cwd=self.runtime_directory)
        self.check(result.returncode == 23 and b"CUSTOM_ENTRY" in result.stdout,
                   "custom entry and integer application exit status")
        unicode_executable = self.alone(custom, "standalone caf\u00e9 \u96ea.exe")
        result = self.run([unicode_executable], runtime=True, cwd=self.runtime_directory)
        self.check(result.returncode == 23 and b"CUSTOM_ENTRY" in result.stdout,
                   "standalone executable runs from a Unicode executable filename")
        many = self.project("many arguments", {"Main.lua":
            'local a={...}; assert(#a==64); for i=1,64 do assert(a[i]==arg[i] and a[i]=="item "..i) end; '
            'assert(arg[0]:match("ManyArgs%.exe$")); print("MANY_ARGS_OK")'})
        many_executable = self.alone(self.build(many, name="ManyArgs"))
        result = self.run([many_executable] + ["item " + str(i) for i in range(1,65)], runtime=True, cwd=self.runtime_directory)
        self.check(result.returncode == 0 and b"MANY_ARGS_OK" in result.stdout,
                   "64 application arguments arrive in arg and entry varargs without stack corruption")
        headers = self.project("BOM shebang sources", {
            "Main.lua": b'\xef\xbb\xbf#!/usr/bin/lua\r\nassert(require("module")==91); '
                        b'assert(lcb.read("Main.lua"):sub(1,3)==string.char(239,187,191)); print("HEADERS_OK")',
            "module.lua": b"\xef\xbb\xbf#!/usr/bin/lua\nreturn 91"})
        headers_executable = self.alone(self.build(headers, name="Headers"))
        result = self.run([headers_executable], runtime=True, cwd=self.runtime_directory)
        self.check(result.returncode == 0 and b"HEADERS_OK" in result.stdout,
                   "UTF8 BOM and shebang entry/modules execute while asset reads preserve exact bytes")

        for label, source, expected, marker in (
            ("return status", "return 7", 7, None),
            ("os exit", "os.exit(12)", 12, None),
            ("invalid return status", "return 256", 1, None),
            ("Lua traceback", 'local function inner() error("EXPECTED_LUA_FAILURE") end; inner()', 1, b"stack traceback"),
        ):
            case = self.project(label, {"Main.lua": source})
            built = self.build(case, name=label.replace(" ", "_"))
            result = self.run([self.alone(built)], runtime=True, cwd=self.runtime_directory)
            self.check(result.returncode == expected, label + " propagates failure/exit status")
            if marker:
                self.check(marker in result.stderr + result.stdout, "Lua errors include a traceback")

        external = self.project("embedded require only", {"Main.lua":
                                'local ok,why=pcall(require,"external"); assert(not ok and why); print("EMBEDDED_ONLY")'})
        external_exe = self.alone(self.build(external, name="External"))
        (self.runtime_directory / "external.lua").write_text('error("EXTERNAL_FILE_WAS_LOADED")', encoding="ascii")
        result = self.run([external_exe], runtime=True, cwd=self.runtime_directory)
        self.check(result.returncode == 0 and b"EMBEDDED_ONLY" in result.stdout and
                   b"EXTERNAL_FILE_WAS_LOADED" not in result.stdout + result.stderr,
                   "require cannot load unbundled Lua files from current directory")

        # Trusted startup policy is compiled into the launcher itself; console
        # projects need no Runtime.lcb or project-supplied bootstrap script.
        policy_source = r'''
assert(#package.searchers==2 and package.path=='' and package.cpath=='' and package.loadlib==nil)
assert(lcb.load==nil and _G.LoadEmbedded==nil,'Private mapped loader leaked into public globals')
package.preload.priority=function(Name,Path) assert(Name=='priority' and Path==':preload:'); return 'PRELOADED' end
assert(require('priority')=='PRELOADED','Preload searcher lost precedence')
assert(require('choice')=='FILE','File module must precede directory init module')
local Nested=require('nested.module')
assert(Nested.Name=='nested.module' and Nested.Path=='nested/module.lua','Module loader arguments changed')
assert(require('folder')=='INIT','Directory init module was not found')
local A=require('cached'); assert(require('cached')==A and _G.CachedLoads==1,'Module cache changed')
assert(require('returns_nil')==true and require('returns_nil')==true,'Nil module return policy changed')
assert(require(123)=='NUMERIC','Numeric require argument compatibility changed')
local Type,ToString,Raise,Find,Replace=type,tostring,error,string.find,string.gsub
type,tostring,error,string.find,string.gsub=false,false,false,false,false
local RobustOK,RobustValue=pcall(require,'globals_changed')
type,tostring,error,string.find,string.gsub=Type,ToString,Raise,Find,Replace
assert(RobustOK and RobustValue=='ROBUST','Project global assignments changed trusted module resolution')
local OK,Why=pcall(require,'bad_module')
assert(not OK and tostring(Why):find('lcb/bad_module.lua',1,true),'Syntax error incorrectly fell back to init.lua')
OK,Why=pcall(require,'missing_policy_module')
assert(not OK and tostring(Why):find("no bundled Lua module 'missing_policy_module'",1,true),'Missing module diagnostic changed')
for _,Name in ipairs({'',string.rep('x',32759),'bad'..string.char(0)..'module'}) do
    OK,Why=pcall(package.searchers[2],Name)
    assert(not OK and tostring(Why):find('Invalid embedded module name',1,true),'Invalid module name was accepted')
end
print('MODULE_POLICY_OK')
'''
        policy = self.project("trusted module policy", {
            "Main.lua": policy_source,
            "priority.lua": 'error("EMBEDDED_PRELOAD_SHADOW_EXECUTED")',
            "choice.lua": 'return "FILE"',
            "choice/init.lua": 'error("WRONG_INIT_EXECUTED")',
            "nested/module.lua": 'local Name,Path=...; return {Name=Name,Path=Path}',
            "folder/init.lua": 'return "INIT"',
            "cached.lua": '_G.CachedLoads=(_G.CachedLoads or 0)+1; return {}',
            "returns_nil.lua": 'return nil',
            "123.lua": 'return "NUMERIC"',
            "globals_changed.lua": 'return "ROBUST"',
            "bad_module.lua": 'local = deliberately invalid syntax',
            "bad_module/init.lua": 'error("SYNTAX_ERROR_FELL_BACK_TO_INIT")',
            "bootstrap.lua": 'error("PROJECT_BOOTSTRAP_EXECUTED")',
            "luacompiler/bootstrap.lua": 'error("PROJECT_BOOTSTRAP_EXECUTED")',
            "native/bootstrap.lua": 'error("PROJECT_BOOTSTRAP_EXECUTED")',
        })
        policy_executable = self.alone(self.build(policy, name="ModulePolicy"))
        environment = self.runtime_environment.copy()
        try:
            self.runtime_environment["LUA_PATH"] = str(self.runtime_directory / "?.lua") + ";;"
            self.runtime_environment["LUA_CPATH"] = str(self.runtime_directory / "?.dll") + ";;"
            result = self.run([policy_executable], runtime=True, cwd=self.runtime_directory)
        finally:
            self.runtime_environment = environment
        self.check(result.returncode == 0 and b"MODULE_POLICY_OK" in result.stdout,
                   "trusted Lua bootstrap preserves module precedence, caching, loader data, diagnostics and name guards")
        self.check(b"PROJECT_BOOTSTRAP_EXECUTED" not in result.stdout + result.stderr,
                   "project files cannot override trusted launcher startup policy")
        _, policy_bundle, _, _ = decode_overlay(policy_executable.read_bytes())
        self.check(b"lc/ui.lua" not in dict(decode_bundle(policy_bundle)),
                   "plain console module policy works without embedding framework Runtime.lcb")

        missing = self.project("missing default entry", {"other.lua": "return 1"})
        self.build(missing, success=False)
        self.check(not (missing / "build/Game.exe").exists(), "no success artifact when default entry is missing")
        blocked = self.project("blocked output", {"Main.lua": "return 0", "build": "ordinary file"})
        self.build(blocked, success=False)

        # A completed application is never a raw launcher template, even if its
        # entry would print the exact template probe response and exit zero.
        guard = self.project("reserved probe guard", {"Main.lua":
            'local f=assert(io.open(arg[0]..".executed","wb")); f:write("ENTRY_EXECUTED"); f:close(); '
            'print("LuaCompiler launcher 1 Lua 5.4"); return 0'})
        guard_executable = self.alone(self.build(guard, name="ProbeGuard"))
        result = self.run([guard_executable, "--luacompiler-probe"], runtime=True, cwd=self.runtime_directory)
        self.check(result.returncode == 1 and b"LuaCompiler launcher 1 Lua 5.4" not in result.stdout,
                   "completed executable rejects reserved raw-template probe")
        self.check(not Path(str(guard_executable) + ".executed").exists(),
                   "reserved probe never executes the bundled entry")

        # Damage a private compiler copy, never the actual installation.
        private_root = self.scratch / "private compiler"
        private_root.mkdir()
        for path in self.root.iterdir():
            if path.is_file() and (path.suffix == ".lua" or path.name.startswith("Launcher.exe")):
                shutil.copyfile(path, private_root / path.name)
        self.write_driver(private_root)
        damaged_template = bytearray((private_root / "Launcher.exe").read_bytes())
        damaged_template[-1] ^= 0xFF
        (private_root / "Launcher.exe").write_bytes(damaged_template)
        self.build(project, success=False)
        self.check(executable.read_bytes() == old_bytes, "bad launcher checksum preserves previous executable")
        (private_root / "Launcher.exe").write_bytes(b"not an executable")
        (private_root / "Launcher.exe.sha256").write_text(hashlib.sha256(b"not an executable").hexdigest() + "\n", encoding="ascii")
        self.build(project, success=False)
        self.check(executable.read_bytes() == old_bytes, "invalid native template preserves previous executable")
        bundled_template = guard_executable.read_bytes()
        (private_root / "Launcher.exe").write_bytes(bundled_template)
        (private_root / "Launcher.exe.sha256").write_text(hashlib.sha256(bundled_template).hexdigest() + "\n", encoding="ascii")
        self.build(project, success=False)
        self.check(executable.read_bytes() == old_bytes, "bundled application used as template preserves previous executable")
        self.check(not (private_root / "Launcher.exe.executed").exists(),
                   "Builder rejects checksummed bundled template without executing its entry")
        self.write_driver(self.root)

        # Exercise ANSI LCB paths and the launcher's UTF-8 Lua API where supported.
        try:
            "caf\u00e9".encode("mbcs")
        except UnicodeEncodeError:
            self.skipped.append("Representable Unicode filename: active ANSI codepage cannot encode cafe-accent")
        else:
            unicode_project = self.project("caf\u00e9 project", {
                "Main.lua": 'assert(require("caf\u00e9")==81); assert(lcb.read("assets/caf\u00e9.bin")=="UNICODE_ASSET"); print("UNICODE_OK")',
                "caf\u00e9.lua": "return 81", "assets/caf\u00e9.bin": b"UNICODE_ASSET"})
            unicode_exe = self.alone(self.build(unicode_project, name="Unicode"))
            result = self.run([unicode_exe], runtime=True, cwd=self.runtime_directory)
            self.check(result.returncode == 0 and b"UNICODE_OK" in result.stdout,
                       "representable Unicode project, module and asset filenames")

        self.malformed(stub, bundle, entry, codepage, first_executable)

    def malformed(self, stub, good_bundle, entry, codepage, good_executable):
        directory = self.scratch / "malformed executables"
        directory.mkdir()

        def overlay(bundle, selected=entry, cp=codepage, offset=None, length=None, size=None, digest=None):
            return stub + bundle + selected + FOOTER.pack(MAGIC, len(stub) if offset is None else offset,
                   len(bundle) if length is None else length, len(selected) if size is None else size, cp,
                   hashlib.sha256(bundle + selected).digest() if digest is None else digest)

        def reject(label, data):
            path = directory / ("bad_%03d.exe" % len(self.checks))
            path.write_bytes(data)
            result = self.run([path, "--luacompiler-validate"], cwd=directory, runtime=True, timeout=20)
            self.check(result.returncode == 1, "safely reject malformed executable: " + label +
                       " (exit=" + str(result.returncode) + ")")
            self.check(b"LuaCompiler executable valid" not in result.stdout,
                       "no validation success for malformed executable: " + label)

        reject("missing footer", stub)
        reject("truncated footer", good_executable[:-1])
        reject("truncated payload", stub + good_bundle[:20])
        damaged = bytearray(good_executable)
        damaged[-64] ^= 1
        reject("footer magic", damaged)
        damaged = bytearray(good_executable)
        damaged[len(stub) + 12] ^= 1
        reject("payload digest mismatch", damaged)
        reject("trailing executable bytes", good_executable + b"EXTRA")
        reject("offset beyond executable", overlay(good_bundle, offset=2**64 - 1))
        reject("length integer overflow", overlay(good_bundle, length=2**64 - 1))
        reject("entry length overflow", overlay(good_bundle, size=2**32 - 1))
        reject("offset into DOS header", overlay(good_bundle, offset=1))
        reject("empty entry", overlay(good_bundle, selected=b""))
        reject("invalid UTF8 entry", overlay(good_bundle, selected=b"\xff.lua"))
        reject("entry outside bundle", overlay(good_bundle, selected=b"Missing.lua"))
        reject("unsafe selected entry", overlay(good_bundle, selected=b"../Main.lua"))
        reject("invalid path codepage", overlay(good_bundle, cp=999999))
        reject("LCB magic", overlay(b"NOPE" + good_bundle[4:]))
        reject("LCB version", overlay(good_bundle[:4] + struct.pack("<I", 2) + good_bundle[8:]))
        reject("truncated LCB header", overlay(b"LCB1"))
        reject("impossible file count", overlay(b"LCB1" + struct.pack("<II", 1, 0xFFFFFFFF)))
        reject("file count exceeds supported maximum", overlay(b"LCB1" + struct.pack("<II", 1, 100001)))
        reject("zero files entry missing", overlay(pack_bundle([])))
        reject("trailing LCB data", overlay(good_bundle + b"EXTRA"))
        reject("file count smaller than records", overlay(pack_bundle([(b"Main.lua", b"return 0")], count=0)))
        reject("path length out of bounds", overlay(b"LCB1" + struct.pack("<II", 1, 1) + struct.pack("<IQ", 0xFFFFFFFF, 0)))
        reject("file size out of bounds", overlay(b"LCB1" + struct.pack("<II", 1, 1) + struct.pack("<IQ", 8, 2**64 - 1) + b"Main.lua"))
        reject("truncated content", overlay(pack_bundle([(b"Main.lua", b"return 0")])[:-1]))
        for path in (b"", b"../bad", b"a/../bad", b"/bad", b"C:/bad", b"C:bad", b"a//bad",
                     b"a/./bad", b"a/", b"bad\0x", b"bad:stream", b"a\\..\\bad", b"CON", b"aux.txt", b"CONIN$", b"bad.", b"bad "):
            reject("unsafe path " + repr(path), overlay(pack_bundle([(b"Main.lua", b"return 0"), (path, b"x")])))
        for names in ((b"Main.lua", b"Main.lua"), (b"Main.lua", b"main.lua"),
                      (b"a", b"a/b"), (b"a/b", b"a"), (b"a", b"a!", b"a/b")):
            reject("duplicate/colliding paths " + repr(names), overlay(pack_bundle(
                   [(b"Main.lua", b"return 0")] + [(name, b"x") for name in names])))
        try:
            reserved = "COM\u00b9".encode("cp" + str(codepage))
        except (UnicodeEncodeError, LookupError):
            self.skipped.append("Superscript Windows device alias cannot be represented in footer codepage")
        else:
            reject("Windows superscript device alias", overlay(pack_bundle([(b"Main.lua", b"return 0"), (reserved, b"x")])))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("scratch", type=Path)
    parser.add_argument("--lua", default=shutil.which("lua"))
    args = parser.parse_args()
    if os.name != "nt":
        parser.error("these integration tests require Windows")
    if not args.lua:
        parser.error("Lua 5.4 is needed to run compiler development tests; supply --lua")
    args.root, args.scratch = args.root.resolve(), args.scratch.resolve()
    if args.scratch.exists():
        parser.error("scratch must be a new directory, to preserve previous results")
    args.scratch.mkdir(parents=True)
    suite = Suite(args.root, args.scratch, Path(args.lua).resolve())
    try:
        suite.execute()
    except Exception:
        error = traceback.format_exc()
        suite.report(error)
        print(error, file=sys.stderr)
        print("FAILED after %d passing checks; report: %s" % (len(suite.checks), args.scratch / "standalone-results.json"), file=sys.stderr)
        return 1
    suite.report()
    print("Standalone integration checks passed: %d; skipped: %d" % (len(suite.checks), len(suite.skipped)))
    print("Report: " + str(args.scratch / "standalone-results.json"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
