// Local gzip extraction only: never import the downloading bootstrap entrypoint.
Deno.test("scoped tar extracts gzip while inherited loader variables are denied", async () => {
  const temp = await Deno.makeTempDir({ prefix: "qcl-bootstrap-tar-" });
  const oldLibrary = Deno.env.get("LD_LIBRARY_PATH");
  const oldPreload = Deno.env.get("LD_PRELOAD");
  try {
    Deno.env.set("LD_LIBRARY_PATH", "/qcl-controlled-untrusted-library-fixture");
    Deno.env.set("LD_PRELOAD", "/qcl-controlled-untrusted-preload-fixture.so");
    const archive = `${temp}/fixture.tar.gz`;
    const output = `${temp}/output`;
    await Deno.mkdir(output);
    const bytes = Uint8Array.from(
      atob(
        "H4sIAAAAAAAC/+3SQQqDMBCF4Vn3FF5AjBHreSIoRERLnEB7e6MggutSCv7f5g1v8zYzxNG7vPdvjaErWj8Vw9bIN5mkqes9k2saY5vz3vrSVtVTMiM/EBd1Ic3LPamfPnk7z7pocK/jER4CAAAAAAAAAAAAAAAAAPhvKx4NitYAKAAA",
      ),
      (x) => x.charCodeAt(0),
    );
    await Deno.writeFile(archive, bytes);
    const module = new URL("./bootstrap_tar.ts", import.meta.url);
    const exists = await Deno.stat(module).then((s) => s.isFile).catch(() => false);
    // Before the extraction helper exists, reproduce the exact legacy tar child.
    const status = exists
      ? await (await import(module.href)).extractArchive(archive, output)
      : await new Deno.Command("tar", {
        args: ["-xzf", archive, "-C", output, "--strip-components=1"],
        stdout: "inherit",
        stderr: "inherit",
      }).spawn().status;
    if (!status.success) throw new Error("Fixture gzip extraction failed");
    const actual = await Deno.readTextFile(`${output}/bin/julia`);
    if (actual !== "tiny-bootstrap-fixture\n") throw new Error("Wrong extracted fixture bytes");
  } finally {
    if (oldLibrary === undefined) Deno.env.delete("LD_LIBRARY_PATH");
    else Deno.env.set("LD_LIBRARY_PATH", oldLibrary);
    if (oldPreload === undefined) Deno.env.delete("LD_PRELOAD");
    else Deno.env.set("LD_PRELOAD", oldPreload);
    await Deno.remove(temp, { recursive: true });
  }
});
