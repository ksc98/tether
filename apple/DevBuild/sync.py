# Copies apple/Tether into Sources/TetherApp with #Preview blocks removed: the
# previews macro plugin does not exist on Linux, and SwiftPM cannot point a
# target at a directory outside the package.
import os, shutil
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "..", "Tether")
dst = os.path.join(here, "Sources", "TetherApp")
shutil.rmtree(dst, ignore_errors=True)
for root, dirs, files in os.walk(src):
    dirs[:] = [d for d in dirs if not d.endswith(".xcassets")]
    for f in files:
        if not f.endswith(".swift"):
            continue
        p = os.path.join(root, f)
        s = open(p).read()
        out = []
        i = 0
        while True:
            j = s.find("#Preview", i)
            if j < 0:
                out.append(s[i:]); break
            out.append(s[i:j])
            k = s.find("{", j)
            depth = 0
            while k < len(s):
                if s[k] == "{": depth += 1
                elif s[k] == "}":
                    depth -= 1
                    if depth == 0: break
                k += 1
            i = k + 1
        rel = os.path.relpath(p, src)
        o = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(o), exist_ok=True)
        open(o, "w").write("".join(out))
print("synced")
