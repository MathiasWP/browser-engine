#!/usr/bin/env python3
# github_pack_headers.py <src dir> <out dir> <upload dir>: what tools/check.sh needs to compile
# the embedding layer's files and the touch points' on a Mac that can't build Chromium: every
# header in the tree (sources' and generated), Chromium's clang, libc++ (whose headers have no
# suffix), the touch points' sources as they were before our patches (originals/), and the
# compile commands of all those files, as headers.tar.zst and compile_commands.json.
import json, os, re, shutil, subprocess, sys

src, out, upload = sys.argv[1:4]
os.makedirs(upload, exist_ok=True)
root = os.path.dirname(os.path.dirname(src))  # the checkout holding build/src
patched = set()
patches = os.path.abspath(os.path.join(root, "patches", "browser_engine"))
for name in sorted(os.listdir(patches)):
    with open(os.path.join(patches, name)) as patch:
        patched.update(m.group(1) for m in re.finditer(r"^\+\+\+ b/(\S+)", patch.read(), re.M))

compdb = json.loads(subprocess.check_output(["ninja", "-C", out, "-t", "compdb", "cc", "cxx", "objc", "objcxx"]))
real_src = os.path.realpath(src)
def relative(entry):
    return os.path.relpath(os.path.realpath(os.path.join(entry["directory"], entry["file"])), real_src)
wanted = [e for e in compdb if relative(e).startswith("browser_engine/") or relative(e) in patched]
with open(os.path.join(upload, "compile_commands.json"), "w") as f:
    json.dump(wanted, f)
print(f"{len(wanted)} compile commands")

suffixes = (".h", ".hh", ".hpp", ".inc", ".def", ".modulemap")
files = []
for top, dirs, names in os.walk(src):
    rel = os.path.relpath(top, src)
    if rel in ("out", ".git") or rel.startswith(("out/", ".git/")):
        dirs[:] = []
        continue
    keep_all = rel.startswith(("third_party/libc++/src/include", "third_party/libc++abi/src/include",
                               "buildtools/third_party/libc++", "third_party/llvm-build/Release+Asserts/lib/clang"))
    files += [os.path.join(rel, n) for n in names if keep_all or n.endswith(suffixes)]
gen = os.path.relpath(os.path.join(out, "gen"), src)
for top, _, names in os.walk(os.path.join(src, gen)):
    files += [os.path.join(os.path.relpath(top, src), n) for n in names if n.endswith(suffixes)]
llvm_bin = "third_party/llvm-build/Release+Asserts/bin"
files += [os.path.join(llvm_bin, n) for n in os.listdir(os.path.join(src, llvm_bin)) if n.startswith("clang")]
# Plugins the compile commands may load.
llvm_lib = "third_party/llvm-build/Release+Asserts/lib"
files += [os.path.join(llvm_lib, n) for n in os.listdir(os.path.join(src, llvm_lib)) if n.endswith(".dylib")]
# The touch points' files without our patches, for check.sh to patch with the ones being checked.
originals = os.path.abspath(os.path.join(src, "originals"))
shutil.rmtree(originals, ignore_errors=True)
for path in patched:
    if os.path.exists(os.path.join(src, path)):
        os.makedirs(os.path.dirname(os.path.join(originals, path)), exist_ok=True)
        shutil.copy2(os.path.join(src, path), os.path.join(originals, path))
for name in sorted(os.listdir(patches), reverse=True):
    subprocess.run(["patch", "-R", "-p1", "-s", "-d", originals, "-i", os.path.join(patches, name)], check=True)
files += [os.path.relpath(os.path.join(top, n), src) for top, _, names in os.walk(originals) for n in names]
print(f"{len(files)} files")
listing = os.path.join(upload, "files.txt")
with open(listing, "w") as f:
    f.write("\n".join(files) + "\n")
subprocess.run(f'tar -C "{src}" -c -f - -T "{listing}" | zstd -10 -T0 -o "{upload}/headers.tar.zst"', shell=True, check=True)
os.remove(listing)
